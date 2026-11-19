import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/ids.dart';
import '../core/theme.dart';
import '../main.dart';
import '../services/hub.dart';
import '../services/mesh.dart';
import '../services/online.dart';
import '../services/updater.dart';
import 'widgets.dart';

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

  @override
  Widget build(BuildContext context) {
    final h = Hub.i;
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
        onTap: () async {
          if (await confirm(context, title: 'Keluar dari konser?', text: 'Semua chat & data konser ini di HP ini dihapus. Tidak bisa dibatalkan.', action: 'Keluar & hapus', danger: true)) {
            await h.leave();
          }
        },
      ),
      if (!kIsWeb)
        ListenableBuilder(
          listenable: Updater.i,
          builder: (context, _) {
            final up = Updater.i.available;
            return ListTile(
              minTileHeight: 56,
              leading: Icon(up != null ? LucideIcons.download : LucideIcons.refreshCw, color: up != null ? c.accent : null),
              title: Text(up != null ? 'Update ke versi ${up.version}' : 'Cek pembaruan'),
              subtitle: Text(Updater.i.checking ? 'Memeriksa…' : 'Versi terpasang ${h.appVersion}'),
              onTap: Updater.i.checking
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
                if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
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
        final peers = h.meshPeersList;
        return Scaffold(
          appBar: AppBar(title: const Text('Koneksi')),
          body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
            const Padding(padding: EdgeInsets.all(16), child: Align(alignment: Alignment.centerLeft, child: ConnPill())),
            const SectionLabel('Internet'),
            _kv('Jaringan HP', h.netUp ? 'Ada' : 'Tidak ada'),
            _kv('Server realtime', Online.i.ready ? (Online.i.connected ? 'Tersambung' : 'Terputus') : 'Belum diatur (hanya mesh)'),
            _kv('Gateway', Online.i.connected && h.meshPeers > 0 ? 'Aktif: pesan mesh diteruskan ke internet' : 'Tidak aktif'),
            const SectionLabel('Mesh (Bluetooth)'),
            _kv('Service', Mesh.i.supported ? (Mesh.i.running ? 'Berjalan' : 'Mati') : 'Tidak tersedia di perangkat ini'),
            _kv('Link aktif', '${status['links'] ?? peers.length}'),
            if (status['bridgeClients'] != null && status['bridgeClients'] != 0) _kv('Klien jembatan', '${status['bridgeClients']}'),
            for (final p in peers)
              ListTile(
                leading: const Icon(LucideIcons.bluetooth),
                title: Text(h.member(p.memberId)?.name ?? (p.memberId.isEmpty ? 'HP tim' : p.memberId)),
                subtitle: Text('${p.via.toUpperCase()} · RSSI ${p.rssi} dBm · ±${p.meters.round()} m'),
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
      final car = '${hello['car'] ?? ''}'.trim();
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
