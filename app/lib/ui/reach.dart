import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:sembast/sembast.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/theme.dart';
import '../services/hub.dart';
import '../services/location.dart';
import '../services/mesh.dart';
import '../services/online.dart';
import 'widgets.dart';

// ============================================================ penilaian sinyal

/// Tingkat sinyal relatif ke ambang "melemah" hasil kalibrasi: 4 kuat · 3 bagus · 2 sedang · 1 lemah.
int signalLevel(double rssi, double weak) => rssi >= weak + 14 ? 4 : (rssi >= weak + 7 ? 3 : (rssi >= weak ? 2 : 1));

String signalLabel(int level) => const ['', 'Lemah', 'Sedang', 'Bagus', 'Kuat'][level];

/// Perkiraan jarak dari RSSI, dikalibrasi: di ambang "melemah" = radius jangkauan. Kasar (±50%), hanya panduan.
double rssiMeters(double rssi, double weak, double radius) => (radius * pow(10, (weak - rssi) / 25)).clamp(1, 300).toDouble();

/// Status rantai GPS satu anggota: tersambung ke koordinator lewat lingkaran yang saling bersentuhan?
enum ChainState { linked, edge, cut, unknown }

/// Graf lingkaran jangkauan (radius R) dari posisi GPS terakhir (<= 10 mnt) + sambungan Bluetooth nyata saya.
/// linked = satu rantai dengan koordinator; edge = tersambung tapi tetangga terdekat > 80% R; cut = terpisah.
Map<String, ChainState> chainStates({
  required String meId,
  required Fix? meFix,
  required Map<String, LatLng> pos,
  required Set<String> koords,
  required Set<String> myBleLinks,
  required double radius,
}) {
  final nodes = <String, LatLng>{...pos};
  if (meFix != null) nodes[meId] = LatLng(meFix.lat, meFix.lng);
  final ids = nodes.keys.toList();
  final adj = {for (final i in ids) i: <String>{}};
  final nearest = <String, double>{};
  for (var a = 0; a < ids.length; a++) {
    for (var b = a + 1; b < ids.length; b++) {
      final pa = nodes[ids[a]]!, pb = nodes[ids[b]]!;
      final d = haversine(pa.latitude, pa.longitude, pb.latitude, pb.longitude);
      nearest[ids[a]] = min(nearest[ids[a]] ?? double.infinity, d);
      nearest[ids[b]] = min(nearest[ids[b]] ?? double.infinity, d);
      if (d <= radius) {
        adj[ids[a]]!.add(ids[b]);
        adj[ids[b]]!.add(ids[a]);
      }
    }
  }
  // sambungan Bluetooth nyata = pasti satu rantai, walau GPS bilang jauh
  for (final m in myBleLinks) {
    if (adj.containsKey(m) && adj.containsKey(meId)) {
      adj[m]!.add(meId);
      adj[meId]!.add(m);
    }
  }
  final seen = <String>{};
  final queue = [for (final k in koords) if (adj.containsKey(k)) k];
  // tidak ada koordinator dengan posisi segar: rantai tidak bisa dinilai (jangan warnai semua "terpisah")
  if (queue.isEmpty) return {for (final i in ids) i: ChainState.unknown};
  seen.addAll(queue);
  while (queue.isNotEmpty) {
    for (final n in adj[queue.removeLast()]!) {
      if (seen.add(n)) queue.add(n);
    }
  }
  return {
    for (final i in ids)
      i: koords.isEmpty
          ? ChainState.unknown
          : !seen.contains(i)
              ? ChainState.cut
              : ((nearest[i] ?? 0) > radius * 0.8 && !koords.contains(i) ? ChainState.edge : ChainState.linked),
  };
}

// ============================================================ panel di tab Lokasi

/// Panel "Jangkauan Tim": status (dari service native) + HP tim di sekitar dengan kekuatan sinyal Bluetooth.
class ReachPanel extends StatefulWidget {
  const ReachPanel({super.key});
  @override
  State<ReachPanel> createState() => _ReachPanelState();
}

