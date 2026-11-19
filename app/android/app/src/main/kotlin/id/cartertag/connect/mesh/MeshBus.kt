package id.cartertag.connect.mesh

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap

/** Penghubung MeshService <-> Flutter (EventChannel). sink null = UI Flutter tidak berjalan. */
object MeshBus {
    @Volatile var sink: EventChannel.EventSink? = null
    @Volatile var config: MeshConfig? = null
    private val main = Handler(Looper.getMainLooper())

    private fun emit(ev: Map<String, Any?>): Boolean {
        val s = sink ?: return false
        main.post { try { sink?.success(ev) } catch (_: Exception) {} }
        return s != null
    }

    fun emitEnvelope(bytes: ByteArray, via: String): Boolean = emit(mapOf("e" to "env", "data" to bytes, "via" to via))
    fun emitPeers(list: List<Map<String, Any>>) { emit(mapOf("e" to "peers", "list" to list)) }
    fun emitState(running: Boolean) { emit(mapOf("e" to "state", "running" to running)) }
    fun emitBridge(ev: Map<String, Any?>): Boolean = emit(ev)

    private const val PREF = "ct_mesh"

    /** Simpan konfigurasi supaya service bisa hidup lagi sendiri (START_STICKY / boot). */
    fun saveConfig(ctx: Context, c: MeshConfig) {
        val names = JSONObject()
        c.names.forEach { (k, v) -> names.put(k, v) }
        ctx.getSharedPreferences(PREF, Context.MODE_PRIVATE).edit()
            .putString("cid", c.cid).putString("mid", c.mid).putString("concert", c.concert).putString("names", names.toString())
            .apply()
    }

    fun loadConfig(ctx: Context): MeshConfig? {
        val p = ctx.getSharedPreferences(PREF, Context.MODE_PRIVATE)
        val cid = p.getString("cid", null) ?: return null
        val names = ConcurrentHashMap<String, String>()
        try {
            val j = JSONObject(p.getString("names", "{}") ?: "{}")
            j.keys().forEach { names[it] = j.getString(it) }
        } catch (_: Exception) {}
        return MeshConfig(cid, p.getString("mid", "") ?: "", p.getString("concert", "") ?: "", names).also { config = it }
    }

    fun clearConfig(ctx: Context) {
        ctx.getSharedPreferences(PREF, Context.MODE_PRIVATE).edit().clear().apply()
        config = null
    }
}
