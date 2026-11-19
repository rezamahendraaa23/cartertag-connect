package id.cartertag.connect.mesh

import java.nio.ByteBuffer

/**
 * Pembaca header envelope (format identik dengan lib/core/envelope.dart).
 * Router hanya membaca header plaintext; body terenkripsi tidak pernah dibuka di sini.
 */
class Env private constructor(val raw: ByteArray) {
    val type: Int get() = raw[3].toInt() and 0xff
    val prio: Int get() = raw[4].toInt() and 0xff
    val ttl: Int get() = raw[5].toInt() and 0xff
    val hop: Int get() = raw[6].toInt() and 0xff
    val flags: Int get() = raw[7].toInt() and 0xff
    val id: ByteArray get() = raw.copyOfRange(8, 24)
    val idHex: String get() = hex(id)
    val cidHex: String get() = hex(raw.copyOfRange(24, 32))
    val from: String get() = String(raw, 40, 12, Charsets.US_ASCII).trim()
    val ts: Long get() = ByteBuffer.wrap(raw, 52, 8).long

    /** Salinan untuk diteruskan: hop + 1 (tanda tangan tidak mencakup ttl/hop). */
    fun relayed(): ByteArray = raw.copyOf().also { it[6] = ((hop + 1) and 0xff).toByte() }

    companion object {
        const val HEADER = 62
        const val SIG = 64
        const val MAX_BODY = 4096

        const val T_CHAT = 1
        const val T_ACK = 2
        const val T_LOC = 3
        const val T_FLEET = 4
        const val T_ANN = 5
        const val T_ROLLCALL = 6
        const val T_SOS = 7
        const val T_CHECKIN = 8
        const val T_CONTROL = 9

        fun parse(b: ByteArray): Env? {
            if (b.size < HEADER + SIG) return null
            if (b[0] != 0x43.toByte() || b[1] != 0x54.toByte() || b[2] != 1.toByte()) return null
            val len = ((b[60].toInt() and 0xff) shl 8) or (b[61].toInt() and 0xff)
            if (len > MAX_BODY || b.size != HEADER + len + SIG) return null
            return Env(b)
        }

        fun hex(b: ByteArray): String {
            val sb = StringBuilder(b.size * 2)
            for (x in b) sb.append(String.format("%02x", x.toInt() and 0xff))
            return sb.toString()
        }

        fun unhex(s: String): ByteArray = ByteArray(s.length / 2) { i -> s.substring(i * 2, i * 2 + 2).toInt(16).toByte() }
    }
}
