package id.cartertag.connect.mesh

import android.annotation.SuppressLint
import android.content.Context
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pGroup
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.os.Looper
import android.util.Base64
import android.util.Log
import java.io.BufferedInputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * Mode Jembatan iPhone (PRD F16).
 *  1. HP ini membuat grup Wi-Fi Direct (iPhone bisa bergabung sebagai klien Wi-Fi biasa).
 *  2. Server HTTP di port 8787 menyajikan web app (assets/bridge_web, hasil `flutter build web`).
 *  3. WebSocket /ws: teks = kontrol (hello/welcome), biner = envelope.
 * Server HTTP/WebSocket ditulis minimal tanpa library tambahan.
 */
@SuppressLint("MissingPermission")
class BridgeServer(private val ctx: Context, private val listener: Listener) {

    interface Listener {
        fun onClientText(client: String, text: String)
        fun onClientBinary(client: String, data: ByteArray)
        fun onClientState(client: String, state: String)
    }

    companion object {
        const val PORT = 8787
        const val MAX_CLIENTS = 6
        private const val GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    }

    inner class Client(val id: String, val socket: Socket, val out: OutputStream) {
        @Volatile var approved = false
        @Synchronized fun sendFrame(opcode: Int, payload: ByteArray) {
            try {
                val header = when {
                    payload.size < 126 -> byteArrayOf((0x80 or opcode).toByte(), payload.size.toByte())
                    payload.size < 65536 -> byteArrayOf((0x80 or opcode).toByte(), 126, (payload.size shr 8).toByte(), payload.size.toByte())
                    else -> {
                        val h = ByteArray(10); h[0] = (0x80 or opcode).toByte(); h[1] = 127
                        val n = payload.size.toLong()
                        for (i in 0 until 8) h[2 + i] = (n shr (8 * (7 - i))).toByte()
                        h
                    }
                }
                out.write(header); out.write(payload); out.flush()
            } catch (e: Exception) {
                close()
            }
        }
        fun text(s: String) = sendFrame(1, s.toByteArray(Charsets.UTF_8))
        fun binary(b: ByteArray) = sendFrame(2, b)
        fun close() {
            try { socket.close() } catch (_: Exception) {}
            if (clients.remove(id) != null) listener.onClientState(id, "closed")
        }
    }

    val clients = ConcurrentHashMap<String, Client>()
    private val seq = AtomicInteger(0)
    private val pool = Executors.newCachedThreadPool()
    private var serverSocket: ServerSocket? = null
    private var p2p: WifiP2pManager? = null
    private var channel: WifiP2pManager.Channel? = null
    var info: Map<String, Any> = emptyMap()
        private set

    // ------------------------------------------------------------ Wi-Fi Direct

