import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sembast/sembast.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/theme.dart';
import '../services/hub.dart';
import '../services/location.dart';
import 'widgets.dart';

class Target {
  Target({required this.id, required this.name, required this.role, required this.lat, required this.lng, required this.at, this.acc, this.sos = false});
  final String id, name, role;
  final double lat, lng;
  final double? acc;
  final int at;
  final bool sos;
}

/// Heading kompas (derajat dari utara). Null di web / tanpa sensor.
Stream<double?> headingStream() {
  if (kIsWeb) return Stream.value(null);
  return FlutterCompass.events?.map((e) => e.heading) ?? Stream.value(null);
}

/// S16 — Radar anggota (jalan offline: GPS + kompas, tanpa peta).
class RadarScreen extends StatefulWidget {
  const RadarScreen({super.key});
  @override
  State<RadarScreen> createState() => _RadarScreenState();
}

class _RadarScreenState extends State<RadarScreen> {
  Fix? me = LocationSvc.i.last;
  bool share = true;
  late final _locs = Hub.i.watch(Hub.i.s.locations);
  Timer? _t;

  @override
  void initState() {
    super.initState();
    Hub.i.s.get<bool>('share_loc').then((v) => setState(() => share = v ?? true));
    _refreshFix();
    _t = Timer.periodic(const Duration(seconds: 15), (_) => _refreshFix());
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  Future<void> _refreshFix() async {
    final f = await LocationSvc.i.current();
    if (mounted) setState(() => me = f);
  }

  @override
  Widget build(BuildContext context) {
    final h = Hub.i;
    final c = CT.of(context);
    return StreamBuilder<List<RecordSnapshot<String, Map<String, Object?>>>>(
      stream: _locs,
      builder: (context, snap) {
        final locs = snap.data ?? const [];
        final targets = <Target>[
          for (final r in locs)
            if (r.value['mid'] != h.me.id && h.member('${r.value['mid']}') != null) // yang sudah keluar tidak ditampilkan
              Target(
                id: '${r.value['mid']}',
                name: h.member('${r.value['mid']}')?.name ?? 'Anggota',
                role: h.member('${r.value['mid']}')?.roleLabel ?? '',
                lat: (r.value['lat'] as num).toDouble(),
                lng: (r.value['lng'] as num).toDouble(),
                acc: (r.value['acc'] as num?)?.toDouble(),
                at: (r.value['at'] as num).toInt(),
              ),
        ];
        final f = me;
        if (f != null) {
          targets.sort((a, b) => haversine(f.lat, f.lng, a.lat, a.lng).compareTo(haversine(f.lat, f.lng, b.lat, b.lng)));
        }
        return ListView(padding: const EdgeInsets.only(bottom: 32), children: [
          if (LocationSvc.i.denied || f == null)
            InfoBanner(
              tone: Tone.warn,
              icon: LucideIcons.mapPin,
              text: LocationSvc.i.denied ? 'Izin lokasi ditolak. Radar butuh lokasi.' : 'Mencari lokasi GPS… pastikan Lokasi HP menyala.',
              action: LocationSvc.i.denied ? 'Buka Pengaturan' : 'Coba lagi',
              onAction: LocationSvc.i.denied ? () => openAppSettings() : _refreshFix,
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: AspectRatio(
              aspectRatio: 1,
              child: StreamBuilder<double?>(
                stream: headingStream(),
                builder: (context, hs) => CustomPaint(
                  painter: RadarPainter(me: f, targets: targets, heading: hs.data ?? 0, c: c, reduceMotion: MediaQuery.of(context).disableAnimations),
                  child: Semantics(label: 'Radar ${targets.length} anggota. Daftar di bawah urut jarak.'),
                ),
              ),
            ),
          ),
          SwitchListTile(
            title: const Text('Bagikan lokasi saya'),
            subtitle: const Text('Hanya ke tim konser ini, tiap 1 menit. Saat SOS tiap 10 detik.'),
            value: share,
            onChanged: (v) {
              setState(() => share = v);
              h.s.put('share_loc', v);
            },
          ),
          const SectionLabel('Urut jarak'),
          if (targets.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('Belum ada lokasi anggota. Lokasi tersebar tiap 1 menit lewat internet atau mesh.')),
          for (final t in targets)
            ListTile(
              minTileHeight: 64,
              leading: Avatar(name: t.name, size: 40),
              title: Text(t.name, style: Theme.of(context).textTheme.titleMedium),
              subtitle: Text(f == null
                  ? t.role
                  : '${fmtDistance(haversine(f.lat, f.lng, t.lat, t.lng))} · ${compassName(bearing(f.lat, f.lng, t.lat, t.lng))} · ${t.role}'),
              trailing: _age(context, t.at),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => CompassScreen(target: t))),
            ),
        ]);
      },
    );
  }

  Widget _age(BuildContext context, int at) {
    final c = CT.of(context);
    final old = DateTime.now().millisecondsSinceEpoch - at > 10 * 60000;
    return old ? StatusChip(label: 'lama', icon: LucideIcons.clock, fg: c.amber, bg: c.amberBg, dense: true) : Text(timeAgo(at), style: mono(12));
  }
}

