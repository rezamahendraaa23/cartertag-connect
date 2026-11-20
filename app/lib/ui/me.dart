import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:geolocator/geolocator.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/ids.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../main.dart';
import '../services/api.dart';
import '../services/hub.dart';
import '../services/mesh.dart';
import '../services/online.dart';
import '../services/updater.dart';
import 'root.dart';
import 'widgets.dart';

/// Keluar dari konser (dipakai tombol di header layar utama & di Saya): konfirmasi -> layar progres -> hasil.
bool _leaveFlowOpen = false;

Future<void> leaveConcertFlow(BuildContext context) async {
  final h = Hub.i;
  // dua ketukan cepat: jangan buka dua konfirmasi
  if (_leaveFlowOpen || h.leaving || h.concert == null) return;
  _leaveFlowOpen = true;
  try {
    await _leaveConcertFlow(context);
  } finally {
    _leaveFlowOpen = false;
  }
}

Future<void> _leaveConcertFlow(BuildContext context) async {
  final h = Hub.i;
  if (!await confirm(context,
      title: 'Keluar dari ${h.concert!.name}?',
      text: 'Semua chat & data konser ini di HP ini dihapus. Tidak bisa dibatalkan. Bisa gabung lagi pakai kode / link.',
      action: 'Keluar & hapus',
      danger: true)) {
    return;
  }
  if (!context.mounted || h.concert == null) return;
  final nav = Navigator.of(context, rootNavigator: true);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final progress = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(children: [
          SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
          SizedBox(width: 16),
          Expanded(child: Text('Mengabari tim & menghapus data…')),
        ]),
      ),
    ),
  );
  unawaited(nav.push(progress));
  var reached = true;
  try {
    reached = await h.leave();
  } catch (_) {
    if (progress.isActive) nav.removeRoute(progress);
    messenger?.showSnackBar(const SnackBar(content: Text('Gagal keluar. Coba lagi.')));
    return;
  }
  if (progress.isActive) nav.removeRoute(progress);
  if (!reached) {
    messenger?.showSnackBar(const SnackBar(
        content: Text('Kamu sudah keluar. Tim lain baru melihatnya setelah HP ini tersambung internet atau dekat HP tim.'), duration: Duration(seconds: 6)));
  }
}

/// S24 — Saya: profil & pengaturan.
class MeScreen extends StatefulWidget {
  const MeScreen({super.key});
  @override
  State<MeScreen> createState() => _MeScreenState();
}

class _MeScreenState extends State<MeScreen> {
  bool powerSave = false;
  String theme = 'system';

  @override
  void initState() {
    super.initState();
    Hub.i.s.get<bool>('power_save').then((v) => setState(() => powerSave = v ?? false));
    Hub.i.s.get<String>('theme').then((v) => setState(() => theme = v ?? 'system'));
  }