class _ReachPanelState extends State<ReachPanel> {
  List<Peer> peers = Mesh.i.peers;
  Map reach = Mesh.i.reach;
  final _hist = <String, List<(int, double)>>{}; // node/addr -> (ms, rssi) 15 dtk terakhir, untuk tren
  final _subs = <StreamSubscription>[];

  @override
  void initState() {
    super.initState();
    _subs.add(Mesh.i.signalStream.listen((l) {
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final p in l) {
        final r = p.rssiSmooth;
        if (r == null) continue;
        final h = _hist.putIfAbsent(_key(p), () => []);
        h.add((now, r));
        h.removeWhere((e) => now - e.$1 > 15000);
      }
      if (mounted) setState(() => peers = l);
    }));
    _subs.add(Mesh.i.reachStream.listen((r) {
      if (mounted) setState(() => reach = r);
    }));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  String _key(Peer p) => p.node.isNotEmpty ? p.node : p.addr;

  /// +1 menguat, -1 melemah, 0 stabil (selisih > 4 dB dalam ~10 dtk).
  int _trend(Peer p) {
    final h = _hist[_key(p)];
    if (h == null || h.length < 3) return 0;
    final now = h.last.$1;
    final old = h.firstWhere((e) => now - e.$1 >= 8000, orElse: () => h.first);
    final d = h.last.$2 - old.$2;
    return d > 4 ? 1 : (d < -4 ? -1 : 0);
  }

