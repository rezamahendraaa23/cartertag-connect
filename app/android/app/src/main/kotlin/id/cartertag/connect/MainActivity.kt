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

class MainActivity : FlutterActivity() {

    private var routeChannel: MethodChannel? = null

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
                        @Suppress("UNCHECKED_CAST")
                        val names = (call.argument<Map<String, String>>("names") ?: emptyMap())
                        MeshService.start(this, call.argument<String>("cid")!!, call.argument<String>("mid")!!,
                            call.argument<String>("concert") ?: "", names)
                        result.success(true)
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

        routeChannel = MethodChannel(messenger, "ct/route")
        intent?.getStringExtra("route")?.let { r -> routeChannel?.invokeMethod("open", r) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.getStringExtra("route")?.let { routeChannel?.invokeMethod("open", it) }
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