  /// Driver salah isi nomor mobil: ganti tanpa keluar. Daftar penumpang ikut berganti ke mobil baru (manifest dari server).
  Future<void> _changeCar(BuildContext context) async {
    final h = Hub.i;
    final old = h.me.car;
    // centang penumpang yang sudah terlanjur diisi di mobil lama
    final done = (await h.myCheckinsOnCar(old)).length;
    if (!context.mounted) return;
    final ctl = TextEditingController();
    final car = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ganti nomor mobil'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Sekarang: ${carName(old)}'),
          const SizedBox(height: 12),
          TextField(
            controller: ctl,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
            style: mono(22, w: FontWeight.w700),
            decoration: const InputDecoration(labelText: 'Nomor mobil yang benar', prefixText: 'C ', hintText: '3'),
          ),
          const SizedBox(height: 12),
          Text('Daftar penumpang di HP kamu ikut berganti ke mobil yang baru, dan tim melihat nomor mobil barumu.',
              style: Theme.of(context).textTheme.bodySmall),
          if (done > 0) ...[
            const SizedBox(height: 8),
            Text('$done centang penumpang yang kamu isi di ${carName(old)} akan dikosongkan lagi, supaya penumpang mobil itu tidak dikira sudah naik.',
                style: TextStyle(fontSize: 12.5, color: CT.of(context).amber, fontWeight: FontWeight.w600)),
          ],
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
          FilledButton(
            onPressed: () {
              final v = ctl.text.trim();
              if (v.isNotEmpty && v != carDigits(old)) Navigator.pop(ctx, v);
            },
            child: const Text('Ganti'),
          ),
        ],
      ),
    );
    if (car == null || !context.mounted || _changingCar) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final nav = Navigator.of(context, rootNavigator: true);
    // proses ke server bisa beberapa detik: tampilkan progres & tolak ketukan ulang (join ganda)
    final progress = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(children: [
            SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
            SizedBox(width: 16),
            Expanded(child: Text('Mengganti nomor mobil…')),
          ]),
        ),
      ),
    );
    _changingCar = true;
    unawaited(nav.push(progress));
    try {
      await h.changeCar(car);
      messenger?.showSnackBar(SnackBar(content: Text('Nomor mobil diganti ke ${carName(car)}. Daftar penumpang sudah diperbarui.')));
    } catch (e) {
      // dikeluarkan otomatis di tengah jalan: layar awal sudah menampilkan alasannya
      if ((e is ApiError && e.code == 'cancel') || h.concert == null) return;
      messenger?.showSnackBar(SnackBar(content: Text('Gagal ganti nomor mobil: $e')));
    } finally {
      _changingCar = false;
      if (progress.isActive) nav.removeRoute(progress);
    }
  }

  bool _changingCar = false;

  // ikut berubah saat internet kembali / nomor mobil diganti
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: Hub.i, builder: (context, _) => _body(context));

  Widget _body(BuildContext context) {
    final h = Hub.i;
    if (h.concert == null) return const SizedBox.shrink();
    final me = h.me;
    final c = CT.of(context);
    return ListView(padding: const EdgeInsets.only(bottom: 40), children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: brutalBox(context),
          child: Row(children: [
            Avatar(name: me.name, size: 56),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(me.name, style: Theme.of(context).textTheme.titleLarge),
                Text(me.roleLabel, style: Theme.of(context).textTheme.bodyLarge),
                if (me.plat.isNotEmpty) Text(me.plat, style: mono(13, w: FontWeight.w600)),
                Text(h.concert!.name, style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
          ]),
        ),
      ),
      const SectionLabel('Koneksi'),
      ListTile(
        minTileHeight: 56,
        leading: const Icon(LucideIcons.network),
        title: const Text('Detail koneksi'),
        subtitle: Text('${h.meshPeers} HP terdekat · ${h.queued} pesan antre'),
        trailing: const Icon(LucideIcons.chevronRight),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ConnectionScreen())),
      ),
      if (Mesh.i.supported) ...[
        ListTile(
          minTileHeight: 56,
          leading: const Icon(LucideIcons.link),
          title: const Text('Mode Jembatan iPhone'),
          subtitle: const Text('Bantu teman pakai iPhone ikut chat tanpa internet'),
          trailing: const Icon(LucideIcons.chevronRight),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BridgeHostScreen())),
        ),
        SwitchListTile(
          secondary: const Icon(LucideIcons.batteryMedium),
          title: const Text('Mode hemat baterai'),
          subtitle: const Text('Scan Bluetooth lebih jarang. Pesan bisa sedikit lebih lambat.'),
          value: powerSave,
          onChanged: (v) {
            setState(() => powerSave = v);
            h.s.put('power_save', v);
            Mesh.i.setPowerSave(v);
          },
        ),
        ListTile(
          minTileHeight: 56,
          leading: const Icon(LucideIcons.link),
          title: const Text('Buka link gabung di app'),
          subtitle: const Text('Aktifkan "Buka link yang didukung" → centang cartertag-connect.web.app'),
          trailing: const Icon(LucideIcons.chevronRight),
          onTap: () => Mesh.i.openLinkSettings(),
        ),
        ListTile(
          minTileHeight: 56,
          leading: const Icon(LucideIcons.rocket),
          title: const Text('Tetap aktif di latar'),
          subtitle: const Text('Autostart & baterai (penting untuk Xiaomi, Oppo, Vivo, Realme)'),
          trailing: const Icon(LucideIcons.chevronRight),
          onTap: () async {
            await Mesh.i.requestBatteryExemption();
            await Mesh.i.openAutostart();
          },
        ),
        ListTile(
          minTileHeight: 56,
          leading: const Icon(LucideIcons.qrCode),
          title: const Text('Undang via QR'),
          subtitle: const Text('Anggota baru gabung tanpa internet'),
          trailing: const Icon(LucideIcons.chevronRight),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const InviteQrScreen())),
        ),
      ],
      const SectionLabel('Tampilan'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: SegmentedButton<String>(
          segments: const [ButtonSegment(value: 'system', label: Text('Otomatis')), ButtonSegment(value: 'light', label: Text('Terang')), ButtonSegment(value: 'dark', label: Text('Gelap'))],
          selected: {theme},
          onSelectionChanged: (s) {
            setState(() => theme = s.first);
            h.s.put('theme', theme);
            themeMode.value = switch (theme) { 'light' => ThemeMode.light, 'dark' => ThemeMode.dark, _ => ThemeMode.system };
          },
        ),
      ),
      ListTile(
        title: const Text('Ukuran teks'),
        subtitle: Slider(
          value: textScale.value,
          min: 1.0,
          max: 1.4,
          divisions: 4,
          label: '${(textScale.value * 100).round()}%',
          onChanged: (v) {
            textScale.value = v;
            h.s.put('text_scale', v);
            setState(() {});
          },
        ),
      ),
      const SectionLabel('Konser'),
      ListTile(
        minTileHeight: 56,
        leading: const Icon(LucideIcons.refreshCw),
        title: const Text('Perbarui data tim & manifest'),
        subtitle: Text(h.netUp ? 'Ambil data terbaru dari server' : 'Butuh internet'),
        enabled: h.netUp,
        onTap: () async {
          await h.refresh();
          if (context.mounted) toast(context, 'Data diperbarui');
        },
      ),
      if (me.isDriver)
        ListTile(
          minTileHeight: 56,
          leading: const Icon(LucideIcons.squarePen),
          title: Text('Nomor mobil: ${me.car.isEmpty ? '-' : me.carLabel}'),
          subtitle: Text(h.netUp ? 'Salah isi? Ganti tanpa keluar dari konser' : 'Ganti nomor mobil butuh internet'),
          trailing: const Icon(LucideIcons.chevronRight),
          enabled: h.netUp,
          onTap: () => _changeCar(context),
        ),
      ListTile(
        minTileHeight: 56,
        leading: const Icon(LucideIcons.carFront),
        title: const Text('Ganti / tambah konser'),
        trailing: const Icon(LucideIcons.chevronRight),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ConcertsScreen())),
      ),
      ListTile(
        minTileHeight: 56,
        leading: Icon(LucideIcons.logOut, color: c.danger),
        title: Text('Keluar & hapus data konser ini', style: TextStyle(color: c.danger, fontWeight: FontWeight.w700)),
        onTap: () => leaveConcertFlow(context),
      ),
      if (!kIsWeb)
        ListenableBuilder(
          listenable: Updater.i,
          builder: (context, _) {
            final u = Updater.i, up = u.available;
            return ListTile(
              minTileHeight: 56,
              leading: Icon(up != null ? LucideIcons.download : LucideIcons.refreshCw, color: up != null ? c.accent : null),
              title: Text(up != null ? 'Update ke versi ${up.version}' : 'Cek pembaruan'),
              subtitle: u.progress != null
                  ? Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: LinearProgressIndicator(value: u.progress, minHeight: 5, color: c.accent, backgroundColor: c.cardLow),
                    )
                  : Text(u.error ?? (u.checking ? 'Memeriksa…' : 'Versi terpasang ${h.appVersion}')),
              onTap: u.checking || u.progress != null
                  ? null
                  : () async {
                      if (up != null) return Updater.i.download();
                      final r = await Updater.i.check(force: true);
                      if (context.mounted) toast(context, r == null ? 'Sudah versi terbaru.' : 'Versi ${r.version} tersedia. Ketuk untuk update.');
                    },
            );
          },
        ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: Text('CarterTag Connect ${h.appVersion} · ID ${me.id}', style: TextStyle(fontSize: 12, color: c.muted)),
      ),
    ]);
  }
}