  @override
  Widget build(BuildContext context) {
    final h = Hub.i;
    final c = CT.of(context);
    if (!Mesh.i.supported) {
      return const InfoBanner(icon: LucideIcons.bluetooth, text: 'Jangkauan Bluetooth hanya tersedia di app Android. Di sini cukup lokasi lewat internet.');
    }
    final st = '${reach['st'] ?? 'idle'}';
    final list = [...peers]..sort((a, b) => (b.rssiSmooth ?? -200).compareTo(a.rssiSmooth ?? -200));
    final linked = list.where((p) => p.connected).toList();
    final nearest = linked.isEmpty ? null : linked.first;
    final nearestName = nearest == null ? '' : (h.member(nearest.memberId)?.displayName ?? 'HP tim');
    final (Color bg, Color fg, IconData icon, String title, String sub) = switch (st) {
      'online' => (c.accentBg, c.accent, LucideIcons.wifi, 'Online', 'Pesan lewat internet. Bluetooth tetap siaga kalau sinyal hilang.'),
      'ok' => (c.okBg, c.ok, LucideIcons.shieldCheck, 'Aman, tersambung ke tim',
          '${linked.length} HP tim tersambung${nearestName.isEmpty ? '' : ' · terdekat $nearestName'}'),
      'weak' => (c.amberBg, c.amber, LucideIcons.triangleAlert, 'Sinyal ke tim melemah',
          nearestName.isEmpty ? 'Jangan menjauh, balik sedikit ke arah tim.' : 'Jangan menjauh dari $nearestName, balik sedikit ke arah tim.'),
      'lost' => (c.dangerBg, c.danger, LucideIcons.wifiOff, 'Terputus dari tim', 'Tidak ada HP tim di sekitar. Pesan tidak akan sampai. Kembali ke arah tim / posko.'),
      'btoff' => (c.amberBg, c.amber, LucideIcons.bluetoothOff, 'Bluetooth mati', 'Nyalakan Bluetooth supaya tetap tersambung ke tim tanpa internet.'),
      _ => (c.cardLow, c.muted, LucideIcons.bluetooth, 'Belum ada HP tim di sekitar', 'Begitu dekat HP tim (±${h.reachRadius.round()} m), status muncul di sini.'),
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Semantics(
        liveRegion: true,
        label: '$title. $sub',
        child: Container(
          margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16)),
          child: Row(children: [
            Icon(icon, size: 30, color: fg),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: fg)),
                const SizedBox(height: 2),
                Text(sub, style: TextStyle(fontSize: 13.5, color: c.ink)),
              ]),
            ),
          ]),
        ),
      ),
      if (h.me.isKoord && h.reachEvents.isNotEmpty) ...[
        const SectionLabel('Anggota menjauh / lepas (30 mnt terakhir)'),
        for (final e in h.reachEvents.take(6))
          ListTile(
            minTileHeight: 52,
            leading: Icon(e['kind'] == 'weak' ? LucideIcons.signalLow : LucideIcons.userX, color: e['kind'] == 'weak' ? c.amber : c.danger),
            title: Text(h.member('${e['mid']}')?.displayName ?? 'Anggota'),
            subtitle: Text([
              e['kind'] == 'weak' ? 'sinyal melemah' : 'lepas dari jangkauan',
              if (e['by'] != e['mid'] && h.member('${e['by']}') != null) 'terakhir dekat ${h.member('${e['by']}')!.displayName}',
              timeAgo(e['at'] as int),
            ].join(' · ')),
          ),
      ],
      SectionLabel('HP tim di sekitar (Bluetooth)',
          trailing: Text('jangkauan ±${h.reachRadius.round()} m', style: mono(11.5, color: c.muted))),
      if (list.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text('Belum terdeteksi. Pastikan Bluetooth & Lokasi HP menyala.', style: TextStyle(color: c.muted)),
        ),
      for (final p in list.take(8)) _peerTile(context, p),
      SwitchListTile(
        title: const Text('Peringatan jangkauan'),
        subtitle: Text(h.reachMuted
            ? 'Didiamkan sampai ${hhmm(h.reachMuteUntil)}'
            : 'Bunyi & getar saat sinyal ke tim melemah atau terputus, walau layar mati. Diam saat ada internet.'),
        value: h.reachAlerts,
        onChanged: (v) async {
          await h.setReachAlerts(v);
          if (mounted) setState(() {});
        },
      ),
      if (h.reachAlerts)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              // driver yang sedang berangkat / pulang memang menjauh dari tim
              onPressed: () async {
                await h.muteReach(h.reachMuted ? null : const Duration(minutes: 30));
                if (mounted) setState(() {});
              },
              icon: Icon(h.reachMuted ? LucideIcons.bellRing : LucideIcons.bellOff, size: 18),
              label: Text(h.reachMuted ? 'Aktifkan lagi sekarang' : 'Diamkan 30 menit (sedang menyetir)'),
            ),
          ),
        ),
      if (h.disbandedToday)
        InfoBanner(
          tone: Tone.ok,
          icon: LucideIcons.flagTriangleRight,
          text: 'Tim sudah dibubarkan${'${h.reachDisband['by'] ?? ''}'.isEmpty ? '' : ' oleh ${h.reachDisband['by']}'}. Peringatan jangkauan mati sampai hari konser berikutnya.',
          action: h.me.isKoord ? 'Batalkan' : null,
          onAction: h.me.isKoord
              ? () async {
                  await h.disbandTeam(undo: true);
                  if (mounted) setState(() {});
                }
              : null,
        )
      else if (h.me.isKoord && h.reachDay)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: OutlinedButton.icon(
            onPressed: () async {
              if (!await confirm(context,
                  title: 'Selesai, bubarkan tim?',
                  text: 'Peringatan jangkauan di semua HP tim dimatikan sampai hari konser berikutnya. Chat tetap jalan.',
                  action: 'Bubarkan')) {
                return;
              }
              await h.disbandTeam();
              if (mounted) setState(() {});
            },
            icon: const Icon(LucideIcons.flagTriangleRight, size: 18),
            label: const Text('Selesai, bubarkan tim'),
          ),
        ),
      if (h.me.isKoord)
        ListTile(
          minTileHeight: 56,
          leading: const Icon(LucideIcons.ruler),
          title: const Text('Kalibrasi jangkauan'),
          subtitle: Text(h.reachBy.isEmpty ? 'Belum dikalibrasi (default ±30 m)' : 'Terakhir oleh ${h.reachBy} · ambang ${h.reachWeak.round()} dBm'),
          trailing: const Icon(LucideIcons.chevronRight),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CalibrationScreen())),
        ),
    ]);
  }

  Widget _peerTile(BuildContext context, Peer p) {
    final h = Hub.i;
    final c = CT.of(context);
    final m = h.member(p.memberId);
    if (p.via == 'wifi') {
      // Wi-Fi posko: tersambung lewat router yang sama (tidak ada RSSI per HP)
      return ListTile(
        minTileHeight: 56,
        leading: Icon(LucideIcons.wifi, color: c.ok),
        title: Text(m?.displayName ?? 'HP tim', maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: const Text('Tersambung lewat Wi-Fi posko'),
      );
    }
    final r = p.rssiSmooth;
    final lvl = r == null ? 0 : signalLevel(r, h.reachWeak);
    final tr = _trend(p);
    final color = lvl >= 3 ? c.ok : (lvl == 2 ? c.amber : c.danger);
    final name = m?.displayName ?? (p.memberId.isEmpty ? 'HP tim' : 'Anggota');
    final parts = [
      if (r != null) '${signalLabel(lvl)} · ≈${rssiMeters(r, h.reachWeak, h.reachRadius).round()} m',
      if (!p.connected) 'terdeteksi, belum tersambung',
      if (tr < 0) 'melemah',
      if (tr > 0) 'menguat',
    ];
    return ListTile(
      minTileHeight: 56,
      leading: _Bars(level: lvl, color: color),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(parts.join(' · '), style: TextStyle(color: tr < 0 ? c.amber : null)),
      trailing: r == null ? null : Text('${r.round()} dBm', style: mono(12, color: c.muted)),
    );
  }
}

