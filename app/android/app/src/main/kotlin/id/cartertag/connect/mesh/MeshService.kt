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

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        store = RelayStore(this)
        workerThread.start()
        worker = Handler(workerThread.looper)
        ble = BleMesh(this, this)
        channels()
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
        if (Build.VERSION.SDK_INT >= 34) startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        else startForeground(NOTIF_ID, n)
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
        try { unregisterReceiver(btReceiver) } catch (_: Exception) {}
        ble.stop()
        bridge?.stop()
        workerThread.quitSafely()
        MeshBus.emitState(false)
        super.onDestroy()
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

    fun peersSnapshot(): List<Map<String, Any>> = ble.links.values.map {
        mapOf("addr" to it.addr, "mid" to it.memberId, "rssi" to it.rssi, "via" to "ble", "connected" to true, "ls" to it.lastSeen)
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
            val inv = store.inventory(c.cid, 400)
            if (inv.isNotEmpty()) link.send(BleMesh.K_INV, inv.fold(ByteArray(0)) { acc, h -> acc + Env.unhex(h) })
            emitPeers()
        }
    }

    override fun onLinkDown(link: BleMesh.Link) { worker.post { emitPeers() } }

    override fun onScanSeen(addr: String, rssi: Int) {}

    override fun onFrame(link: BleMesh.Link, kind: Int, data: ByteArray) {
        worker.post {
            when (kind) {
                BleMesh.K_ENV -> accept(data, link, null)
                BleMesh.K_HELLO -> { link.memberId = String(data, Charsets.US_ASCII).trim(); emitPeers() }
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
