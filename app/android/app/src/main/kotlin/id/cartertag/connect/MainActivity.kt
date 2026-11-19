package id.cartertag.connect

import android.annotation.SuppressLint
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import id.cartertag.connect.mesh.MeshBus
import id.cartertag.connect.mesh.MeshService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/** Izin minimum untuk mesh BLE. Android 12+: SCAN/ADVERTISE/CONNECT; Android 11 ke bawah: lokasi. */
fun hasBluetoothPermission(ctx: android.content.Context): Boolean {
    val need = if (Build.VERSION.SDK_INT >= 31) listOf(
        android.Manifest.permission.BLUETOOTH_SCAN, android.Manifest.permission.BLUETOOTH_ADVERTISE, android.Manifest.permission.BLUETOOTH_CONNECT
    ) else listOf(android.Manifest.permission.ACCESS_FINE_LOCATION)
    return need.all { ctx.checkSelfPermission(it) == android.content.pm.PackageManager.PERMISSION_GRANTED }
}

class MainActivity : FlutterActivity() {

    private var routeChannel: MethodChannel? = null

    /** Rute dari notifikasi / link yang belum diambil Flutter (diambil lewat ct/route "initial"). */
    private var pendingRoute: String? = null

    /** "route" dari notifikasi, atau "join:CT-XXXXXX" dari link https://cartertag-connect.web.app/join?kode=... */
    private fun routeOf(intent: Intent?): String? {
        if (intent == null) return null
        intent.getStringExtra("route")?.let { return it }
        val data = intent.data ?: return null
        if (data.host == "cartertag-connect.web.app" && (data.path ?: "").startsWith("/join")) {
            val kode = data.getQueryParameter("kode") ?: data.getQueryParameter("k") ?: return "join:"
            return "join:" + kode
        }
        return null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        EventChannel(messenger, "ct/mesh/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                MeshBus.sink = events
                MeshService.instance?.let { MeshBus.emitPeers(it.peersSnapshot()); MeshBus.emitState(true) }
            }
            override fun onCancel(arguments: Any?) { MeshBus.sink = null }
        })

        MethodChannel(messenger, "ct/mesh").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "start" -> {
                        // Android 14+: service tipe connectedDevice WAJIB sudah punya izin Bluetooth, kalau tidak startForeground crash.
                        if (!hasBluetoothPermission(this)) { result.success(false); return@setMethodCallHandler }
                        val names = (call.argument<Map<String, String>>("names") ?: emptyMap())
                        try {
                            MeshService.start(this, call.argument<String>("cid")!!, call.argument<String>("mid")!!,
                                call.argument<String>("concert") ?: "", names)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "stop" -> { MeshService.stop(this); MeshBus.clearConfig(this); result.success(null) }
                    "send" -> {
                        val svc = MeshService.instance
                        if (svc == null) result.error("not_running", "Mesh belum berjalan", null)
                        else { svc.sendLocal(call.argument<ByteArray>("data")!!); result.success(null) }
                    }
                    "names" -> {
                        MeshService.instance?.setNames(call.argument<Map<String, String>>("names") ?: emptyMap())
                        result.success(null)
                    }
                    "powerSave" -> { MeshService.instance?.setPowerSave(call.argument<Boolean>("on") == true); result.success(null) }
                    "drain" -> result.success(MeshService.instance?.drain() ?: emptyList<ByteArray>())
                    "status" -> result.success(MeshService.instance?.status() ?: mapOf("running" to false))
                    "bridgeStart" -> {
                        val svc = MeshService.instance
                        if (svc == null) result.error("not_running", "Mesh belum berjalan", null)
                        else svc.bridgeStart { info, err ->
                            runOnUiThread { if (err != null) result.error("bridge", err, null) else result.success(info) }
                        }
                    }
                    "bridgeStop" -> { MeshService.instance?.bridgeStop(); result.success(null) }
                    "bridgeReply" -> {
                        MeshService.instance?.bridgeReply(call.argument<String>("client")!!, call.argument<String>("data")!!)
                        result.success(null)
                    }
                    "bridgeKick" -> { MeshService.instance?.bridgeKick(call.argument<String>("client")!!); result.success(null) }
                    "batteryExempt" -> { requestBatteryExemption(); result.success(null) }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("mesh", e.message, null)
            }
        }

        pendingRoute = routeOf(intent)
        routeChannel = MethodChannel(messenger, "ct/route").also { ch ->
            ch.setMethodCallHandler { call, result ->
                if (call.method == "initial") { result.success(pendingRoute); pendingRoute = null } else result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        routeOf(intent)?.let { routeChannel?.invokeMethod("open", it) }
    }

    /** Minta dikecualikan dari optimasi baterai supaya mesh tidak dimatikan sistem (PRD M1.2). */
    @SuppressLint("BatteryLife")
    private fun requestBatteryExemption() {
        if (Build.VERSION.SDK_INT < 23) return
        val pm = getSystemService(PowerManager::class.java)
        if (pm.isIgnoringBatteryOptimizations(packageName)) return
        startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")))
    }
}