/// Daftar konser tersimpan di HP ini.
class ConcertsScreen extends StatelessWidget {
  const ConcertsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Konser')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: Hub.i.savedConcerts(),
        builder: (context, snap) => ListView(children: [
          for (final b in snap.data ?? const <Map<String, dynamic>>[])
            ListTile(
              minTileHeight: 64,
              leading: const Icon(LucideIcons.music),
              title: Text('${(b['konser'] as Map?)?['nama'] ?? ''}'),
              subtitle: Text('${(b['konser'] as Map?)?['venue'] ?? ''}'),
              trailing: (b['konser'] as Map?)?['slug'] == Hub.i.slug ? const StatusChip(label: 'Aktif', icon: LucideIcons.check, fg: Colors.black, bg: Color(0xFFB9F0CF), dense: true) : null,
              onTap: () async {
                await Hub.i.switchTo('${(b['konser'] as Map)['slug']}');
                if (context.mounted) Navigator.pop(context);
              },
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: OutlinedButton.icon(
              onPressed: () async {
                await Hub.i.detachForNewJoin();
                if (context.mounted) openRoot(context);
              },
              icon: const Icon(LucideIcons.plus),
              label: const Text('Gabung konser lain'),
            ),
          ),
        ]),
      ),
    );
  }
}

/// S25 — Detail koneksi (diagnosa lapangan).
class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key});
  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  Map status = const {};
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _load();
    _t = Timer.periodic(const Duration(seconds: 3), (_) => _load());
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final s = await Mesh.i.status();
    if (mounted) setState(() => status = s);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Hub.i,
      builder: (context, _) {
        final h = Hub.i;
        // hanya link aktif (daftar service juga memuat HP yang sekadar terlihat di scan)
        final peers = h.meshPeersList.where((p) => p.connected).toList();
        return Scaffold(
          appBar: AppBar(title: const Text('Koneksi')),
          body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
            const Padding(padding: EdgeInsets.all(16), child: Align(alignment: Alignment.centerLeft, child: ConnPill())),
            const SectionLabel('Internet'),
            _kv('Jaringan HP', h.netUp ? 'Ada' : 'Tidak ada'),
            _kv('Server realtime', Online.i.ready ? (Online.i.connected ? 'Tersambung' : 'Terputus') : 'Belum diatur (hanya mesh)'),
            _kv('Gateway', Online.i.connected && h.meshPeers > 0 ? 'Aktif: pesan mesh diteruskan ke internet' : 'Tidak aktif'),
            const SectionLabel('Mesh (Bluetooth)'),
            _kv('Service', Mesh.i.supported ? (Mesh.i.running ? 'Berjalan' : 'Mati (izin Bluetooth belum diberikan?)') : 'Tidak tersedia di perangkat ini'),
            FutureBuilder<List<bool>>(
              future: Future.wait([Mesh.i.bluetoothOn(), Geolocator.isLocationServiceEnabled()]),
              builder: (context, s) => Column(children: [
                _kv('Bluetooth', s.data == null ? '…' : (s.data![0] ? 'Nyala' : 'MATI — nyalakan')),
                _kv('Lokasi (GPS)', s.data == null ? '…' : (s.data![1] ? 'Nyala' : 'MATI — wajib nyala untuk menemukan HP tim')),
              ]),
            ),
            _kv('Link aktif', '${status['links'] ?? peers.length}'),
            if (status['bridgeClients'] != null && status['bridgeClients'] != 0) _kv('Klien jembatan', '${status['bridgeClients']}'),
            for (final p in peers)
              ListTile(
                leading: const Icon(LucideIcons.bluetooth),
                title: Text(h.member(p.memberId)?.name ?? (p.memberId.isEmpty ? 'HP tim' : p.memberId)),
                subtitle: Text(p.via == 'wifi' ? 'Wi-Fi posko (router lokal)' : '${p.via.toUpperCase()} · RSSI ${p.rssi} dBm · ±${p.meters.round()} m'),
                trailing: Text(timeAgo(p.lastSeen), style: mono(12)),
              ),
            if (peers.isEmpty && Mesh.i.supported)
              const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('Belum ada HP tim dalam jangkauan Bluetooth (±10–30 m di keramaian).')),
            const SectionLabel('Antrean'),
            _kv('Pesan menunggu', '${h.queued}'),
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton.icon(onPressed: () => h.retryNow(), icon: const Icon(LucideIcons.refreshCw), label: const Text('Coba kirim sekarang')),
            ),
          ]),
        );
      },
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(children: [
          SizedBox(width: 140, child: Text(k, style: const TextStyle(fontWeight: FontWeight.w700))),
          Expanded(child: Text(v)),
        ]),
      );
}

