package id.cartertag.connect

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import id.cartertag.connect.mesh.MeshBus
import id.cartertag.connect.mesh.MeshService

/** HP dinyalakan ulang: hidupkan lagi mesh kalau sebelumnya sedang ikut konser. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        if (MeshBus.loadConfig(context) == null) return
        if (!hasBluetoothPermission(context)) return
        val i = Intent(context, MeshService::class.java)
        try {
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(i) else context.startService(i)
        } catch (_: Exception) {
        }
    }
}
