package id.cartertag.connect.mesh

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import androidx.core.app.NotificationCompat
import id.cartertag.connect.MainActivity
import id.cartertag.connect.R

/**
 * Pengawas jangkauan tim (jalan di service, tetap bekerja saat layar mati / UI tertutup).
 * Sumber utama = kekuatan sinyal Bluetooth (RSSI) ke HP tim yang tersambung, dinilai tiap 3 detik:
 *   ok     : ada HP tim tersambung dengan sinyal cukup
 *   weak   : sinyal terbaik di bawah ambang, atau turun cepat mendekati ambang -> "jangan menjauh"
 *   lost   : tidak ada HP tim tersambung >= 20 dtk padahal sebelumnya ada -> "terputus dari tim"
 *   online : ada internet tervalidasi -> tidak perlu peringatan (pesan tetap sampai lewat internet)
 *   idle   : belum pernah tersambung ke HP tim (mis. masih di rumah) -> diam
 * Peringatan hanya saat berpindah kondisi (bukan berulang), dengan jeda minimal.
 */
class ReachWatch(private val ctx: Context) {

    companion object {
        const val CH_REACH = "ct_reach"
        const val NOTIF_REACH = 9
        const val LOST_AFTER_MS = 20_000L
        const val ALERT_GAP_MS = 60_000L
    }

    /** Diatur dari Flutter: peringatan aktif + ambang RSSI "melemah" (hasil kalibrasi koordinator, default -88 dBm). */
    @Volatile var enabled = true
    @Volatile var weakDbm = -88.0
    /** Peringatan didiamkan sampai (ms), mis. driver sedang menyetir. */
    @Volatile var muteUntil = 0L

    /** Hari konser berjalan & tim belum dibubarkan (dari Flutter). Saat aktif, HP yang kehilangan internet tanpa HP tim di sekitar
     *  diperingatkan walau belum pernah tersambung ke tim (mis. driver parkir sendirian lalu sel penuh). */
    @Volatile var active = false
    /** "Terputus" karena kehilangan internet saat sendirian (bukan karena menjauh dari tim). */
    private var lostSolo = false
    /** Sejak kapan offline (0 = sedang online). Status "online" ditahan 45 dtk: koneksi di sel penuh sering naik-turun. */
    private var offlineSince = 0L
    @Volatile private var lastOnline = false

    /**
     * Status internet dari Flutter (Firebase .info/connected). Di konser "sinyal mati" biasanya sel penuh: Android tetap
     * menandai jaringan VALIDATED berjam-jam, jadi VALIDATED saja tidak cukup. Basi > 45 dtk (UI mati) = pakai VALIDATED saja.
     */
    @Volatile var appOnline = false
    @Volatile var appOnlineAt = 0L

    /** Probe internet native saat UI Flutter mati (app di-swipe): hasil + waktu. */
    @Volatile private var probeOnline = false
    @Volatile private var probeAt = 0L
    @Volatile private var probing = false

    /** Dipanggil setReach saat mulai diam: kondisi buruk yang sedang berlangsung tetap diperingatkan begitu masa diam habis. */
    fun onMuted() {
        if (state == "weak" || state == "lost") pendingAfterMute = true
    }

    var state = "idle"; private set
    var best: Double? = null; private set
    var bestMid = ""; private set
    private var lastLinkAt = 0L
    private var weakSince = 0L
    @Volatile private var pendingAfterMute = false
    private var lastAlertAt = HashMap<String, Long>()
    private val history = ArrayDeque<Pair<Long, Double>>()   // (waktu, RSSI terbaik) 15 dtk terakhir