/// Batang sinyal 4 tingkat.
class _Bars extends StatelessWidget {
  const _Bars({required this.level, required this.color});
  final int level;
  final Color color;
  @override
  Widget build(BuildContext context) {
    final off = CT.of(context).line;
    return Semantics(
      label: level == 0 ? 'Sinyal belum terbaca' : 'Sinyal ${signalLabel(level)}',
      child: SizedBox(
        width: 28,
        height: 22,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          for (var i = 1; i <= 4; i++)
            Container(width: 5, height: 5.0 + i * 4, decoration: BoxDecoration(color: i <= level ? color : off, borderRadius: BorderRadius.circular(2))),
        ]),
      ),
    );
  }
}

// ============================================================ peta

/// Peta OpenStreetMap + lingkaran jangkauan tiap anggota (warna = status rantai ke koordinator).
/// Potongan peta yang pernah tampil saat online tersimpan otomatis (cache flutter_map), jadi tetap tampil tanpa internet.
class ReachMap extends StatelessWidget {
  const ReachMap({super.key, required this.me, required this.locs});
  final Fix? me;
  final List<RecordSnapshot<String, Map<String, Object?>>> locs;

  @override
  Widget build(BuildContext context) {
    final h = Hub.i;
    final c = CT.of(context);
    final now = DateTime.now().millisecondsSinceEpoch;
    final pos = <String, LatLng>{};
    final age = <String, int>{};
    for (final r in locs) {
      final mid = '${r.value['mid']}';
      if (mid == h.me.id || h.member(mid) == null) continue;
      final at = (r.value['at'] as num?)?.toInt() ?? 0;
      if (now - at > 10 * 60000) continue; // posisi > 10 mnt terlalu basi untuk menilai rantai
      pos[mid] = LatLng((r.value['lat'] as num).toDouble(), (r.value['lng'] as num).toDouble());
      age[mid] = at;
    }
    final koords = {for (final m in h.roster) if (m.isKoord) m.id};
    final ble = {for (final p in Mesh.i.peers) if (p.connected && p.memberId.isNotEmpty) p.memberId};
    final states = chainStates(meId: h.me.id, meFix: me, pos: pos, koords: koords, myBleLinks: ble, radius: h.reachRadius);
    Color colorOf(String id) => switch (states[id]) {
          ChainState.linked => c.ok,
          ChainState.edge => c.amber,
          ChainState.cut => c.danger,
          _ => c.accent,
        };
    final center = me != null ? LatLng(me!.lat, me!.lng) : (pos.isNotEmpty ? pos.values.first : null);
    if (center == null) {
      return const SizedBox(height: 120, child: EmptyState(icon: LucideIcons.map, title: 'Menunggu lokasi', text: 'Peta tampil begitu GPS HP ini atau anggota tim terbaca.'));
    }
    final all = {...pos, if (me != null) h.me.id: LatLng(me!.lat, me!.lng)};
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        height: 380,
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: c.line)),
        child: FlutterMap(
          options: MapOptions(initialCenter: center, initialZoom: 18, maxZoom: 19, minZoom: 12),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'id.cartertag.connect',
              maxNativeZoom: 19,
            ),
            CircleLayer(circles: [
              for (final e in all.entries)
                CircleMarker(
                  point: e.value,
                  radius: h.reachRadius,
                  useRadiusInMeter: true,
                  color: colorOf(e.key).withValues(alpha: 0.14),
                  borderColor: colorOf(e.key).withValues(alpha: 0.8),
                  borderStrokeWidth: e.key == h.me.id ? 2.5 : 1.5,
                ),
            ]),
            MarkerLayer(markers: [
              for (final e in all.entries)
                Marker(
                  point: e.value,
                  width: 120,
                  height: 46,
                  child: _MapPin(
                    label: e.key == h.me.id ? 'Saya' : (h.member(e.key)?.tagLabel ?? '?'),
                    color: colorOf(e.key),
                    stale: e.key != h.me.id && now - (age[e.key] ?? now) > 3 * 60000,
                  ),
                ),
            ]),
            // kebijakan tile OSM: atribusi harus selalu terlihat (tidak boleh di balik tombol)
            const SimpleAttributionWidget(source: Text('© OpenStreetMap contributors')),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Wrap(spacing: 12, runSpacing: 4, children: [
          _legend(c.ok, 'satu rantai dengan koordinator'),
          _legend(c.amber, 'di pinggir jangkauan'),
          _legend(c.danger, 'terpisah'),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
        child: Text(
            'Lingkaran = jangkauan Bluetooth ±${h.reachRadius.round()} m dari posisi GPS terakhir (tiap 1 menit). Perkiraan; penentu akhirnya sinyal Bluetooth di atas. '
            'Bagian peta yang pernah dibuka saat ada internet mungkin tetap tampil tanpa sinyal; lingkaran & posisi tim selalu tampil.',
            style: TextStyle(fontSize: 12, color: c.muted)),
      ),
    ]);
  }

  Widget _legend(Color color, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 12, height: 12, decoration: BoxDecoration(color: color.withValues(alpha: 0.3), border: Border.all(color: color, width: 2), shape: BoxShape.circle)),
        const SizedBox(width: 5),
        Text(text, style: const TextStyle(fontSize: 12)),
      ]);
}