    fun start(cb: (Map<String, Any>?, String?) -> Unit) {
        val m = ctx.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
        if (m == null) { cb(null, "Perangkat tidak mendukung Wi-Fi Direct"); return }
        p2p = m
        val ch = m.initialize(ctx, Looper.getMainLooper(), null)
        channel = ch
        val done = { startHttp(); readGroup(cb) }
        // bersihkan grup lama dulu, lalu buat grup baru
        m.removeGroup(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() = create(m, ch, done, cb)
            override fun onFailure(reason: Int) = create(m, ch, done, cb)
        })
    }

    private fun create(m: WifiP2pManager, ch: WifiP2pManager.Channel, done: () -> Unit, cb: (Map<String, Any>?, String?) -> Unit) {
        val listener = object : WifiP2pManager.ActionListener {
            override fun onSuccess() { android.os.Handler(Looper.getMainLooper()).postDelayed({ done() }, 1500) }
            override fun onFailure(reason: Int) { cb(null, "Gagal membuat grup Wi-Fi Direct (kode $reason). Nyalakan Wi-Fi & Lokasi.") }
        }
        if (Build.VERSION.SDK_INT >= 29) {
            val suffix = (1000 + (Math.random() * 8999).toInt()).toString()
            val pass = randomPass()
            val cfg = WifiP2pConfig.Builder()
                .setNetworkName("DIRECT-CT-$suffix")
                .setPassphrase(pass)
                .enablePersistentMode(false)
                .setGroupOperatingBand(WifiP2pConfig.GROUP_OWNER_BAND_2GHZ)
                .build()
            m.createGroup(ch, cfg, listener)
        } else {
            m.createGroup(ch, listener)
        }
    }

    private fun randomPass(): String {
        val a = "abcdefghjkmnpqrstuvwxyz23456789"
        return (1..10).map { a[(Math.random() * a.length).toInt()] }.joinToString("")
    }

    private fun readGroup(cb: (Map<String, Any>?, String?) -> Unit, attempt: Int = 0) {
        val m = p2p ?: return
        val ch = channel ?: return
        m.requestGroupInfo(ch) { g: WifiP2pGroup? ->
            if (g == null) {
                if (attempt < 5) android.os.Handler(Looper.getMainLooper()).postDelayed({ readGroup(cb, attempt + 1) }, 1000)
                else cb(null, "Grup Wi-Fi Direct tidak terbaca. Coba lagi.")
                return@requestGroupInfo
            }
            info = mapOf("ssid" to g.networkName, "pass" to (g.passphrase ?: ""), "ip" to "192.168.49.1", "port" to PORT)
            cb(info, null)
        }
    }

    fun stop() {
        clients.values.forEach { it.close() }
        clients.clear()
        try { serverSocket?.close() } catch (_: Exception) {}
        serverSocket = null
        val m = p2p; val ch = channel
        if (m != null && ch != null) m.removeGroup(ch, null)
        info = emptyMap()
    }

    // ------------------------------------------------------------ HTTP + WebSocket

    private fun startHttp() {
        if (serverSocket != null) return
        val ss = ServerSocket(PORT)
        ss.reuseAddress = true
        serverSocket = ss
        pool.execute {
            while (!ss.isClosed) {
                try {
                    val s = ss.accept()
                    pool.execute { handle(s) }
                } catch (e: SocketException) {
                    break
                } catch (e: Exception) {
                    Log.w(BleMesh.TAG, "bridge accept: $e")
                }
            }
        }
    }

    private fun readLine(inp: InputStream): String? {
        val sb = StringBuilder()
        while (true) {
            val c = inp.read()
            if (c == -1) return if (sb.isEmpty()) null else sb.toString()
            if (c == '\n'.code) return sb.toString().trimEnd('\r')
            sb.append(c.toChar())
            if (sb.length > 8192) return null
        }
    }

    private fun handle(s: Socket) {
        try {
            s.soTimeout = 0
            val inp = BufferedInputStream(s.getInputStream())
            val out = s.getOutputStream()
            val req = readLine(inp) ?: run { s.close(); return }
            val headers = HashMap<String, String>()
            while (true) {
                val l = readLine(inp) ?: break
                if (l.isEmpty()) break
                val i = l.indexOf(':')
                if (i > 0) headers[l.substring(0, i).trim().lowercase()] = l.substring(i + 1).trim()
            }
            val parts = req.split(" ")
            val path = if (parts.size > 1) parts[1].substringBefore('?').substringBefore('#') else "/"
            if (path == "/ws" && headers["upgrade"]?.lowercase() == "websocket") {
                upgrade(s, inp, out, headers["sec-websocket-key"] ?: "")
            } else {
                serveFile(out, path)
                s.close()
            }
        } catch (e: Exception) {
            try { s.close() } catch (_: Exception) {}
        }
    }

    private fun mime(p: String): String = when (p.substringAfterLast('.', "").lowercase()) {
        "html" -> "text/html; charset=utf-8"
        "js", "mjs" -> "application/javascript"
        "json" -> "application/json"
        "wasm" -> "application/wasm"
        "css" -> "text/css"
        "png" -> "image/png"
        "ico" -> "image/x-icon"
        "ttf" -> "font/ttf"
        "otf" -> "font/otf"
        "woff2" -> "font/woff2"
        "svg" -> "image/svg+xml"
        "webmanifest" -> "application/manifest+json"
        else -> "application/octet-stream"
    }

    private fun serveFile(out: OutputStream, rawPath: String) {
        var p = rawPath.trimStart('/')
        if (p.isEmpty() || p.contains("..")) p = "index.html"
        val bytes = try {
            ctx.assets.open("bridge_web/$p").use { it.readBytes() }
        } catch (e: Exception) {
            if (!p.contains('.')) ctx.assets.open("bridge_web/index.html").use { it.readBytes() }.also { p = "index.html" }
            else null
        }
        if (bytes == null) {
            out.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray()); out.flush(); return
        }
        val head = "HTTP/1.1 200 OK\r\nContent-Type: ${mime(p)}\r\nContent-Length: ${bytes.size}\r\n" +
            "Cache-Control: no-cache\r\nConnection: close\r\n\r\n"
        out.write(head.toByteArray()); out.write(bytes); out.flush()
    }

    private fun upgrade(s: Socket, inp: InputStream, out: OutputStream, key: String) {
        if (clients.size >= MAX_CLIENTS) {
            out.write("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n".toByteArray()); out.flush(); s.close(); return
        }
        val accept = Base64.encodeToString(MessageDigest.getInstance("SHA-1").digest((key + GUID).toByteArray()), Base64.NO_WRAP)
        out.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
            "Sec-WebSocket-Accept: $accept\r\n\r\n").toByteArray())
        out.flush()
        val c = Client("c" + seq.incrementAndGet(), s, out)
        clients[c.id] = c
        listener.onClientState(c.id, "open")
        try {
            readFrames(c, inp)
        } finally {
            c.close()
        }
    }

    private fun readFully(inp: InputStream, n: Int): ByteArray {
        val b = ByteArray(n)
        var off = 0
        while (off < n) {
            val r = inp.read(b, off, n - off)
            if (r < 0) throw SocketException("eof")
            off += r
        }
        return b
    }

    private fun readFrames(c: Client, inp: InputStream) {
        var msgOp = 0
        val buf = java.io.ByteArrayOutputStream()
        while (true) {
            val h = readFully(inp, 2)
            val fin = (h[0].toInt() and 0x80) != 0
            val op = h[0].toInt() and 0x0f
            val masked = (h[1].toInt() and 0x80) != 0
            var len = (h[1].toInt() and 0x7f).toLong()
            if (len == 126L) { val e = readFully(inp, 2); len = (((e[0].toInt() and 0xff) shl 8) or (e[1].toInt() and 0xff)).toLong() }
            else if (len == 127L) { val e = readFully(inp, 8); len = 0; for (x in e) len = (len shl 8) or (x.toLong() and 0xff) }
            if (len > 1_000_000) throw SocketException("frame terlalu besar")
            val mask = if (masked) readFully(inp, 4) else null
            val payload = readFully(inp, len.toInt())
            if (mask != null) for (i in payload.indices) payload[i] = (payload[i].toInt() xor mask[i % 4].toInt()).toByte()
            when (op) {
                0x8 -> { c.sendFrame(0x8, ByteArray(0)); return }
                0x9 -> c.sendFrame(0xA, payload)
                0xA -> {}
                0x0, 0x1, 0x2 -> {
                    if (op != 0) { msgOp = op; buf.reset() }
                    buf.write(payload)
                    if (fin) {
                        val data = buf.toByteArray()
                        if (msgOp == 1) listener.onClientText(c.id, String(data, Charsets.UTF_8))
                        else if (c.approved) listener.onClientBinary(c.id, data)
                        buf.reset()
                    }
                }
            }
        }
    }
}
