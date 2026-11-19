package id.cartertag.connect.mesh

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue

/**
 * Transport BLE untuk mesh. Setiap HP sekaligus:
 *  - advertiser + GATT server (menerima tulisan di RX, mengirim notifikasi di TX)
 *  - scanner + GATT client (menyambung ke peer, menulis ke RX peer, menerima notifikasi TX peer)
 * Satu koneksi per pasangan HP: yang nodeId-nya lebih kecil yang menyambung (initiator).
 *
 * Frame di atas GATT: [kind 1][seq 2][idx 1][count 1] + potongan data (maks MTU-3-5).
 *   kind 1 = envelope, 2 = inventaris (daftar id 16 byte), 3 = minta (daftar id), 4 = hello (member_id)
 */
@SuppressLint("MissingPermission")
class BleMesh(private val ctx: Context, private val listener: Listener) {

    interface Listener {
        fun onLinkUp(link: Link)
        fun onLinkDown(link: Link)
        fun onFrame(link: Link, kind: Int, data: ByteArray)
        fun onScanSeen(addr: String, rssi: Int)
    }

    companion object {
        const val TAG = "CTMesh"
        val SERVICE: UUID = UUID.fromString("0000ca7a-0000-1000-8000-00805f9b34fb")
        val RX: UUID = UUID.fromString("6f3c0002-6c2a-4c1b-9c39-1b6a3d2f7a10")
        val TX: UUID = UUID.fromString("6f3c0003-6c2a-4c1b-9c39-1b6a3d2f7a10")
        val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        const val K_ENV = 1
        const val K_INV = 2
        const val K_WANT = 3
        const val K_HELLO = 4
        /** node id (4 byte) pengirim: memetakan RSSI dari hasil scan ke link (HP versi lama mengabaikan frame ini). */
        const val K_NODE = 5
        const val MAX_OUT = 4
        const val MAX_LINKS = 7
    }

    private val main = Handler(Looper.getMainLooper())
    private val manager = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val adapter: BluetoothAdapter? get() = manager.adapter
    private var server: BluetoothGattServer? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var scanner: BluetoothLeScanner? = null
    private var cid = ByteArray(8)
    private var nodeId = ByteArray(4)
    private var running = false
    private var powerSave = false
    val isRunning: Boolean get() = running
    val nodeHex: String get() = Env.hex(nodeId)

    /** HP konser ini yang terlihat di scan (node hex -> RSSI dihaluskan), termasuk yang belum/tidak tersambung. */
    class Seen(@Volatile var rssiS: Double, @Volatile var at: Long, @Volatile var addr: String) {
        @Volatile var raw = 0
        @Volatile var rawChangedAt = at
    }
    val seenNodes = ConcurrentHashMap<String, Seen>()

    /** Link aktif (client & server), kunci = alamat perangkat. */
    val links = ConcurrentHashMap<String, Link>()
    private val connecting = ConcurrentHashMap<String, Long>()
    private val cooldown = ConcurrentHashMap<String, Long>()

    // ------------------------------------------------------------ Link

    abstract inner class Link(val addr: String) {
        var mtu = 23
        var memberId = ""
        var rssi = -80
        /** RSSI dihaluskan (EMA): satu bacaan BLE bisa meleset ±10 dB. NaN = belum ada bacaan. */
        @Volatile var rssiS = Double.NaN
        @Volatile var rssiAt = 0L
        /** Waktu terakhir bacaan MENTAH berubah. Radio yang sudah putus memberi bacaan membeku (link baru lepas ±20 dtk kemudian). */
        @Volatile var rawChangedAt = 0L
        @Volatile var nodeHex = ""
        var lastSeen = System.currentTimeMillis()

        fun feed(r: Int) {
            if (r >= 0 || r < -120) return
            if (r != rssi || rawChangedAt == 0L) rawChangedAt = System.currentTimeMillis()
            rssi = r
            rssiS = if (rssiS.isNaN()) r.toDouble() else 0.35 * r + 0.65 * rssiS
            rssiAt = System.currentTimeMillis()
        }
        private var seqOut = 0
        private val queue = ConcurrentLinkedQueue<ByteArray>()
        @Volatile private var busy = false
        private val partial = HashMap<Int, Array<ByteArray?>>()

        val chunk: Int get() = (mtu - 3 - 5).coerceAtLeast(15)

        fun send(kind: Int, data: ByteArray) {
            val c = chunk
            val count = ((data.size + c - 1) / c).coerceAtLeast(1)
            if (count > 255) return
            val seq = (seqOut++) and 0xffff
            for (i in 0 until count) {
                val part = data.copyOfRange(i * c, minOf(data.size, (i + 1) * c))
                val f = ByteArray(5 + part.size)
                f[0] = kind.toByte(); f[1] = (seq shr 8).toByte(); f[2] = seq.toByte(); f[3] = i.toByte(); f[4] = count.toByte()
                System.arraycopy(part, 0, f, 5, part.size)
                queue.add(f)
            }
            pump()
        }

        fun pump() {
            if (busy) return
            val f = queue.poll() ?: return
            busy = true
            if (!write(f)) {
                busy = false
                main.postDelayed({ pump() }, 50)
            }
        }

        /** Dipanggil saat tulisan/notifikasi sebelumnya selesai. */
        fun done() {
            busy = false
            pump()
        }

        fun receive(frame: ByteArray) {
            lastSeen = System.currentTimeMillis()
            if (frame.size < 5) return
            val kind = frame[0].toInt() and 0xff
            val seq = ((frame[1].toInt() and 0xff) shl 8) or (frame[2].toInt() and 0xff)
            val idx = frame[3].toInt() and 0xff
            val count = frame[4].toInt() and 0xff
            val data = frame.copyOfRange(5, frame.size)
            if (count <= 1) { listener.onFrame(this, kind, data); return }
            val key = (kind shl 16) or seq
            val arr = partial.getOrPut(key) { arrayOfNulls(count) }
            if (idx >= arr.size) { partial.remove(key); return }
            arr[idx] = data
            if (arr.all { it != null }) {
                partial.remove(key)
                val total = arr.sumOf { it!!.size }
                val out = ByteArray(total)
                var p = 0
                for (a in arr) { System.arraycopy(a!!, 0, out, p, a.size); p += a.size }
                listener.onFrame(this, kind, out)
            }
            if (partial.size > 64) partial.clear()
        }

        abstract fun write(frame: ByteArray): Boolean
        abstract fun close()
        abstract val outgoing: Boolean
    }