class RadarPainter extends CustomPainter {
  RadarPainter({required this.me, required this.targets, required this.heading, required this.c, required this.reduceMotion});
  final Fix? me;
  final List<Target> targets;
  final double heading;
  final CT c;
  final bool reduceMotion;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = size.width / 2 - 4;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..color = c.ink
      ..strokeWidth = 2;
    canvas.drawCircle(center, r, Paint()..color = c.card);
    canvas.drawCircle(center, r, ring);
    const rings = [25.0, 50.0, 100.0, 200.0];
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (var i = 0; i < rings.length; i++) {
      final rr = r * (i + 1) / rings.length;
      canvas.drawCircle(center, rr, ring..strokeWidth = 1..color = c.ink.withValues(alpha: 0.35));
      tp.text = TextSpan(text: '${rings[i].toInt()} m', style: mono(10, color: c.muted));
      tp.layout();
      tp.paint(canvas, center + Offset(4, -rr + 2));
    }
    // penanda utara (berputar mengikuti kompas)
    final north = -heading * pi / 180;
    tp.text = TextSpan(text: 'U', style: mono(14, w: FontWeight.w700, color: c.danger));
    tp.layout();
    tp.paint(canvas, center + Offset(sin(north) * (r - 14), -cos(north) * (r - 14)) - Offset(tp.width / 2, tp.height / 2));
    // saya
    canvas.drawCircle(center, 9, Paint()..color = c.accent);
    canvas.drawCircle(center, 9, Paint()
      ..style = PaintingStyle.stroke
      ..color = c.ink
      ..strokeWidth = 2);
    final f = me;
    if (f == null) return;
    for (final t in targets) {
      final d = haversine(f.lat, f.lng, t.lat, t.lng);
      final b = (bearing(f.lat, f.lng, t.lat, t.lng) - heading) * pi / 180;
      // skala log supaya 0–25 m tidak menumpuk & 200+ m tetap di tepi
      final norm = d <= 0 ? 0.0 : (log(1 + d) / log(1 + 200)).clamp(0.0, 1.0);
      final p = center + Offset(sin(b), -cos(b)) * (r - 14) * norm;
      final fill = Paint()..color = t.sos ? c.danger : (DateTime.now().millisecondsSinceEpoch - t.at > 600000 ? c.cardLow : c.amberBg);
      canvas.drawCircle(p, 14, fill);
      canvas.drawCircle(p, 14, Paint()
        ..style = PaintingStyle.stroke
        ..color = c.ink
        ..strokeWidth = 2);
      final ini = t.name.trim().isEmpty ? '?' : t.name.trim().split(RegExp(r'\s+')).take(2).map((w) => w[0]).join().toUpperCase();
      tp.text = TextSpan(text: ini, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: t.sos ? Colors.white : const Color(0xFF0B0B0F)));
      tp.layout();
      tp.paint(canvas, p - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant RadarPainter old) => true;
}

