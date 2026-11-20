package id.cartertag.connect.mesh

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.util.Log
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.util.concurrent.ConcurrentHashMap

/**
 * "Wi-Fi posko": HP yang tersambung ke Wi-Fi yang sama (mis. travel router dicolok powerbank, TANPA internet) saling
 * kirim envelope lewat UDP broadcast di jaringan lokal. Jangkauan router ±50–100 m, jauh lebih luas dari Bluetooth HP.
 *
 * Paket: "CTL1" + jenis (1) + cid konser (8) + node pengirim (4) + isi.
 *   jenis 1 = envelope, 2 = hello (isi = member_id ASCII), dikirim tiap 4 dtk supaya HP lain tahu siapa saja di Wi-Fi ini.
 * Socket diikat ke jaringan Wi-Fi itu sendiri: Android memakai data seluler sebagai jaringan utama kalau Wi-Fi tidak ada
 * internetnya, dan siaran ke router harus tetap lewat Wi-Fi.
 * Router: matikan "AP / client isolation" supaya HP bisa saling kirim.
 */
class LanMesh(private val ctx: Context, private val listener: Listener) {

    interface Listener {
        /** handoff=true: pesan bawaan HP yang baru masuk (dikirim ke leader saja) -> leader meneruskan yang baru ke HP posko lain. */
        fun onLanEnvelope(bytes: ByteArray, fromIp: String, handoff: Boolean)
        /** HP tim (baru / kembali) muncul di Wi-Fi ini: kirimkan pesan simpanan supaya dia menyusul.
         *  goneAt = kapan dia terakhir terlihat sebelum hilang (0 = belum pernah). */
        fun onLanPeerNew(node: String, ip: String, goneAt: Long)
        fun onLanPeersChanged()
        /** HP ini sudah 12 dtk di Wi-Fi: serahkan pesan yang dibawanya ke HP posko (susulan dua arah). */
        /** closedAt = kapan socket Wi-Fi sebelumnya ditutup (0 = sesi pertama): cukup kirim pesan sejak saat itu. */
        fun onLanSettled(leaderIp: String, closedAt: Long)
    }

    class Peer(@Volatile var ip: String, @Volatile var mid: String, @Volatile var lastSeen: Long, @Volatile var sess: String = "") {
        /** lastSeen sebelum hello terakhir (K_SESS datang tepat sesudah hello: dipakai sebagai "terakhir terlihat sebelum putus"). */
        @Volatile var prevSeen = lastSeen
    }

    companion object {
        const val PORT = 47817
        const val K_ENV: Byte = 1
        const val K_HELLO: Byte = 2
        const val K_HANDOFF: Byte = 3
        /** Nomor sesi socket (paket terpisah: hello tetap berisi member_id saja, cocok dengan HP 1.5). */
        const val K_SESS: Byte = 4
        private val MAGIC = byteArrayOf('C'.code.toByte(), 'T'.code.toByte(), 'L'.code.toByte(), '1'.code.toByte())
        private const val HDR = 4 + 1 + 8 + 4
        /** 5–6 hello boleh hilang (udara 2,4 GHz konser padat, HP layar mati) sebelum dianggap pergi. */
        const val PEER_TTL_MS = 25_000L
    }

    val peers = ConcurrentHashMap<String, Peer>()   // node hex -> peer
    /** node -> kapan terakhir terlihat sebelum hilang (untuk susulan sejak saat itu ketika dia kembali). */
    private val gone = ConcurrentHashMap<String, Long>()
    @Volatile private var settledSent = false
    @Volatile var running = false; private set
    @Volatile private var socket: DatagramSocket? = null
    @Volatile private var network: Network? = null
    @Volatile private var bcast: InetAddress? = null
    @Volatile private var openedAt = 0L
    @Volatile private var closedAt = 0L
    /** HP yang terdengar di sesi socket saya sebelumnya: kalau muncul lagi di 10 dtk pertama, merekalah yang menyusulkan saya. */
    private val prevPeers = ConcurrentHashMap.newKeySet<String>()
    /** HP benar-benar baru yang muncul di 10 dtk pertama sesi saya: diproses setelah 10 dtk (node -> goneAt). */
    private val deferred = ConcurrentHashMap<String, Long>()
    /** Nomor sesi socket (naik tiap buka ulang), ikut di hello: HP lain tahu saya sempat putus walau < TTL. */
    @Volatile private var sess = 0
    private fun helloBody() = mid.toByteArray(Charsets.US_ASCII)
    private fun sendHello() {
        send(K_HELLO, helloBody())
        send(K_SESS, byteArrayOf(sess.toByte()))
    }