/// QR putih bergaris tebal + hitung mundur (K15).
class QrCard extends StatelessWidget {
  const QrCard({super.key, required this.data, this.caption});
  final String data;
  final String? caption;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: brutalBox(context, color: Colors.white, border: Colors.black),
      child: Column(children: [
        QrImageView(data: data, size: 240, backgroundColor: Colors.white, eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Colors.black)),
        if (caption != null) ...[const SizedBox(height: 8), Text(caption!, textAlign: TextAlign.center, style: mono(13, w: FontWeight.w600, color: Colors.black))],
      ]),
    );
  }
}

/// S26 — Undang via QR (berlaku 15 menit).
class InviteQrScreen extends StatefulWidget {
  const InviteQrScreen({super.key});
  @override
  State<InviteQrScreen> createState() => _InviteQrScreenState();
}

class _InviteQrScreenState extends State<InviteQrScreen> {
  String? data;
  int left = 900;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) WakelockPlus.enable();
    _make();
  }

  Future<void> _make() async {
    final d = await Hub.i.inviteQr();
    _t?.cancel();
    setState(() {
      data = d;
      left = 900;
    });
    _t = Timer.periodic(const Duration(seconds: 1), (_) => setState(() => left--));
  }

  @override
  void dispose() {
    _t?.cancel();
    if (!kIsWeb) WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final expired = left <= 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Undang via QR')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        const Text('Minta temanmu install CarterTag Connect, pilih "Punya QR undangan? Scan", lalu arahkan kamera ke sini.'),
        const SizedBox(height: 20),
        if (data != null && !expired) Center(child: QrCard(data: data!, caption: 'Berlaku ${left ~/ 60}:${(left % 60).toString().padLeft(2, '0')}')),
        if (expired) const InfoBanner(margin: EdgeInsets.zero, tone: Tone.warn, text: 'QR kedaluwarsa.'),
        const SizedBox(height: 16),
        OutlinedButton.icon(onPressed: _make, icon: const Icon(LucideIcons.refreshCw), label: const Text('Buat ulang')),
        const SizedBox(height: 12),
        const InfoBanner(margin: EdgeInsets.zero, tone: Tone.info, text: 'QR ini berisi kunci grup. Tunjukkan langsung, jangan difoto & disebar.'),
      ]),
    );
  }
}

