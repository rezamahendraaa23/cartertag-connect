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
        fun onLanEnvelope(bytes: ByteArray, fromIp: String)
        /** HP tim baru muncul di Wi-Fi ini: kirimkan pesan simpanan supaya dia menyusul. */
        fun onLanPeerNew(node: String, ip: String)
        fun onLanPeersChanged()
    }

    class Peer(@Volatile var ip: String, @Volatile var mid: String, @Volatile var lastSeen: Long)

    companion object {
        const val PORT = 47817
        const val K_ENV: Byte = 1
        const val K_HELLO: Byte = 2
        private val MAGIC = byteArrayOf('C'.code.toByte(), 'T'.code.toByte(), 'L'.code.toByte(), '1'.code.toByte())
        private const val HDR = 4 + 1 + 8 + 4
        const val PEER_TTL_MS = 15_000L
    }

    val peers = ConcurrentHashMap<String, Peer>()   // node hex -> peer
    @Volatile var running = false; private set
    @Volatile private var socket: DatagramSocket? = null
    @Volatile private var network: Network? = null
    @Volatile private var bcast: InetAddress? = null
    @Volatile private var openedAt = 0L
    private var cid = ByteArray(8)
    private var node = ByteArray(4)
    private var mid = ""
    private var lock: WifiManager.MulticastLock? = null
    private var rx: Thread? = null
    private var hello: Thread? = null
    private val cm = ctx.getSystemService(ConnectivityManager::class.java)

    private val netCb = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(n: Network) { openOn(n) }
        override fun onLinkPropertiesChanged(n: Network, lp: LinkProperties) { if (n == network) bcast = broadcastOf(lp) }
        override fun onLost(n: Network) { if (n == network) closeSocket() }
    }

    fun start(cid: ByteArray, node: ByteArray, mid: String) {
        stop()
        this.cid = cid; this.node = node; this.mid = mid
        running = true
        try {
            // Wi-Fi posko memang tanpa internet: jangan minta kemampuan internet
            cm.registerNetworkCallback(NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).build(), netCb)
        } catch (e: Exception) { Log.w(BleMesh.TAG, "lan callback: $e") }
        hello = Thread({
            while (running) {
                try {
                    send(K_HELLO, mid.toByteArray(Charsets.US_ASCII))
                    val now = System.currentTimeMillis()
                    if (peers.entries.removeIf { now - it.value.lastSeen > PEER_TTL_MS }) listener.onLanPeersChanged()
                    Thread.sleep(4_000)
                } catch (_: InterruptedException) { break } catch (_: Exception) {}
            }
        }, "ct-lan-hello").apply { isDaemon = true; start() }
    }

    fun stop() {
        running = false
        try { cm.unregisterNetworkCallback(netCb) } catch (_: Exception) {}
        hello?.interrupt(); hello = null
        closeSocket()
        if (peers.isNotEmpty()) { peers.clear(); listener.onLanPeersChanged() }
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
            // kunci multicast (terima siaran) hanya selama tersambung ke Wi-Fi: hemat baterai
            try {
                if (lock == null) lock = ctx.applicationContext.getSystemService(WifiManager::class.java)?.createMulticastLock("ct-lan")?.apply { setReferenceCounted(false) }
                lock?.acquire()
            } catch (e: Exception) { Log.w(BleMesh.TAG, "multicast lock: $e") }
            rx = Thread({ loop(s) }, "ct-lan-rx").apply { isDaemon = true; start() }
            send(K_HELLO, mid.toByteArray(Charsets.US_ASCII))
        } catch (e: Exception) {
            Log.w(BleMesh.TAG, "lan open: $e")
            closeSocket()
        }
    }

    @Synchronized
    private fun closeSocket() {
        try { socket?.close() } catch (_: Exception) {}
        try { if (lock?.isHeld == true) lock?.release() } catch (_: Exception) {}
        socket = null; network = null
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
                            peers[fromHex] = Peer(ip, m, System.currentTimeMillis())
                            listener.onLanPeersChanged()
                            listener.onLanPeerNew(fromHex, ip)
                        } else { old.lastSeen = System.currentTimeMillis(); old.ip = ip; if (old.mid != m) { old.mid = m; listener.onLanPeersChanged() } }
                    }
                    K_ENV -> {
                        peers[fromHex]?.lastSeen = System.currentTimeMillis()
                        listener.onLanEnvelope(body, ip)
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
        val b = v or mask.inv()
        return InetAddress.getByAddress(byteArrayOf((b ushr 24).toByte(), (b ushr 16).toByte(), (b ushr 8).toByte(), b.toByte()))
    }
}