/// S17 — Kompas ke anggota / pengirim SOS.
class CompassScreen extends StatefulWidget {
  const CompassScreen({super.key, required this.target});
  final Target target;
  @override
  State<CompassScreen> createState() => _CompassScreenState();
}

class _CompassScreenState extends State<CompassScreen> {
  Fix? me = LocationSvc.i.last;
  Timer? _t;
  bool buzzed = false;
  late Target target = widget.target;
  StreamSubscription? _locSub;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) WakelockPlus.enable();
    _tick();
    _t = Timer.periodic(const Duration(seconds: 5), (_) => _tick());
    // posisi target ikut diperbarui saat lokasi barunya masuk
    _locSub = Hub.i.s.locations.record('${Hub.i.slug}|${target.id}').onSnapshot(Hub.i.s.db).listen((s) {
      final v = s?.value;
      if (v == null || target.sos) return;
      setState(() => target = Target(
          id: target.id, name: target.name, role: target.role, lat: (v['lat'] as num).toDouble(), lng: (v['lng'] as num).toDouble(), acc: (v['acc'] as num?)?.toDouble(), at: (v['at'] as num).toInt()));
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    _locSub?.cancel();
    if (!kIsWeb) WakelockPlus.disable();
    super.dispose();
  }

  Future<void> _tick() async {
    final f = await LocationSvc.i.current();
    if (!mounted || f == null) return;
    setState(() => me = f);
    final d = haversine(f.lat, f.lng, target.lat, target.lng);
    if (d < 20 && !buzzed) {
      buzzed = true;
      HapticFeedback.heavyImpact();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = CT.of(context);
    final f = me;
    final dist = f == null ? null : haversine(f.lat, f.lng, target.lat, target.lng);
    final brg = f == null ? 0.0 : bearing(f.lat, f.lng, target.lat, target.lng);
    return Scaffold(
      backgroundColor: target.sos ? c.dangerBg : null,
      appBar: AppBar(title: Text('Menuju ${target.name}')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(children: [
            Expanded(
              child: StreamBuilder<double?>(
                stream: headingStream(),
                builder: (context, hs) {
                  final heading = hs.data;
                  final angle = ((brg - (heading ?? 0)) * pi / 180);
                  return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    if (heading == null) const InfoBanner(margin: EdgeInsets.only(bottom: 16), tone: Tone.warn, text: 'Kompas tidak tersedia. Panah menunjuk relatif ke utara.'),
                    Transform.rotate(
                      angle: angle,
                      child: Semantics(
                        label: f == null ? 'Menunggu GPS' : 'Arah ${compassName(brg)}',
                        child: Icon(LucideIcons.navigation, size: MediaQuery.of(context).size.width * 0.5, color: target.sos ? c.danger : c.accent),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(dist == null ? 'Menunggu GPS…' : fmtDistance(dist), style: mono(44, w: FontWeight.w700)),
                    const SizedBox(height: 6),
                    if (f != null) Text('${compassName(brg)} · ±${(target.acc ?? 0).round()} m', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text('Lokasi ${timeAgo(target.at)}', style: Theme.of(context).textTheme.bodyMedium),
                    if (heading != null) ...[
                      const SizedBox(height: 10),
                      Text('Kalau panah melenceng, gerakkan HP membentuk angka 8.', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ]);
                },
              ),
            ),
            OutlinedButton.icon(
              onPressed: Hub.i.netUp
                  ? () => launchUrl(Uri.parse('https://www.google.com/maps/search/?api=1&query=${target.lat},${target.lng}'), mode: LaunchMode.externalApplication)
                  : null,
              icon: const Icon(LucideIcons.mapPin),
              label: Text(Hub.i.netUp ? 'Buka di Google Maps' : 'Google Maps butuh internet'),
            ),
          ]),
        ),
      ),
    );
  }
}