    init {
        if (Build.VERSION.SDK_INT >= 26) {
            ctx.getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CH_REACH, "Jangkauan tim", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "Peringatan saat sinyal Bluetooth ke tim melemah atau terputus"
                    enableVibration(true)
                    vibrationPattern = longArrayOf(0, 400, 200, 400)
                })
        }
    }

    /**
     * @param links bukti HP tim dalam jangkauan: (member_id, RSSI segar atau null) untuk tiap link tersambung, ditambah HP yang
     *   terlihat di scan beberapa detik terakhir (sambungan GATT sering putus-sambung sesaat padahal rekannya 3 m di sebelah).
     * @param btOn Bluetooth HP menyala. @return true kalau kondisi berubah.
     */
    fun tick(links: List<Pair<String, Double?>>, names: Map<String, String>, btOn: Boolean = true): Boolean {
        val now = System.currentTimeMillis()
        if (links.isNotEmpty()) lastLinkAt = now
        var b: Double? = null
        var bm = ""
        for ((mid, r) in links) if (r != null && (b == null || r > b)) { b = r; bm = mid }
        best = b; bestMid = bm
        if (b != null) history.addLast(now to b)
        while (history.isNotEmpty() && now - history.first().first > 15_000) history.removeFirst()

        val isOnline = online()
        if (isOnline) offlineSince = 0L else if (offlineSince == 0L) offlineSince = now
        val next = when {
            isOnline -> "online"
            // baru offline & tidak ada HP tim: tahan "online" 45 dtk dulu (bukan alarm tiap kali Firebase berkedip)
            state == "online" && links.isEmpty() && now - offlineSince < 45_000 -> "online"
            !btOn -> "btoff"
            // baru saja putus: "melemah" dulu, >= 20 dtk: "terputus"; > 30 mnt tanpa tim (mis. sudah pulang): diam
            links.isEmpty() -> when {
                // hari konser: internet baru hilang (atau masih hilang sejak itu) & tidak ada HP tim di sekitar -> terputus
                active && (state == "online" || (state == "lost" && lostSolo)) &&
                    (lastLinkAt == 0L || now - lastLinkAt >= LOST_AFTER_MS) -> { lostSolo = true; "lost" }
                // 30 mnt dihitung sejak tim terakhir terlihat ATAU masa diam berakhir (supaya peringatan susulan tidak langsung hilang)
                lastLinkAt == 0L || now - maxOf(lastLinkAt, muteUntil) > 30 * 60_000 -> "idle"
                now - lastLinkAt >= LOST_AFTER_MS -> "lost"
                state == "lost" -> "lost"
                else -> "weak"
            }
            // tersambung tapi sinyal tak terbaca: sedang menjauh (iklan hilang dari scan sebelum link putus) -> pertahankan kondisi;
            // baru tersambung -> aman
            b == null -> if (state == "weak" || state == "lost") state else "ok"
            isWeak(b, now) -> "weak"
            else -> "ok"
        }
        // "melemah" baru dianggap nyata setelah bertahan >= 6 dtk (satu bacaan jelek / putus-sambung sesaat tidak memicu peringatan)
        val settled = if (next == "weak" && state != "weak") {
            if (weakSince == 0L) weakSince = now
            if (now - weakSince >= 6_000) "weak" else state
        } else {
            if (next != "weak") weakSince = 0L
            next
        }
        if (settled != "lost") lostSolo = false
        if (settled == state) {
            // masa diam selesai sementara masih lemah/terputus: peringatkan sekali
            if (pendingAfterMute && enabled && now >= muteUntil) {
                pendingAfterMute = false
                if (state == "weak" || state == "lost") alert("ok", state, names[bm] ?: "", now)
            }
            return false
        }
        val prev = state
        state = settled
        if (enabled && now >= muteUntil) alert(prev, settled, names[bm] ?: "", now)
        else {
            if (enabled) pendingAfterMute = settled == "weak" || settled == "lost"
            if (settled == "ok" || settled == "online") cancel()
        }
        return true
    }

    private fun isWeak(b: Double, now: Long): Boolean {
        val th = if (state == "weak") weakDbm + 4 else weakDbm   // histeresis: keluar dari "melemah" butuh sinyal sedikit lebih kuat
        if (b < th) return true
        // turun cepat (> 8 dB dalam ~10 dtk) dan sudah dekat ambang: peringatkan sebelum benar-benar lemah
        val old = history.firstOrNull { now - it.first >= 9_000 }?.second ?: return false
        return old - b > 8 && b < weakDbm + 6
    }

    private fun online(): Boolean {
        val validated = try {
            val cm = ctx.getSystemService(ConnectivityManager::class.java)
            val caps = cm.getNetworkCapabilities(cm.activeNetwork)
            caps != null && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        } catch (_: Exception) { false }
        if (!validated) return false.also { lastOnline = false }
        val now = System.currentTimeMillis()
        if (now - appOnlineAt < 45_000) return appOnline.also { lastOnline = it }
        // UI mati: VALIDATED saja tidak bisa dipercaya di sel konser yang penuh -> cek sendiri tiap 60 dtk
        if (now - probeAt > 60_000) probe()
        // probe pertama belum selesai: pakai nilai sebelumnya (jangan dianggap offline sesaat setelah app ditutup)
        if (probeAt == 0L) return lastOnline
        return (now - probeAt < 120_000 && probeOnline).also { lastOnline = it }
    }

    /** HTTP 204 dari Google dalam 4 dtk = internet benar-benar jalan. Di thread sendiri (jangan menahan router mesh). */
    private fun probe() {
        if (probing) return
        probing = true
        Thread {
            var ok = false
            try {
                val c = java.net.URL("https://clients3.google.com/generate_204").openConnection() as java.net.HttpURLConnection
                c.connectTimeout = 4_000; c.readTimeout = 4_000; c.instanceFollowRedirects = false; c.useCaches = false
                ok = c.responseCode == 204
                c.disconnect()
            } catch (_: Exception) {}
            probeOnline = ok
            probeAt = System.currentTimeMillis()
            probing = false
        }.start()
    }

    fun cancel() = ctx.getSystemService(NotificationManager::class.java).cancel(NOTIF_REACH)

    private var wifiTrapAt = 0L
    /**
     * Wi-Fi posko (tanpa internet) jadi jaringan utama padahal data seluler ada: terjadi kalau pengguna memilih
     * "Tetap sambungkan" di notifikasi Android. Internet seluruh HP (Firebase, WhatsApp) ikut buntu -> beri tahu, maks 1x/jam.
     */
    @Volatile var wifiTrapSince = 0L
    fun checkWifiTrap() {
        val now = System.currentTimeMillis()
        if (now - wifiTrapAt < 3600_000) return
        try {
            val cm = ctx.getSystemService(ConnectivityManager::class.java)
            val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return
            @Suppress("DEPRECATION")
            val trapped = caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) && !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) &&
                cm.allNetworks.any { cm.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true }
            // sesaat setelah tersambung Android bisa memakai Wi-Fi beberapa detik sebelum validasi gagal: tunggu 30 dtk
            if (!trapped) { wifiTrapSince = 0L; return }
            if (wifiTrapSince == 0L) wifiTrapSince = now
            if (now - wifiTrapSince < 30_000) return
            wifiTrapAt = now
            ctx.getSystemService(NotificationManager::class.java).notify(NOTIF_REACH + 1, build("Internet lewat Wi-Fi posko (tanpa internet)",
                "HP ini memakai Wi-Fi posko sebagai jalur internet. Buka Setelan Wi-Fi > Wi-Fi posko, lalu nyalakan " +
                    "\"Beralih ke data seluler\" / matikan \"Tetap sambungkan\", supaya internet lewat data seluler & Wi-Fi posko tetap untuk tim.", false))
        } catch (_: Exception) {}
    }

    private fun alert(prev: String, now: String, nearest: String, t: Long) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        when (now) {
            "weak" -> {
                if (t - (lastAlertAt["weak"] ?: 0) < ALERT_GAP_MS) return
                lastAlertAt["weak"] = t
                nm.notify(NOTIF_REACH, build("Sinyal ke tim melemah",
                    if (nearest.isNotEmpty()) "Terdekat: $nearest. Jangan menjauh, balik sedikit ke arah tim." else "Jangan menjauh, balik sedikit ke arah tim.", false))
            }
            "lost" -> {
                // alarm "internet hilang" paling banyak tiap 5 mnt (sel penuh membuat internet hilang-timbul)
                val key = if (lostSolo) "solo" else "lost"
                if (t - (lastAlertAt[key] ?: 0) < (if (lostSolo) 5 * 60_000L else ALERT_GAP_MS)) return
                lastAlertAt[key] = t
                nm.notify(NOTIF_REACH, if (lostSolo) build("Internet hilang, tidak ada HP tim di sekitar",
                    "Pesan tidak akan sampai. Dekati HP tim / posko supaya tersambung lewat Bluetooth.", true)
                else build("Terputus dari tim",
                    "Tidak ada HP tim di sekitar. Pesan tidak akan sampai. Kembali ke arah tim / posko.", true))
            }
            "btoff" -> {
                // hanya kalau tadi sedang bersama tim (bukan di rumah / sebelum berangkat)
                if (prev == "idle" || lastLinkAt == 0L || t - lastLinkAt > 30 * 60_000 || t - (lastAlertAt["btoff"] ?: 0) < ALERT_GAP_MS) return
                lastAlertAt["btoff"] = t
                nm.notify(NOTIF_REACH, build("Bluetooth mati", "Nyalakan Bluetooth supaya tetap tersambung ke tim tanpa internet.", false))
            }
            "ok" -> if (prev == "lost" || prev == "weak") {
                nm.notify(NOTIF_REACH, build("Tersambung lagi ke tim", if (nearest.isNotEmpty()) "Terdekat: $nearest" else "Sinyal ke tim aman.", false, quiet = true))
            }
            else -> nm.cancel(NOTIF_REACH)
        }
    }

    private fun build(title: String, text: String, urgent: Boolean, quiet: Boolean = false): Notification {
        val i = Intent(ctx, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("route", "reach")
        }
        val pi = PendingIntent.getActivity(ctx, 9, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(ctx, CH_REACH)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setContentIntent(pi)
            .setAutoCancel(true)
            .setOnlyAlertOnce(false)
            .setSilent(quiet)
            .setCategory(if (urgent) NotificationCompat.CATEGORY_ALARM else NotificationCompat.CATEGORY_STATUS)
            .setPriority(if (urgent) NotificationCompat.PRIORITY_MAX else NotificationCompat.PRIORITY_HIGH)
            .apply { if (quiet) setTimeoutAfter(10_000) }
            .build()
    }
}