    inner class ClientLink(addr: String, val gatt: BluetoothGatt) : Link(addr) {
        var rx: BluetoothGattCharacteristic? = null
        override val outgoing = true
        override fun write(frame: ByteArray): Boolean {
            val c = rx ?: return false
            return if (Build.VERSION.SDK_INT >= 33) {
                gatt.writeCharacteristic(c, frame, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                c.value = frame
                c.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                @Suppress("DEPRECATION")
                gatt.writeCharacteristic(c)
            }
        }
        override fun close() { try { gatt.disconnect(); gatt.close() } catch (_: Exception) {} }
    }

    inner class ServerLink(addr: String, val device: BluetoothDevice) : Link(addr) {
        var subscribed = false
        override val outgoing = false
        override fun write(frame: ByteArray): Boolean {
            val s = server ?: return false
            val tx = s.getService(SERVICE)?.getCharacteristic(TX) ?: return false
            if (!subscribed) return false
            return if (Build.VERSION.SDK_INT >= 33) {
                s.notifyCharacteristicChanged(device, tx, false, frame) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                tx.value = frame
                @Suppress("DEPRECATION")
                s.notifyCharacteristicChanged(device, tx, false)
            }
        }
        override fun close() { try { server?.cancelConnection(device) } catch (_: Exception) {} }
    }

    // ------------------------------------------------------------ start / stop

    fun start(cid: ByteArray, nodeId: ByteArray) {
        this.cid = cid
        this.nodeId = nodeId
        val a = adapter
        if (a == null || !a.isEnabled) { Log.w(TAG, "Bluetooth mati"); return }
        openServer()
        advertise()
        scan()
        running = true   // baru true kalau semua langkah lolos (SecurityException = izin belum ada, dicoba lagi nanti)
        main.postDelayed(maintenance, 15_000)
        main.postDelayed(rssiTask, 3_000)
    }

    /**
     * Baca RSSI koneksi keluar bergiliran, satu link tiap 1,5 dtk: stack Bluetooth Android hanya melayani SATU permintaan
     * baca RSSI pada satu waktu untuk seluruh perangkat (permintaan serentak lain dibuang diam-diam).
     * Link masuk mendapat RSSI dari scan iklan peer, dipetakan lewat node id.
     */
    private var rssiTurn = 0
    private val rssiTask = object : Runnable {
        override fun run() {
            if (!running) return
            val clients = links.values.filterIsInstance<ClientLink>()
            if (clients.isNotEmpty()) {
                val l = clients[rssiTurn++ % clients.size]
                try { l.gatt.readRemoteRssi() } catch (_: Exception) {}
            }
            val now = System.currentTimeMillis()
            seenNodes.entries.removeIf { now - it.value.at > 120_000 }
            main.postDelayed(this, 1_500)
        }
    }

    /** Kapan bacaan mentah terakhir berubah untuk link ini (dari link sendiri atau iklan scan-nya). */
    fun rawChangedAt(l: Link): Long = maxOf(l.rawChangedAt, seenNodes[l.nodeHex]?.takeIf { l.nodeHex.isNotEmpty() }?.rawChangedAt ?: 0L)

    /** RSSI terbaik yang masih segar untuk link: bacaan link sendiri, atau iklan peer yang terlihat di scan. */
    fun freshRssi(l: Link, now: Long = System.currentTimeMillis()): Double? {
        val own = if (!l.rssiS.isNaN() && now - l.rssiAt < 12_000) l.rssiS else null
        val sc = seenNodes[l.nodeHex]?.takeIf { l.nodeHex.isNotEmpty() && now - it.at < 12_000 }?.rssiS
        return when {
            own != null && sc != null -> maxOf(own, sc)
            else -> own ?: sc
        }
    }

    fun stop() {
        running = false
        main.removeCallbacksAndMessages(null)
        try { scanner?.stopScan(scanCb) } catch (_: Exception) {}
        try { advertiser?.stopAdvertising(advCb) } catch (_: Exception) {}
        links.values.forEach { it.close() }
        links.clear()
        try { server?.close() } catch (_: Exception) {}
        server = null
    }

    fun setPowerSave(on: Boolean) {
        if (powerSave == on) return
        powerSave = on
        if (running) { try { scanner?.stopScan(scanCb) } catch (_: Exception) {}; scan() }
    }

    fun broadcast(kind: Int, data: ByteArray, except: Link? = null) {
        links.values.forEach { if (it !== except) it.send(kind, data) }
    }

    private val maintenance = object : Runnable {
        override fun run() {
            if (!running) return
            val now = System.currentTimeMillis()
            // link yang diam > 90 detik dianggap putus
            links.values.filter { now - it.lastSeen > 90_000 }.forEach { it.close(); drop(it) }
            connecting.entries.removeIf { now - it.value > 20_000 }
            // advertiser kadang berhenti diam-diam di beberapa vendor: segarkan berkala
            try { advertiser?.stopAdvertising(advCb) } catch (_: Exception) {}
            advertise()
            main.postDelayed(this, 30_000)
        }
    }

    private fun drop(l: Link) {
        if (links.remove(l.addr) != null) listener.onLinkDown(l)
    }

    // ------------------------------------------------------------ GATT server

    private fun openServer() {
        server = manager.openGattServer(ctx, serverCb)
        val svc = BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        val rx = BluetoothGattCharacteristic(RX,
            BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
            BluetoothGattCharacteristic.PERMISSION_WRITE)
        val tx = BluetoothGattCharacteristic(TX, BluetoothGattCharacteristic.PROPERTY_NOTIFY, BluetoothGattCharacteristic.PERMISSION_READ)
        tx.addDescriptor(BluetoothGattDescriptor(CCCD, BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE))
        svc.addCharacteristic(rx)
        svc.addCharacteristic(tx)
        server?.addService(svc)
    }

    private val serverCb = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            val addr = device.address
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                if (links[addr] == null && links.size < MAX_LINKS) links[addr] = ServerLink(addr, device)
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                val l = links[addr]
                if (l is ServerLink) drop(l)
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            links[device.address]?.mtu = mtu
        }

