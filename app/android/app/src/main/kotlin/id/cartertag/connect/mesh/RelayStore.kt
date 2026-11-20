package id.cartertag.connect.mesh

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

/**
 * Penyimpanan simpan-teruskan (store-and-forward) milik mesh service, terpisah dari database UI.
 *  - relay : envelope yang pernah dilihat, untuk dikirim ke peer yang baru muncul (sinkron inventaris)
 *  - inbox : envelope untuk UI saat Flutter belum berjalan (diambil lewat drain)
 */
class RelayStore(ctx: Context) : SQLiteOpenHelper(ctx, "ct_mesh.db", null, 1) {

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE relay (id TEXT PRIMARY KEY, cid TEXT, type INTEGER, prio INTEGER, ts INTEGER, expires INTEGER, blob BLOB)")
        db.execSQL("CREATE INDEX relay_cid ON relay(cid, ts)")
        db.execSQL("CREATE TABLE inbox (id TEXT PRIMARY KEY, at INTEGER, blob BLOB)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldV: Int, newV: Int) {}

    @Synchronized
    fun has(id: String): Boolean =
        readableDatabase.rawQuery("SELECT 1 FROM relay WHERE id=?", arrayOf(id)).use { it.moveToFirst() }

    @Synchronized
    fun put(env: Env) {
        val now = System.currentTimeMillis()
        val keep = when {
            env.type == Env.T_LOC -> 10 * 60_000L
            env.prio >= 2 -> 3 * 3600_000L
            else -> 6 * 3600_000L
        }
        val v = ContentValues().apply {
            put("id", env.idHex); put("cid", env.cidHex); put("type", env.type); put("prio", env.prio)
            put("ts", now); put("expires", now + keep); put("blob", env.raw)
        }
        writableDatabase.insertWithOnConflict("relay", null, v, SQLiteDatabase.CONFLICT_IGNORE)
    }

    @Synchronized
    fun get(id: String): ByteArray? =
        readableDatabase.rawQuery("SELECT blob FROM relay WHERE id=?", arrayOf(id)).use { if (it.moveToFirst()) it.getBlob(0) else null }

    /** id envelope terbaru untuk konser ini (inventaris yang ditawarkan ke peer baru). */
    @Synchronized
    fun inventory(cid: String, limit: Int): List<String> {
        val out = ArrayList<String>()
        readableDatabase.rawQuery(
            "SELECT id FROM relay WHERE cid=? AND expires>? AND type<>? ORDER BY prio DESC, ts DESC LIMIT ?",
            arrayOf(cid, System.currentTimeMillis().toString(), Env.T_LOC.toString(), limit.toString())
        ).use { while (it.moveToNext()) out.add(it.getString(0)) }
        return out
    }

    @Synchronized
    /**
     * [limit] envelope TERBARU (dikirim urut lama -> baru) untuk HP yang baru bergabung. Tanda terima (ack) dilewati:
     * jumlahnya banyak dan tidak berguna bagi yang menyusul, jangan sampai menghabiskan jatah pesan sungguhan.
     */
    fun recent(cid: String, limit: Int, includeAck: Boolean = false): List<ByteArray> {
        val out = ArrayList<ByteArray>()
        // includeAck: Mode Jembatan butuh tanda terkirim/dibaca untuk riwayat di klien web
        val skip = if (includeAck) "-1" else Env.T_ACK.toString()
        readableDatabase.rawQuery(
            "SELECT blob FROM (SELECT blob, ts FROM relay WHERE cid=? AND expires>? AND type<>? ORDER BY ts DESC LIMIT ?) ORDER BY ts ASC",
            arrayOf(cid, System.currentTimeMillis().toString(), skip, limit.toString())
        ).use { while (it.moveToNext()) out.add(it.getBlob(0)) }
        return out
    }

    /** Buang yang kedaluwarsa + batasi 5.000 baris (SOS dibuang paling akhir). */
    @Synchronized
    fun prune() {
        val db = writableDatabase
        db.delete("relay", "expires<?", arrayOf(System.currentTimeMillis().toString()))
        db.execSQL("DELETE FROM relay WHERE id IN (SELECT id FROM relay ORDER BY prio ASC, ts ASC LIMIT max(0, (SELECT count(*) FROM relay) - 5000))")
        db.delete("inbox", "at<?", arrayOf((System.currentTimeMillis() - 24 * 3600_000L).toString()))
    }

    @Synchronized
    fun inboxAdd(env: Env) {
        val v = ContentValues().apply { put("id", env.idHex); put("at", System.currentTimeMillis()); put("blob", env.raw) }
        writableDatabase.insertWithOnConflict("inbox", null, v, SQLiteDatabase.CONFLICT_IGNORE)
    }

    @Synchronized
    fun inboxDrain(): List<ByteArray> {
        val out = ArrayList<ByteArray>()
        readableDatabase.rawQuery("SELECT blob FROM inbox ORDER BY at ASC", null).use { while (it.moveToNext()) out.add(it.getBlob(0)) }
        writableDatabase.delete("inbox", null, null)
        return out
    }
}
