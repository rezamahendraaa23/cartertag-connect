package id.cartertag.connect.mesh

import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.*
import android.util.Log
import androidx.core.app.NotificationCompat
import id.cartertag.connect.MainActivity
import id.cartertag.connect.R
import org.json.JSONObject
import java.util.LinkedHashMap
import java.util.concurrent.ConcurrentHashMap
import kotlin.random.Random

/**
 * Foreground service mesh: tetap hidup saat UI ditutup atau HP terkunci.
 * Router: dedup, TTL, relay dengan jeda acak, simpan-teruskan, sinkron inventaris, gerbang ke klien jembatan.
 * Hanya memindahkan ciphertext; dekripsi terjadi di Flutter.
 */
class MeshService : Service(), BleMesh.Listener, BridgeServer.Listener {

    companion object {
        const val CH_SVC = "ct_mesh_service"
        const val CH_MSG = "ct_mesh_msg"
        const val CH_SOS = "ct_sos_native"
        const val NOTIF_ID = 1
        var instance: MeshService? = null
            private set

        fun start(ctx: Context, cid: String, mid: String, concert: String, names: Map<String, String>) {
            MeshBus.config = MeshConfig(cid, mid, concert, ConcurrentHashMap(names))
            val i = Intent(ctx, MeshService::class.java)
            if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, MeshService::class.java))
        }
    }

    private lateinit var store: RelayStore
    private lateinit var ble: BleMesh
    private var bridge: BridgeServer? = null
    private lateinit var worker: Handler
    private val workerThread = HandlerThread("ct-router")
    private val main = Handler(Looper.getMainLooper())
    private val seen = object : LinkedHashMap<String, Long>(4096, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Long>?) = size > 20_000
    }
    private val rate = HashMap<String, ArrayDeque<Long>>()
    private var cfg: MeshConfig? = null
    private var notifSeq = 100
    private lateinit var reach: ReachWatch
    /** node hex -> member_id (dari link yang sudah bertukar hello + node), untuk HP yang terlihat di scan tapi belum tersambung. */
    private val nodeMid = ConcurrentHashMap<String, String>()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        store = RelayStore(this)
        workerThread.start()
        worker = Handler(workerThread.looper)
        ble = BleMesh(this, this)
        channels()
        reach = ReachWatch(this)
        loadReach()
        // status internet/layar yang dikirim Flutter sebelum service sempat hidup (startForegroundService asinkron)
        if (System.currentTimeMillis() - MeshBus.netAt < 45_000) {
            reach.appOnline = MeshBus.netOnline
            reach.appOnlineAt = MeshBus.netAt
        }
        uiForeground = MeshBus.netFg && MeshBus.sink != null
        worker.postDelayed(reachTask, 3_000)
        val f = android.content.IntentFilter(android.bluetooth.BluetoothAdapter.ACTION_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(btReceiver, f, Context.RECEIVER_NOT_EXPORTED) else registerReceiver(btReceiver, f)
    }

    /** Bluetooth dinyalakan/dimatikan pengguna: hidupkan/matikan mesh mengikuti. */
    private val btReceiver = object : android.content.BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            val st = intent.getIntExtra(android.bluetooth.BluetoothAdapter.EXTRA_STATE, -1)
            val c = cfg ?: return
            if (st == android.bluetooth.BluetoothAdapter.STATE_ON && !ble.isRunning) {
                main.postDelayed({ try { ble.start(Env.unhex(c.cid), Random.nextBytes(4)) } catch (_: SecurityException) {} }, 1000)
            } else if (st == android.bluetooth.BluetoothAdapter.STATE_OFF) {
                ble.stop(); emitPeers()
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val c = MeshBus.config ?: MeshBus.loadConfig(this)
        if (c == null) { stopSelf(); return START_NOT_STICKY }
        MeshBus.saveConfig(this, c)
        val n = foregroundNotification(c)
        try {
            if (Build.VERSION.SDK_INT >= 34) startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            else startForeground(NOTIF_ID, n)
        } catch (e: Exception) {
            // izin Bluetooth dicabut / dilarang start dari latar: berhenti rapi, app tetap jalan lewat internet
            Log.w(BleMesh.TAG, "startForeground ditolak: $e")
            stopSelf()
            return START_NOT_STICKY
        }
        if (cfg?.cid != c.cid) {
            ble.stop()
            cfg = c
            try {
                ble.start(Env.unhex(c.cid), Random.nextBytes(4))
            } catch (e: SecurityException) {
                Log.w(BleMesh.TAG, "izin Bluetooth belum diberikan: $e")   // service tetap hidup; jembatan & relay jalan setelah izin diberi + app dibuka ulang
            }
        } else {
            cfg = c   // konser sama: cukup perbarui nama/member, BLE tidak diputus
            if (!ble.isRunning) try { ble.start(Env.unhex(c.cid), Random.nextBytes(4)) } catch (_: SecurityException) {}
        }
        MeshBus.emitState(true)
        worker.postDelayed(pruneTask, 60_000)
        return START_STICKY
    }

    override fun onDestroy() {
        instance = null
        try { reach.cancel() } catch (_: Exception) {}   // jangan tinggalkan alarm "Terputus" setelah keluar konser
        try { unregisterReceiver(btReceiver) } catch (_: Exception) {}
        ble.stop()
        bridge?.stop()
        workerThread.quitSafely()
        MeshBus.emitState(false)
        super.onDestroy()
    }

    /** Tiap 3 dtk: nilai jangkauan (peringatan native) + kirim daftar HP sekitar beserta sinyalnya ke UI. */
    private val reachTask = object : Runnable {
        override fun run() {
            try {
                val now = System.currentTimeMillis()
                val linked = if (ble.isRunning) ble.links.values.toList() else emptyList()
                val evidence = linked.map { it.memberId to ble.freshRssi(it, now) } +
                    // HP tim yang masih terlihat di scan (belum/sedang sambung ulang) = masih dalam jangkauan
                    (if (ble.isRunning) ble.seenNodes.entries
                        .filter { e -> now - e.value.at < 12_000 && linked.none { it.nodeHex == e.key || it.addr == e.value.addr } }
                        .map { (nodeMid[it.key] ?: "") to it.value.rssiS } else emptyList())
                val btOn = try { android.bluetooth.BluetoothAdapter.getDefaultAdapter()?.isEnabled == true } catch (_: Exception) { true }
                // UI mati melewati 06.00: "hari konser aktif" kedaluwarsa sendiri
                if (reach.active && activeDay != today()) reach.active = false
                val changed = reach.tick(evidence, cfg?.names ?: emptyMap(), btOn)
                // UI di latar: kirim hanya kalau berubah (Dart tidak perlu bangun tiap 3 dtk saat layar mati)
                if (uiForeground) emitPeers()
                if (changed || uiForeground) MeshBus.emitReach(reachState())
            } catch (e: Exception) { Log.w(BleMesh.TAG, "reach: $e") }
            worker.postDelayed(this, 3_000)
        }
    }

    fun reachState(): Map<String, Any> = mapOf(
        "st" to reach.state, "best" to (reach.best ?: 0.0), "mid" to reach.bestMid,
        "weak" to reach.weakDbm, "enabled" to reach.enabled, "mute" to reach.muteUntil)

    @Volatile private var uiForeground = false

    /** Dari Flutter: status internet nyata (Firebase) + app sedang di layar. Dipanggil saat berubah & berkala. */
    fun setNet(online: Boolean?, foreground: Boolean) {
        if (online != null) {
            reach.appOnline = online
            reach.appOnlineAt = System.currentTimeMillis()
        }
        val wasFg = uiForeground
        uiForeground = foreground
        if (foreground && !wasFg) worker.post { emitPeers(); MeshBus.emitReach(reachState()) }
    }

    /** Dari Flutter: aktif/nonaktif peringatan + ambang RSSI melemah (kalibrasi) + diam sementara. Disimpan untuk service yang hidup sendiri. */
    fun setReach(enabled: Boolean, weakDbm: Double, muteUntil: Long, active: Boolean) {
        reach.enabled = enabled
        reach.weakDbm = weakDbm.coerceIn(-100.0, -60.0)
        reach.active = active
        activeDay = today()
        val wasMuted = reach.muteUntil > System.currentTimeMillis()
        reach.muteUntil = muteUntil
        if (!wasMuted && muteUntil > System.currentTimeMillis()) worker.post { reach.onMuted() }   // state ditulis di worker
        getSharedPreferences("ct_reach", Context.MODE_PRIVATE).edit()
            .putBoolean("enabled", enabled).putFloat("weak", reach.weakDbm.toFloat()).putLong("mute", muteUntil)
            .putBoolean("active", active).putString("activeDay", today()).apply()
        if (!enabled || muteUntil > System.currentTimeMillis()) reach.cancel()
        worker.post { MeshBus.emitReach(reachState()) }
    }

    private fun loadReach() {
        val p = getSharedPreferences("ct_reach", Context.MODE_PRIVATE)
        reach.enabled = p.getBoolean("enabled", true)
        reach.weakDbm = p.getFloat("weak", -88f).toDouble()
        reach.muteUntil = p.getLong("mute", 0L)
        // "aktif" hanya berlaku untuk hari (mulai 06.00) saat disimpan: service yang hidup sendiri besok tidak ikut aktif
        activeDay = p.getString("activeDay", "") ?: ""
        reach.active = p.getBoolean("active", false) && activeDay == today()
    }

    @Volatile private var activeDay = ""

    /** Hari konser lokal (mulai 06.00), sama dengan Hub.concertDay di Dart. */
    private fun today(): String {
        val c = java.util.Calendar.getInstance().apply { timeInMillis = System.currentTimeMillis() - 6 * 3_600_000L }
        return String.format(java.util.Locale.US, "%04d-%02d-%02d", c.get(java.util.Calendar.YEAR), c.get(java.util.Calendar.MONTH) + 1, c.get(java.util.Calendar.DAY_OF_MONTH))
    }

    private val pruneTask = object : Runnable {
        override fun run() {
            try { store.prune() } catch (_: Exception) {}
            worker.postDelayed(this, 10 * 60_000)
        }
    }

    // ------------------------------------------------------------ API dari Flutter

    /** Envelope buatan HP ini (sudah ditandatangani & dienkripsi di Dart). */
    fun sendLocal(bytes: ByteArray) = worker.post {
        val env = Env.parse(bytes) ?: return@post
        val id = env.idHex
        synchronized(seen) { seen[id] = System.currentTimeMillis() }
        if (env.type != Env.T_LOC) store.put(env)
        ble.broadcast(BleMesh.K_ENV, bytes)
        bridge?.clients?.values?.forEach { if (it.approved) it.binary(bytes) }
    }

    fun setNames(names: Map<String, String>) {
        cfg?.names?.putAll(names)
        cfg?.let { MeshBus.saveConfig(this, it) }
    }

    fun setPowerSave(on: Boolean) = ble.setPowerSave(on)

    fun drain(): List<ByteArray> = store.inboxDrain()

    /**
     * HP tim yang tersambung (connected) + yang hanya terlihat di scan (connected=false, mis. batas link penuh).
     * rs = RSSI dihaluskan & masih segar (dBm), 0 = belum ada bacaan.
     */
    fun peersSnapshot(): List<Map<String, Any>> {
        val now = System.currentTimeMillis()
        val linked = ble.links.values.map {
            if (it.memberId.isNotEmpty() && it.nodeHex.isNotEmpty()) nodeMid[it.nodeHex] = it.memberId
            mapOf("addr" to it.addr, "mid" to it.memberId, "rssi" to it.rssi, "rs" to (ble.freshRssi(it, now) ?: 0.0),
                "via" to "ble", "connected" to true, "ls" to it.lastSeen, "node" to it.nodeHex, "rc" to ble.rawChangedAt(it))
        }
        val linkedNodes = ble.links.values.map { it.nodeHex }.toSet()
        val linkedAddr = ble.links.keys.toSet()
        // HP versi lama tidak mengirim node id: saring juga lewat alamat supaya tidak tampil ganda
        val seen = ble.seenNodes.entries.filter { it.key !in linkedNodes && it.value.addr !in linkedAddr && now - it.value.at < 12_000 }.map {
            mapOf("addr" to it.value.addr, "mid" to (nodeMid[it.key] ?: ""), "rssi" to it.value.rssiS.toInt(), "rs" to it.value.rssiS,
                "via" to "ble", "connected" to false, "ls" to it.value.at, "node" to it.key, "rc" to it.value.rawChangedAt)
        }
        return linked + seen
    }

    fun status(): Map<String, Any> = mapOf(
        "running" to true,
        "links" to ble.links.size,
        "bridgeClients" to (bridge?.clients?.size ?: 0),
        "bridge" to (bridge?.info ?: emptyMap<String, Any>())
    )

    // ------------------------------------------------------------ router

    private fun accept(bytes: ByteArray, from: BleMesh.Link?, fromClient: String?) {
        val env = Env.parse(bytes) ?: return
        val c = cfg ?: return
        if (env.cidHex != c.cid) return
        val id = env.idHex
        synchronized(seen) {
            if (seen.containsKey(id)) return
            seen[id] = System.currentTimeMillis()
        }
        if (store.has(id)) return
        if (!allowRate(env)) return
        if (env.type != Env.T_LOC) store.put(env)

        // ke UI (atau inbox + notifikasi kalau UI tidak berjalan)
        val via = if (fromClient != null) "bridge" else "ble"
        if (!MeshBus.emitEnvelope(bytes, via)) {
            if (env.type != Env.T_LOC) store.inboxAdd(env)
            notifyNative(env)
        }

        // ke klien jembatan lain
        bridge?.clients?.values?.forEach { if (it.approved && it.id != fromClient) it.binary(bytes) }

        // relay BLE dengan jeda acak (mengurangi tabrakan siaran)
        if (env.hop + 1 < env.ttl || fromClient != null) {
            val out = if (fromClient != null) bytes else env.relayed()
            val delay = if (env.prio >= 2) Random.nextLong(10, 80) else Random.nextLong(50, 300)
            worker.postDelayed({ ble.broadcast(BleMesh.K_ENV, out, except = from) }, delay)
        }
    }

    /** Maks 30 envelope/menit per pengirim (SOS dikecualikan). */
    private fun allowRate(env: Env): Boolean {
        if (env.prio >= 2) return true
        val now = System.currentTimeMillis()
        val q = rate.getOrPut(env.from) { ArrayDeque() }
        while (q.isNotEmpty() && now - q.first() > 60_000) q.removeFirst()
        if (q.size >= 30) return false
        q.addLast(now)
        return true
    }

    // ---- BleMesh.Listener (dipanggil dari thread binder; pindah ke worker)

    override fun onLinkUp(link: BleMesh.Link) {
        worker.post {
            val c = cfg ?: return@post
            link.send(BleMesh.K_HELLO, c.mid.toByteArray(Charsets.US_ASCII))
            link.send(BleMesh.K_NODE, Env.unhex(ble.nodeHex))
            val inv = store.inventory(c.cid, 400)
            if (inv.isNotEmpty()) link.send(BleMesh.K_INV, inv.fold(ByteArray(0)) { acc, h -> acc + Env.unhex(h) })
            emitPeers()
        }
    }

    override fun onLinkDown(link: BleMesh.Link) {
        worker.post {
            // RSSI terakhir saat putus: Flutter memakainya untuk menilai "menjauh" (lemah) vs putus biasa (kuat), juga saat layar mati
            if (link.memberId.isNotEmpty()) {
                val rs = if (!link.rssiS.isNaN()) link.rssiS else link.rssi.toDouble()
                MeshBus.emitLinkDown(mapOf("mid" to link.memberId, "rs" to rs, "at" to System.currentTimeMillis()))
            }
            emitPeers()
        }
    }

    override fun onScanSeen(addr: String, rssi: Int) {}

    override fun onFrame(link: BleMesh.Link, kind: Int, data: ByteArray) {
        worker.post {
            when (kind) {
                BleMesh.K_ENV -> accept(data, link, null)
                BleMesh.K_HELLO -> { link.memberId = String(data, Charsets.US_ASCII).trim(); emitPeers() }
                BleMesh.K_NODE -> if (data.size >= 4) { link.nodeHex = Env.hex(data.copyOfRange(0, 4)); emitPeers() }
                BleMesh.K_INV -> {
                    val want = ArrayList<ByteArray>()
                    var i = 0
                    while (i + 16 <= data.size) {
                        val id = data.copyOfRange(i, i + 16)
                        val h = Env.hex(id)
                        val known = synchronized(seen) { seen.containsKey(h) } || store.has(h)
                        if (!known) want.add(id)
                        i += 16
                    }
                    if (want.isNotEmpty()) link.send(BleMesh.K_WANT, want.fold(ByteArray(0)) { acc, b -> acc + b })
                }
                BleMesh.K_WANT -> {
                    var i = 0
                    while (i + 16 <= data.size) {
                        store.get(Env.hex(data.copyOfRange(i, i + 16)))?.let { link.send(BleMesh.K_ENV, it) }
                        i += 16
                    }
                }
            }
        }
    }

    private fun emitPeers() = MeshBus.emitPeers(peersSnapshot())

    // ------------------------------------------------------------ jembatan

    fun bridgeStart(cb: (Map<String, Any>?, String?) -> Unit) {
        val b = bridge ?: BridgeServer(this, this).also { bridge = it }
        if (b.info.isNotEmpty()) { cb(b.info, null); return }
        b.start(cb)
    }

    fun bridgeStop() { bridge?.stop(); bridge = null }

    fun bridgeReply(client: String, json: String) = worker.post {
        val c = bridge?.clients?.get(client) ?: return@post
        c.text(json)
        val t = try { JSONObject(json).optString("t") } catch (_: Exception) { "" }
        if (t == "welcome") {
            c.approved = true
            val cf = cfg ?: return@post
            store.recent(cf.cid, 300).forEach { c.binary(it) }
        } else if (t == "denied") {
            main.postDelayed({ c.close() }, 500)
        }
    }

    fun bridgeKick(client: String) { bridge?.clients?.get(client)?.close() }

    override fun onClientText(client: String, text: String) {
        if (!MeshBus.emitBridge(mapOf("e" to "bridge_msg", "client" to client, "data" to text))) {
            bridge?.clients?.get(client)?.text("{\"t\":\"denied\",\"reason\":\"Buka aplikasi CarterTag Connect di HP host.\"}")
        }
    }

    override fun onClientBinary(client: String, data: ByteArray) { worker.post { accept(data, null, client) } }

    override fun onClientState(client: String, state: String) {
        MeshBus.emitBridge(mapOf("e" to "bridge_client", "client" to client, "state" to state))
    }

    // ------------------------------------------------------------ notifikasi (UI tidak berjalan)

    private fun channels() {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CH_SVC, "Mesh aktif", NotificationManager.IMPORTANCE_LOW).apply {
            description = "Menjaga koneksi antar-HP tanpa internet"
        })
        nm.createNotificationChannel(NotificationChannel(CH_MSG, "Pesan (offline)", NotificationManager.IMPORTANCE_HIGH))
        nm.createNotificationChannel(NotificationChannel(CH_SOS, "SOS (offline)", NotificationManager.IMPORTANCE_HIGH).apply {
            setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM),
                AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 800, 400, 800, 400, 800)
        })
    }

    private fun openApp(route: String): PendingIntent {
        val i = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("route", route)
        }
        return PendingIntent.getActivity(this, route.hashCode(), i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    private fun foregroundNotification(c: MeshConfig): Notification =
        NotificationCompat.Builder(this, CH_SVC)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("CarterTag Connect aktif")
            .setContentText("${c.concert} · siap kirim pesan tanpa internet")
            .setOngoing(true)
            .setContentIntent(openApp("chat"))
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

    private fun notifyNative(env: Env) {
        val c = cfg ?: return
        if (env.from == c.mid) return
        val name = c.names[env.from] ?: "Anggota tim"
        val nm = getSystemService(NotificationManager::class.java)
        when (env.type) {
            Env.T_SOS -> {
                val n = NotificationCompat.Builder(this, CH_SOS)
                    .setSmallIcon(R.mipmap.ic_launcher)
                    .setContentTitle("SOS dari $name")
                    .setContentText("Buka untuk melihat arah & jarak")
                    .setCategory(NotificationCompat.CATEGORY_ALARM)
                    .setPriority(NotificationCompat.PRIORITY_MAX)
                    .setFullScreenIntent(openApp("sos"), true)
                    .setContentIntent(openApp("sos"))
                    .setAutoCancel(true)
                    .build()
                n.flags = n.flags or Notification.FLAG_INSISTENT
                nm.notify(7, n)
            }
            Env.T_CHAT, Env.T_ANN, Env.T_ROLLCALL -> {
                val (title, text) = when (env.type) {
                    Env.T_ANN -> "Pengumuman baru" to "Dari $name"
                    Env.T_ROLLCALL -> "Absen dari $name" to "Tandai kondisimu"
                    else -> name to if ((env.flags and 1) == 1) "Pesan pribadi baru (offline)" else "Pesan baru di grup (offline)"
                }
                val n = NotificationCompat.Builder(this, CH_MSG)
                    .setSmallIcon(R.mipmap.ic_launcher)
                    .setContentTitle(title)
                    .setContentText(text)
                    .setContentIntent(openApp(if (env.type == Env.T_CHAT) "chat" else "info"))
                    .setAutoCancel(true)
                    .setPriority(NotificationCompat.PRIORITY_HIGH)
                    .build()
                nm.notify(notifSeq++, n)
            }
        }
    }
}

data class MeshConfig(val cid: String, val mid: String, val concert: String, val names: ConcurrentHashMap<String, String>)