class _MapPin extends StatelessWidget {
  const _MapPin({required this.label, required this.color, required this.stale});
  final String label;
  final Color color;
  final bool stale;
  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6), border: Border.all(color: color, width: 1.5)),
        child: Text(stale ? '$label · lama' : label,
            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF0B0B0F))),
      ),
      const SizedBox(height: 2),
      Container(width: 14, height: 14, decoration: BoxDecoration(color: color, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2))),
    ]);
  }
}

// ============================================================ kalibrasi

/// Kalibrasi jangkauan: satu koordinator diam (titik pusat), HP ini dibawa jalan menjauh sampai sambungan Bluetooth
/// ke HP itu putus. Sinyal & jarak saat putus jadi ambang "melemah" + radius untuk semua HP tim.
class CalibrationScreen extends StatefulWidget {
  const CalibrationScreen({super.key});
  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _Break {
  _Break(this.rssi, this.meters);
  final double rssi;
  final double? meters;
}

class _CalibrationScreenState extends State<CalibrationScreen> {
  String? anchor; // member_id HP pusat
  bool walking = false;
  final _samples = <(int, double, double?)>[]; // (ms, rssi, jarak m)
  final breaks = <_Break>[];
  List<Peer> peers = Mesh.i.peers;
  StreamSubscription? _sub;
  Timer? _gps;
  Fix? me = LocationSvc.i.last;
  int _lostTicks = 0;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) WakelockPlus.enable();
    _sub = Mesh.i.signalStream.listen(_onSignal);
    _gps = Timer.periodic(const Duration(seconds: 5), (_) async {
      final f = await LocationSvc.i.current();
      if (mounted && f != null) setState(() => me = f);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _gps?.cancel();
    if (!kIsWeb) WakelockPlus.disable();
    super.dispose();
  }

  // kalibrasi mengukur jangkauan Bluetooth: abaikan sambungan lewat Wi-Fi posko
  Peer? get _anchorPeer => anchor == null ? null : peers.where((p) => p.memberId == anchor && p.via != 'wifi').firstOrNull;

  /// Jarak saya ke HP pusat dari GPS (posisi pusat = lokasi terakhir yang dibagikannya; pusat diam, jadi cukup).
  Future<double?> _dist() async {
    final f = me;
    // GPS meleset > 20 m membuat radius tidak bisa dipercaya
    if (f == null || anchor == null || f.acc > 20) return null;
    final l = await Hub.i.s.locations.record('${Hub.i.slug}|$anchor').get(Hub.i.s.db);
    if (l == null) return null;
    return haversine(f.lat, f.lng, (l['lat'] as num).toDouble(), (l['lng'] as num).toDouble());
  }

  Future<void> _onSignal(List<Peer> l) async {
    if (!mounted) return;
    setState(() => peers = l);
    if (!walking) return;
    final p = _anchorPeer;
    final r = p?.connected == true ? p!.rssiSmooth : null;
    // Setelah radio benar-benar putus, Android masih menganggap link tersambung sampai ±20 dtk dan bacaan RSSI MENTAH-nya membeku.
    // Sampel "hidup" = bacaan mentah berubah dalam 4 dtk terakhir. Membeku hanya dianggap batas kalau sinyal memang sudah
    // lemah atau sudah cukup jauh (HP diam dekat pusat dengan sinyal stabil bukan batas).
    final now = DateTime.now().millisecondsSinceEpoch;
    final frozen = r != null && p!.rawChangedAt > 0 && now - p.rawChangedAt > 4000;
    if (frozen && r > Hub.i.reachWeak + 10 && ((_samples.isEmpty ? null : _samples.last.$3) ?? 0) <= 5) {
      _lostTicks = 0;
      return; // dekat & kuat: abaikan, belum batas
    }
    if (r != null && !frozen) {
      _lostTicks = 0;
      _samples.add((DateTime.now().millisecondsSinceEpoch, r, await _dist()));
      if (_samples.length > 200) _samples.removeAt(0);
      return;
    }
    // putus: tanpa sambungan 2 tick (±6 dtk) atau sinyal membeku 3 tick = titik batas
    if (++_lostTicks < (frozen ? 3 : 2) || _samples.isEmpty) return;
    // batas = sampel hidup terakhir (bukan rata-rata yang tercampur bacaan basi)
    final lastLive = _samples.last;
    final ds = _samples.sublist(max(0, _samples.length - 2)).map((e) => e.$3).whereType<double>().toList();
    breaks.add(_Break(lastLive.$2, lastLive.$3 ?? (ds.isEmpty ? null : ds.last)));
    _samples.clear();
    _lostTicks = 0;
    HapticFeedback.heavyImpact();
    if (mounted) {
      setState(() => walking = false);
      toast(context, 'Batas tercatat. Balik ke dekat pusat, lalu ulangi ke arah lain.');
    }
  }

  double? get _weak {
    if (breaks.isEmpty) return null;
    final rs = breaks.map((b) => b.rssi).toList()..sort();
    // ambang melemah = sedikit di atas sinyal saat putus, supaya peringatan datang sebelum benar-benar putus
    return (rs[rs.length ~/ 2] + 5).clamp(-96.0, -70.0).toDouble();
  }

  double? get _radius {
    final ds = breaks.map((b) => b.meters).whereType<double>().toList()..sort();
    if (ds.isEmpty) return null;
    return ds[ds.length ~/ 2].clamp(5.0, 150.0).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final h = Hub.i;
    final c = CT.of(context);
    final linked = peers.where((p) => p.connected && p.memberId.isNotEmpty && p.via != 'wifi').toList();
    final ap = _anchorPeer;
    final cur = ap?.connected == true ? ap!.rssiSmooth : null;
    final w = _weak, r = _radius;
    return Scaffold(
      appBar: AppBar(title: const Text('Kalibrasi jangkauan')),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        const InfoBanner(
          tone: Tone.info,
          icon: LucideIcons.footprints,
          text: '1. Satu HP tim diam di satu titik (pusat). 2. Pilih HP itu di bawah. 3. Tekan Mulai lalu jalan menjauh sampai HP bergetar (sambungan putus). '
              'Ulangi 2–3 arah. Lakukan saat area sudah ramai: badan orang meredam sinyal.',
        ),
        const SectionLabel('HP pusat'),
        if (linked.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('Belum ada HP tim yang tersambung. Dekatkan ke HP pusat dulu.', style: TextStyle(color: c.muted)),
          ),
        RadioGroup<String>(
          groupValue: anchor,
          onChanged: (v) => walking ? null : setState(() => anchor = v),
          child: Column(children: [
            for (final p in linked)
              RadioListTile<String>(
                value: p.memberId,
                title: Text(h.member(p.memberId)?.displayName ?? 'HP tim'),
                subtitle: Text(p.rssiSmooth == null ? 'sinyal belum terbaca' : '${p.rssiSmooth!.round()} dBm'),
              ),
          ]),
        ),
        Container(
          margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: c.cardLow, borderRadius: BorderRadius.circular(16)),
          child: Column(children: [
            Text(cur == null ? (walking ? 'Sambungan ke pusat hilang…' : '—') : '${cur.round()} dBm', style: mono(36, w: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(walking ? 'Terus jalan menjauh. HP bergetar saat batas tercapai.' : 'Sinyal ke HP pusat', style: TextStyle(color: c.muted)),
            if (me != null)
              Text('GPS ±${me!.acc.round()} m${me!.acc > 20 ? ' (kurang akurat, jarak tidak dicatat)' : ''}',
                  style: TextStyle(fontSize: 12, color: me!.acc > 20 ? c.amber : c.muted)),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: anchor == null
                  ? null
                  : () => setState(() {
                        walking = !walking;
                        _samples.clear();
                        _lostTicks = 0;
                      }),
              icon: Icon(walking ? LucideIcons.square : LucideIcons.play),
              label: Text(walking ? 'Berhenti' : (breaks.isEmpty ? 'Mulai jalan' : 'Ulangi ke arah lain')),
            ),
          ]),
        ),
        if (breaks.isNotEmpty) ...[
          SectionLabel('Batas tercatat (${breaks.length})'),
          for (final (i, b) in breaks.indexed)
            ListTile(
              dense: true,
              leading: Text('#${i + 1}', style: mono(13, w: FontWeight.w700)),
              title: Text('Putus di ${b.rssi.round()} dBm${b.meters == null ? '' : ' · ±${b.meters!.round()} m'}'),
            ),
          Container(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: c.okBg, borderRadius: BorderRadius.circular(16)),
            child: Text(
              'Hasil: peringatan "melemah" di ${w!.round()} dBm'
              '${r == null ? '' : ', jangkauan ±${r.round()} m'}.'
              '${r == null ? ' Jarak tidak terukur (GPS HP ini / pusat belum ada), radius tetap ${h.reachRadius.round()} m.' : ''}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: FilledButton.icon(
              onPressed: () async {
                await h.applyReachCalibration(weakDbm: w, radiusM: r ?? h.reachRadius);
                if (!context.mounted) return;
                toast(context, Online.i.connected || h.meshPeers > 0 ? 'Dipakai & disebar ke semua HP tim' : 'Dipakai di HP ini. Disebar begitu tersambung ke tim.');
                Navigator.of(context).pop();
              },
              icon: const Icon(LucideIcons.send),
              label: const Text('Pakai & sebarkan ke tim'),
            ),
          ),
          TextButton(onPressed: () => setState(breaks.clear), child: const Text('Hapus hasil, ulang dari awal')),
        ],
      ]),
    );
  }
}
