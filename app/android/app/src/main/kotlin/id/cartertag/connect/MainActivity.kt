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
            // r = d (driver) / k (koordinator): app langsung tahu perlu tanya nomor mobil atau tidak
            val r = data.getQueryParameter("r") ?: ""
            return "join:" + kode + (if (r.isNotEmpty()) "|$r" else "")
        }
        return null
    }

    /** Engine Flutter dihancurkan (back / swipe dari recents) tanpa onCancel: lepas sink supaya service tahu UI mati
     *  (pesan masuk ke inbox + notifikasi, bukan dikirim ke engine yang sudah tidak ada). */
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        MeshBus.sink = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        MeshBus.sink = null
        super.onDestroy()
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
                    "reach" -> {
                        val en = call.argument<Boolean>("enabled") != false
                        val weak = call.argument<Number>("weak")?.toDouble() ?: -88.0
                        val mute = call.argument<Number>("mute")?.toLong() ?: 0L
                        val active = call.argument<Boolean>("active") == true
                        // service belum hidup: simpan dulu, dibaca saat service mulai
                        MeshService.instance?.setReach(en, weak, mute, active) ?: run {
                            val c = java.util.Calendar.getInstance().apply { timeInMillis = System.currentTimeMillis() - 6 * 3_600_000L }
                            val day = String.format(java.util.Locale.US, "%04d-%02d-%02d", c.get(java.util.Calendar.YEAR), c.get(java.util.Calendar.MONTH) + 1, c.get(java.util.Calendar.DAY_OF_MONTH))
                            getSharedPreferences("ct_reach", MODE_PRIVATE).edit()
                                .putBoolean("enabled", en).putFloat("weak", weak.toFloat()).putLong("mute", mute)
                                .putBoolean("active", active).putString("activeDay", day).apply()
                        }
                        result.success(null)
                    }
                    "channels" -> {
                        val list = call.argument<List<String>>("list") ?: emptyList()
                        // disimpan: service yang dihidupkan ulang sistem (UI tertutup) tetap menyaring notifikasi
                        getSharedPreferences("ct_vis", MODE_PRIVATE).edit()
                            .putStringSet("list", list.toSet()).putString("cid", call.argument<String>("cid") ?: "").apply()
                        MeshService.instance?.setVisibleChannels(list)
                        result.success(null)
                    }
                    "net" -> {
                        // online null = belum tahu (Firebase masih menyambung): hanya perbarui status layar
                        val on: Boolean? = call.argument<Boolean>("online")
                        val fg = call.argument<Boolean>("fg") == true
                        MeshBus.netFg = fg
                        if (on != null) { MeshBus.netOnline = on; MeshBus.netAt = System.currentTimeMillis() }
                        MeshService.instance?.setNet(on, fg)
                        result.success(null)
                    }
                    "peers" -> result.success(MeshService.instance?.peersSnapshot() ?: emptyList<Map<String, Any>>())
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
                    "brand" -> result.success(Build.MANUFACTURER.lowercase())
                    "linkStatus" -> result.success(joinLinkEnabled())
                    "btOn" -> result.success(
                        (getSystemService(android.bluetooth.BluetoothManager::class.java)?.adapter?.isEnabled) == true)
                    "btSettings" -> { startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS)); result.success(null) }
                    "linkSettings" -> { openLinkSettings(); result.success(null) }
                    "autostart" -> result.success(openAutostartSettings())
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("mesh", e.message, null)
            }
        }

        // Update dalam app: pasang APK yang sudah diunduh Flutter ke cache/updates
        MethodChannel(messenger, "ct/update").setMethodCallHandler { call, result ->
            when (call.method) {
                "canInstall" -> result.success(Build.VERSION.SDK_INT < 26 || packageManager.canRequestPackageInstalls())
                "allowInstall" -> {
                    if (Build.VERSION.SDK_INT >= 26) startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                    result.success(null)
                }
                "install" -> {
                    try {
                        val file = java.io.File(call.argument<String>("path")!!)
                        val uri = androidx.core.content.FileProvider.getUriForFile(this, "$packageName.files", file)
                        startActivity(Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                        })
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("install", e.message, null)
                    }
                }
                else -> result.notImplemented()
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

    /**
     * Link gabung (https://cartertag-connect.web.app/join?...) sudah boleh membuka app langsung?
     * Android 12+: domain harus "verified" (otomatis lewat assetlinks) atau "selected" (dipilih pengguna di pengaturan).
     * Android 11 ke bawah: selalu true (Android menawarkan pilihan aplikasi saat link diklik).
     */
    private fun joinLinkEnabled(): Boolean {
        if (Build.VERSION.SDK_INT < 31) return true
        return try {
            val dvm = getSystemService(android.content.pm.verify.domain.DomainVerificationManager::class.java)
            val st = dvm.getDomainVerificationUserState(packageName) ?: return false
            if (!st.isLinkHandlingAllowed) return false
            val s = st.hostToStateMap["cartertag-connect.web.app"]
            s == android.content.pm.verify.domain.DomainVerificationUserState.DOMAIN_STATE_VERIFIED ||
                s == android.content.pm.verify.domain.DomainVerificationUserState.DOMAIN_STATE_SELECTED
        } catch (_: Exception) {
            true
        }
    }

    /** Buka layar "Buka secara default" app ini supaya pengguna bisa mencentang cartertag-connect.web.app. */
    private fun openLinkSettings() {
        val i = if (Build.VERSION.SDK_INT >= 31)
            Intent(Settings.ACTION_APP_OPEN_BY_DEFAULT_SETTINGS, Uri.parse("package:$packageName"))
        else Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
        try { startActivity(i) } catch (_: Exception) {
            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
        }
    }

    /**
     * Buka layar "Autostart / Mulai otomatis" milik vendor (Xiaomi, Oppo, Realme, Vivo, Huawei, dll.).
     * Tanpa ini, vendor tersebut mematikan app di latar walau optimasi baterai sudah dikecualikan.
     * Kembali true kalau salah satu layar berhasil dibuka; false = buka info aplikasi sebagai cadangan.
     */
    private fun openAutostartSettings(): Boolean {
        val candidates = listOf(
            "com.miui.securitycenter" to "com.miui.permcenter.autostart.AutoStartManagementActivity",
            "com.coloros.safecenter" to "com.coloros.safecenter.permission.startup.StartupAppListActivity",
            "com.coloros.safecenter" to "com.coloros.safecenter.startupapp.StartupAppListActivity",
            "com.oplus.safecenter" to "com.oplus.safecenter.permission.startup.StartupAppListActivity",
            "com.oppo.safe" to "com.oppo.safe.permission.startup.StartupAppListActivity",
            "com.vivo.permissionmanager" to "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
            "com.iqoo.secure" to "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity",
            "com.huawei.systemmanager" to "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
            "com.huawei.systemmanager" to "com.huawei.systemmanager.optimize.process.ProtectActivity",
            "com.hihonor.systemmanager" to "com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
            "com.transsion.phonemaster" to "com.cyin.himgr.autostart.AutoStartActivity",
            "com.asus.mobilemanager" to "com.asus.mobilemanager.autostart.AutoStartActivity",
            "com.letv.android.letvsafe" to "com.letv.android.letvsafe.AutobootManageActivity"
        )
        for ((pkg, cls) in candidates) {
            try {
                startActivity(Intent().setClassName(pkg, cls).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return true
            } catch (_: Exception) { }
        }
        try {
            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
        } catch (_: Exception) { }
        return false
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