        override fun onCharacteristicWriteRequest(device: BluetoothDevice, requestId: Int, c: BluetoothGattCharacteristic,
                                                  prepared: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?) {
            if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            val l = links[device.address] ?: ServerLink(device.address, device).also { links[device.address] = it }
            if (c.uuid == RX && value != null) l.receive(value)
        }

        override fun onDescriptorWriteRequest(device: BluetoothDevice, requestId: Int, d: BluetoothGattDescriptor,
                                              prepared: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?) {
            if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            val l = links[device.address]
            if (d.uuid == CCCD && l is ServerLink) {
                val on = value != null && value.isNotEmpty() && value[0].toInt() != 0
                if (on && !l.subscribed) {
                    l.subscribed = true
                    listener.onLinkUp(l)
                    l.pump()
                }
            }
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            links[device.address]?.done()
        }
    }

    // ------------------------------------------------------------ advertise

    private val advCb = object : AdvertiseCallback() {
        override fun onStartFailure(errorCode: Int) { Log.w(TAG, "advertise gagal $errorCode") }
    }

    private fun advertise() {
        advertiser = adapter?.bluetoothLeAdvertiser ?: return
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(if (powerSave) AdvertiseSettings.ADVERTISE_MODE_LOW_POWER else AdvertiseSettings.ADVERTISE_MODE_BALANCED)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .build()
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(SERVICE))
            .addServiceData(ParcelUuid(SERVICE), cid + nodeId)
            .build()
        try { advertiser?.startAdvertising(settings, data, advCb) } catch (e: Exception) { Log.w(TAG, "advertise: $e") }
    }

    // ------------------------------------------------------------ scan + connect

    private val scanCb = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) = handle(result)
        override fun onBatchScanResults(results: MutableList<ScanResult>) = results.forEach { handle(it) }
        override fun onScanFailed(errorCode: Int) { Log.w(TAG, "scan gagal $errorCode") }
    }

    private fun scan() {
        scanner = adapter?.bluetoothLeScanner ?: return
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE)).build()
        val settings = ScanSettings.Builder()
            .setScanMode(if (powerSave) ScanSettings.SCAN_MODE_LOW_POWER else ScanSettings.SCAN_MODE_BALANCED)
            .setReportDelay(0)
            .build()
        try { scanner?.startScan(listOf(filter), settings, scanCb) } catch (e: Exception) { Log.w(TAG, "scan: $e") }
    }

    private fun handle(r: ScanResult) {
        val sd = r.scanRecord?.getServiceData(ParcelUuid(SERVICE)) ?: return
        if (sd.size < 12) return
        if (!sd.copyOfRange(0, 8).contentEquals(cid)) return // konser lain
        val peerNode = sd.copyOfRange(8, 12)
        val addr = r.device.address
        val now = System.currentTimeMillis()
        val ph = Env.hex(peerNode)
        val s = seenNodes[ph]
        if (s == null) seenNodes[ph] = Seen(r.rssi.toDouble(), now, addr).also { it.raw = r.rssi }
        else {
            if (r.rssi != s.raw) { s.raw = r.rssi; s.rawChangedAt = now }
            s.rssiS = 0.35 * r.rssi + 0.65 * s.rssiS; s.at = now; s.addr = addr
        }
        listener.onScanSeen(addr, r.rssi)
        links[addr]?.let { it.feed(r.rssi); it.lastSeen = now; return }
        // satu koneksi per pasangan: hanya node dengan id lebih kecil yang menyambung
        if (compare(nodeId, peerNode) >= 0) return
        if (connecting.containsKey(addr)) return
        if ((cooldown[addr] ?: 0) > System.currentTimeMillis()) return
        if (links.values.count { it.outgoing } >= MAX_OUT || links.size >= MAX_LINKS) return
        connecting[addr] = System.currentTimeMillis()
        val rssi = r.rssi
        main.post { connect(r.device, rssi, ph) }
    }

    private fun compare(a: ByteArray, b: ByteArray): Int {
        for (i in a.indices) {
            val x = a[i].toInt() and 0xff
            val y = b[i].toInt() and 0xff
            if (x != y) return x - y
        }
        return 0
    }

    private fun connect(device: BluetoothDevice, rssi: Int, peerNodeHex: String) {
        val gatt = if (Build.VERSION.SDK_INT >= 23) device.connectGatt(ctx, false, clientCb, BluetoothDevice.TRANSPORT_LE)
        else device.connectGatt(ctx, false, clientCb)
        if (gatt == null) { connecting.remove(device.address); return }
        val l = ClientLink(device.address, gatt)
        l.feed(rssi)
        l.nodeHex = peerNodeHex
        links[device.address] = l
    }

    private val clientCb = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            val addr = gatt.device.address
            if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                gatt.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_BALANCED)
                if (!gatt.requestMtu(517)) gatt.discoverServices()
            } else {
                connecting.remove(addr)
                cooldown[addr] = System.currentTimeMillis() + 10_000
                val l = links[addr]
                if (l is ClientLink) { l.close(); drop(l) } else try { gatt.close() } catch (_: Exception) {}
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            links[gatt.device.address]?.mtu = if (status == BluetoothGatt.GATT_SUCCESS) mtu else 23
            gatt.discoverServices()
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            val l = links[gatt.device.address] as? ClientLink ?: return
            val svc = gatt.getService(SERVICE)
            val rx = svc?.getCharacteristic(RX)
            val tx = svc?.getCharacteristic(TX)
            if (rx == null || tx == null) { l.close(); drop(l); return }
            l.rx = rx
            gatt.setCharacteristicNotification(tx, true)
            val d = tx.getDescriptor(CCCD)
            if (Build.VERSION.SDK_INT >= 33) {
                gatt.writeDescriptor(d, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
            } else {
                @Suppress("DEPRECATION")
                d.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                @Suppress("DEPRECATION")
                gatt.writeDescriptor(d)
            }
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            val l = links[gatt.device.address] ?: return
            connecting.remove(gatt.device.address)
            listener.onLinkUp(l)
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
            links[gatt.device.address]?.done()
        }

        @Deprecated("API < 33")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, c: BluetoothGattCharacteristic) {
            @Suppress("DEPRECATION")
            if (c.uuid == TX) links[gatt.device.address]?.receive(c.value ?: return)
        }

        override fun onCharacteristicChanged(gatt: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray) {
            if (c.uuid == TX) links[gatt.device.address]?.receive(value)
        }

        override fun onReadRemoteRssi(gatt: BluetoothGatt, rssi: Int, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) links[gatt.device.address]?.feed(rssi)
        }
    }
}