    /** HP 1.6+ (pernah mengirim K_SESS) mengerti serah-terima; HP 1.5 hanya K_ENV. */
    fun handoffKind(ip: String): Byte = if (peers.values.any { it.ip == ip && it.sess.isNotEmpty() }) K_HANDOFF else K_ENV
    private var cid = ByteArray(8)
    private var node = ByteArray(4)
    private var mid = ""
    private var lock: WifiManager.MulticastLock? = null
    private var rx: Thread? = null
    private var hello: Thread? = null
    private val cm = ctx.getSystemService(ConnectivityManager::class.java)

    private val keepCb = object : ConnectivityManager.NetworkCallback() {}

    private val netCb = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(n: Network) { openOn(n) }
        // LinkProperties sesaat tanpa IPv4: pertahankan alamat siaran lama (jangan jadi null & diam)
        override fun onLinkPropertiesChanged(n: Network, lp: LinkProperties) { if (n == network) bcast = broadcastOf(lp) ?: bcast }
        override fun onLost(n: Network) { if (n == network) closeSocket() }
    }

    fun start(cid: ByteArray, node: ByteArray, mid: String) {
        stop()
        this.cid = cid; this.node = node; this.mid = mid
        running = true
        val req = NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).build()   // Wi-Fi posko memang tanpa internet
        try { cm.registerNetworkCallback(req, netCb) } catch (e: Exception) { Log.w(BleMesh.TAG, "lan callback: $e") }
        // permintaan aktif: Android/OEM tidak melepas Wi-Fi tanpa internet yang "tidak dipakai" selama app memintanya
        try { cm.requestNetwork(req, keepCb) } catch (e: Exception) { Log.w(BleMesh.TAG, "lan request: $e") }
        hello = Thread({
            while (running) {
                try {
                    sendHello()
                    val now = System.currentTimeMillis()
                    val old = peers.entries.filter { now - it.value.lastSeen > PEER_TTL_MS }
                    if (old.isNotEmpty()) {
                        old.forEach { gone[it.key] = it.value.lastSeen; peers.remove(it.key) }
                        listener.onLanPeersChanged()
                    }
                    if (deferred.isNotEmpty() && openedAt > 0 && now - openedAt >= 10_000) {
                        val d = HashMap(deferred); deferred.clear()
                        d.forEach { (n, g) -> peers[n]?.let { listener.onLanPeerNew(n, it.ip, g) } }
                    }
                    // sudah 12 dtk di Wi-Fi ini: serahkan pesan bawaan ke HP posko (node terkecil) sekali per sesi
                    if (!settledSent && socket != null && openedAt > 0 && now - openedAt > 12_000) {
                        val leader = peers.entries.minByOrNull { it.key }
                        if (leader != null) { settledSent = true; listener.onLanSettled(leader.value.ip, closedAt) }
                    }
                    Thread.sleep(4_000)
                } catch (_: InterruptedException) { break } catch (_: Exception) {}
            }
        }, "ct-lan-hello").apply { isDaemon = true; start() }
    }

    fun stop() {
        running = false
        try { cm.unregisterNetworkCallback(netCb) } catch (_: Exception) {}
        try { cm.unregisterNetworkCallback(keepCb) } catch (_: Exception) {}
        hello?.interrupt(); hello = null
        closeSocket()
        if (peers.isNotEmpty()) { peers.clear(); listener.onLanPeersChanged() }
    }

    /**
     * Kirim envelope ke semua HP tim di Wi-Fi ini. Unicast ke tiap HP yang dikenal: Wi-Fi memberi tanda terima & mengulang
     * paket yang hilang, dengan kecepatan penuh (siaran dikirim 1 Mbps tanpa ulang -> di udara konser padat sering hilang).
     * Siaran hanya kalau belum ada HP yang dikenal.
     */
    fun sendEnv(data: ByteArray) {
        val now = System.currentTimeMillis()
        val list = peers.values.filter { now - it.lastSeen < PEER_TTL_MS }
        if (list.isEmpty()) send(K_ENV, data) else list.forEach { sendTo(it.ip, K_ENV, data) }
    }

    /** Teruskan ke semua HP yang dikenal kecuali [exceptIp] (serah-terima dari HP yang baru masuk). */
    fun sendEnvExcept(data: ByteArray, exceptIp: String) {
        val now = System.currentTimeMillis()
        peers.values.filter { now - it.lastSeen < PEER_TTL_MS && it.ip != exceptIp }.forEach { sendTo(it.ip, K_ENV, data) }
    }

    @Volatile private var subnet: Pair<Int, Int>? = null   // (alamat jaringan, mask)
    private fun sameSubnet(a: InetAddress?): Boolean {
        val s = subnet ?: return true
        val b = (a as? Inet4Address)?.address ?: return false
        val v = ((b[0].toInt() and 0xff) shl 24) or ((b[1].toInt() and 0xff) shl 16) or ((b[2].toInt() and 0xff) shl 8) or (b[3].toInt() and 0xff)
        return (v and s.second) == s.first
    }

    /** Kirim langsung ke satu HP (unicast: Wi-Fi mengulang otomatis kalau gagal, lebih andal dari siaran). */
    fun sendTo(ip: String, kind: Byte, data: ByteArray) {
        val s = socket ?: return
        if (data.size > 60_000 || ip.isEmpty()) return
        try { s.send(DatagramPacket(packet(kind, data), HDR + data.size, InetAddress.getByName(ip), PORT)) } catch (e: Exception) { Log.w(BleMesh.TAG, "lan sendTo: $e") }
    }

    /** HP ini yang bertugas menyusulkan pesan ke [newNode]: node terkecil di antara HP yang sudah ada di Wi-Fi ini. */
    fun isSyncLeader(newNode: String): Boolean {
        // baru masuk Wi-Fi (< 10 dtk): daftar HP di sini belum lengkap, jangan ikut jadi pengirim
        if (System.currentTimeMillis() - openedAt < 10_000) return false
        val me = Env.hex(node)
        return peers.keys.filter { it != newNode }.all { me < it }
    }

    private fun packet(kind: Byte, data: ByteArray): ByteArray {
        val pkt = ByteArray(HDR + data.size)
        System.arraycopy(MAGIC, 0, pkt, 0, 4)
        pkt[4] = kind
        System.arraycopy(cid, 0, pkt, 5, 8)
        System.arraycopy(node, 0, pkt, 13, 4)
        System.arraycopy(data, 0, pkt, HDR, data.size)
        return pkt
    }

    /** Siarkan ke semua HP di Wi-Fi ini. Diam kalau belum tersambung ke Wi-Fi. */
    fun send(kind: Byte, data: ByteArray) {
        val s = socket ?: return
        val to = bcast ?: return
        if (data.size > 60_000) return
        val pkt = packet(kind, data)
        try { s.send(DatagramPacket(pkt, pkt.size, to, PORT)) } catch (e: Exception) { Log.w(BleMesh.TAG, "lan send: $e") }
    }

    val connected: Boolean get() = socket != null

    /** Susulan untuk [node] sudah benar-benar dikirim: catatan hilangnya boleh dibuang. */
    fun syncedGone(node: String) { gone.remove(node) }

    @Synchronized
    private fun openOn(n: Network) {
        if (!running) return
        if (network == n && socket != null) return
        closeSocket()
        try {
            val s = DatagramSocket(null).apply { reuseAddress = true; broadcast = true }
            n.bindSocket(s)   // siaran lewat Wi-Fi walau jaringan utama = data seluler
            s.bind(InetSocketAddress(PORT))
            network = n
            bcast = broadcastOf(cm.getLinkProperties(n)) ?: InetAddress.getByName("255.255.255.255")
            socket = s
            openedAt = System.currentTimeMillis()
            sess = (sess + 1) and 0xff
            settledSent = false
            // kunci multicast (terima siaran) hanya selama tersambung ke Wi-Fi: hemat baterai
            try {
                if (lock == null) lock = ctx.applicationContext.getSystemService(WifiManager::class.java)?.createMulticastLock("ct-lan")?.apply { setReferenceCounted(false) }
                lock?.acquire()
            } catch (e: Exception) { Log.w(BleMesh.TAG, "multicast lock: $e") }
            rx = Thread({ loop(s) }, "ct-lan-rx").apply { isDaemon = true; start() }
            sendHello()
        } catch (e: Exception) {
            Log.w(BleMesh.TAG, "lan open: $e")
            closeSocket()
        }
    }

    @Synchronized
    private fun closeSocket() {
        try { socket?.close() } catch (_: Exception) {}
        try { if (lock?.isHeld == true) lock?.release() } catch (_: Exception) {}
        if (socket != null) { closedAt = System.currentTimeMillis(); prevPeers.clear(); prevPeers.addAll(peers.keys) }
        deferred.clear()
        socket = null; network = null; subnet = null
        rx = null
        if (peers.isNotEmpty()) { peers.clear(); listener.onLanPeersChanged() }
    }

    private fun loop(s: DatagramSocket) {
        val buf = ByteArray(65_535)
        while (running && !s.isClosed) {
            try {
                val p = DatagramPacket(buf, buf.size)
                s.receive(p)
                val n = p.length
                if (n < HDR) continue
                val d = p.data
                if (d[0] != MAGIC[0] || d[1] != MAGIC[1] || d[2] != MAGIC[2] || d[3] != MAGIC[3]) continue
                var same = true
                for (i in 0 until 8) if (d[5 + i] != cid[i]) { same = false; break }
                if (!same) continue                                     // konser lain
                val from = d.copyOfRange(13, 17)
                if (from.contentEquals(node)) continue                  // siaran sendiri
                val fromHex = Env.hex(from)
                val body = d.copyOfRange(HDR, n)
                val ip = p.address?.hostAddress ?: ""
                when (d[4]) {
                    K_HELLO -> {
                        val m = String(body, Charsets.US_ASCII).trim()
                        val old = peers[fromHex]
                        if (old == null) {
                            // hanya dari subnet Wi-Fi ini (tolak IP palsu dari luar jaringan)
                            if (!sameSubnet(p.address)) continue
                            peers[fromHex] = Peer(ip, m, System.currentTimeMillis())
                            listener.onLanPeersChanged()
                            // socket SAYA baru dibuka: semua HP tampak baru padahal sayalah yang tertinggal (mereka menyusulkan
                            // saya lewat deteksi sesi). Jangan kirim susulan ke tiap HP posko -> router tersumbat.
                            if (System.currentTimeMillis() - openedAt >= 10_000) listener.onLanPeerNew(fromHex, ip, gone[fromHex] ?: 0L)
                            else if (fromHex !in prevPeers) deferred[fromHex] = gone[fromHex] ?: 0L
                        } else {
                            old.prevSeen = old.lastSeen
                            old.lastSeen = System.currentTimeMillis(); old.ip = ip
                            if (old.mid != m) { old.mid = m; listener.onLanPeersChanged() }
                        }
                    }
                    K_SESS -> {
                        val old = peers[fromHex] ?: continue
                        val ss = if (body.isNotEmpty()) (body[0].toInt() and 0xff).toString() else ""
                        val prevSeen = old.prevSeen
                        old.lastSeen = System.currentTimeMillis()
                        // sesi socket dia berganti = sempat putus (walau < TTL): susulkan sejak terakhir terlihat
                        if (old.sess.isNotEmpty() && ss != old.sess) listener.onLanPeerNew(fromHex, ip, prevSeen)
                        old.sess = ss
                    }
                    K_ENV, K_HANDOFF -> {
                        peers[fromHex]?.lastSeen = System.currentTimeMillis()
                        listener.onLanEnvelope(body, ip, d[4] == K_HANDOFF)
                    }
                }
            } catch (_: Exception) {
                if (!running || s.isClosed) break
            }
        }
    }

    private fun broadcastOf(lp: LinkProperties?): InetAddress? {
        val la = lp?.linkAddresses?.firstOrNull { it.address is Inet4Address } ?: return null
        val ip = la.address.address
        val prefix = la.prefixLength
        if (prefix !in 1..31) return null
        val mask = (-1 shl (32 - prefix))
        val v = ((ip[0].toInt() and 0xff) shl 24) or ((ip[1].toInt() and 0xff) shl 16) or ((ip[2].toInt() and 0xff) shl 8) or (ip[3].toInt() and 0xff)
        subnet = (v and mask) to mask
        val b = v or mask.inv()
        return InetAddress.getByAddress(byteArrayOf((b ushr 24).toByte(), (b ushr 16).toByte(), (b ushr 8).toByte(), b.toByte()))
    }
}