/// S27 — Mode Jembatan iPhone (host Android).
class BridgeHostScreen extends StatefulWidget {
  const BridgeHostScreen({super.key});
  @override
  State<BridgeHostScreen> createState() => _BridgeHostScreenState();
}

class _BridgeHostScreenState extends State<BridgeHostScreen> {
  Map? info;
  bool busy = false;
  String? error;
  String token = '';
  int tokenExp = 0;
  final clients = <String, String>{}; // client -> nama / status
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) WakelockPlus.enable();
    _sub = Mesh.i.bridgeEvents.listen(_onEvent);
  }

  @override
  void dispose() {
    _sub?.cancel();
    if (!kIsWeb) WakelockPlus.disable();
    super.dispose();
  }

  void _newToken() {
    final r = Random.secure();
    token = List.generate(12, (_) => 'abcdefghjkmnpqrstuvwxyz23456789'[r.nextInt(31)]).join();
    tokenExp = DateTime.now().add(const Duration(minutes: 10)).millisecondsSinceEpoch;
  }

  Future<void> _start() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      _newToken();
      final i = await Mesh.i.bridgeStart();
      setState(() => info = i);
    } catch (e) {
      setState(() => error = '$e'.replaceAll('PlatformException', ''));
    } finally {
      setState(() => busy = false);
    }
  }

  Future<void> _stop() async {
    await Mesh.i.bridgeStop();
    setState(() {
      info = null;
      clients.clear();
    });
  }

  Future<void> _onEvent(Map ev) async {
    final client = '${ev['client']}';
    if (ev['e'] == 'bridge_client') {
      setState(() => ev['state'] == 'closed' ? clients.remove(client) : clients[client] = 'Menyambung…');
      return;
    }
    Map<String, dynamic> hello;
    try {
      hello = (jsonDecode('${ev['data']}') as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    if (hello['t'] != 'hello') return;
    final h = Hub.i;
    String deny(String reason) => jsonEncode({'t': 'denied', 'reason': reason});
    if (hello['token'] != token || DateTime.now().millisecondsSinceEpoch > tokenExp) {
      await Mesh.i.bridgeReply(client, deny('QR sudah kedaluwarsa. Minta host menampilkan QR baru.'));
      return;
    }
    if ('${hello['pe'] ?? ''}'.isEmpty || '${hello['n'] ?? ''}'.trim().isEmpty) {
      await Mesh.i.bridgeReply(client, deny('Nama wajib diisi.'));
      return;
    }
    // identitas = kunci perangkat iPhone (sama seperti member_id di server)
    final mid = await memberIdFor(h.slug, '${hello['pe']}');
    hello['mid'] = mid;
    final known = h.member(mid);
    var ok = known != null;
    if (!ok && mounted) {
      // klien iPhone versi lama bisa mengirim "C3": normalkan di host juga
      final car = carDigits('${hello['car'] ?? ''}');
      hello['car'] = car;
      ok = await confirm(context,
          title: 'Izinkan ${hello['n']} bergabung?',
          text: car.isEmpty ? 'Masuk sebagai anggota tim. Izinkan hanya kalau kamu kenal orangnya.' : 'Masuk sebagai driver mobil $car. Izinkan hanya kalau kamu kenal orangnya.',
          action: 'Izinkan');
    }
    if (!ok) {
      await Mesh.i.bridgeReply(client, deny('Host tidak mengizinkan.'));
      return;
    }
    if (known != null) {
      hello['r'] = known.role;
      hello['car'] = known.car;
      hello['area'] = known.area;
    } else {
      hello['r'] = '${hello['car'] ?? ''}'.trim().isEmpty ? 'panitia' : 'driver';
    }
    await Mesh.i.bridgeReply(client, jsonEncode({'t': 'welcome', 'host': h.me.name, 'bundle': h.bridgeBundleFor(hello)}));
    setState(() => clients[client] = '${hello['n']}');
  }

  @override
  Widget build(BuildContext context) {
    final i = info;
    final ssid = '${i?['ssid'] ?? ''}', pass = '${i?['pass'] ?? ''}';
    final url = 'http://${i?['ip'] ?? '192.168.49.1'}:${i?['port'] ?? 8787}/#t=$token';
    return Scaffold(
      appBar: AppBar(title: const Text('Mode Jembatan iPhone')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        const Text('Bantu teman pakai iPhone ikut chat tanpa internet. iPhone tersambung ke Wi-Fi HP ini, lalu membuka web app.'),
        const SizedBox(height: 12),
        const InfoBanner(margin: EdgeInsets.zero, tone: Tone.warn, text: 'Jembatan memakai baterai lebih banyak (±10%/jam). Maks 6 iPhone.'),
        const SizedBox(height: 16),
        if (error != null) InfoBanner(margin: const EdgeInsets.only(bottom: 12), tone: Tone.danger, text: error!),
        if (i == null)
          FilledButton.icon(onPressed: busy ? null : _start, icon: const Icon(LucideIcons.link), label: Text(busy ? 'Menyiapkan Wi-Fi Direct…' : 'Aktifkan jembatan'))
        else ...[
          Text('Langkah 1 · Sambungkan Wi-Fi', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          const Text('Di iPhone: buka Kamera, arahkan ke QR ini, ketuk "Gabung ke jaringan".'),
          const SizedBox(height: 12),
          Center(child: QrCard(data: 'WIFI:S:$ssid;T:WPA;P:$pass;;', caption: 'Wi-Fi: $ssid\nSandi: $pass')),
          const SizedBox(height: 24),
          Text('Langkah 2 · Buka web app', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          const Text('Setelah tersambung, scan QR ini dengan Kamera lalu buka di Safari.'),
          const SizedBox(height: 12),
          Center(child: QrCard(data: url, caption: url)),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => setState(_newToken),
            icon: const Icon(LucideIcons.refreshCw),
            label: const Text('Buat QR langkah 2 baru (berlaku 10 menit)'),
          ),
          const SectionLabel('iPhone tersambung'),
          if (clients.isEmpty) const Text('Belum ada.'),
          for (final e in clients.entries)
            ListTile(
              leading: const Icon(LucideIcons.user),
              title: Text(e.value),
              trailing: TextButton(onPressed: () => Mesh.i.bridgeKick(e.key), child: const Text('Putuskan')),
            ),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: _stop, child: const Text('Matikan jembatan')),
        ],
      ]),
    );
  }
}
