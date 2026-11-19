import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:sembast/sembast.dart';

import '../core/theme.dart';
import '../services/hub.dart';
import '../services/location.dart';
import '../services/notifier.dart';
import 'radar.dart';
import 'widgets.dart';

/// K02 — Tombol SOS di top bar: tap = petunjuk, tahan 2 detik = kirim.
class SosButton extends StatefulWidget {
  const SosButton({super.key});
  @override
  State<SosButton> createState() => _SosButtonState();
}

class _SosButtonState extends State<SosButton> with SingleTickerProviderStateMixin {
  late final AnimationController _hold = AnimationController(vsync: this, duration: const Duration(seconds: 2));

  @override
  void initState() {
    super.initState();
    _hold.addStatusListener((s) {
      if (s == AnimationStatus.completed) _fire();
    });
  }

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  Future<void> _fire() async {
    HapticFeedback.heavyImpact();
    _hold.reset();
    final kind = await Navigator.of(context).push<String>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const SosKindScreen()));
    if (kind == null) return;
    await Hub.i.startSos(kind);
    if (mounted) toast(context, 'SOS terkirim ke semua anggota. Dikirim ulang tiap 30 detik.');
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'SOS. Tahan 2 detik untuk mengirim',
      child: GestureDetector(
        onTap: () => toast(context, 'Tahan tombol SOS 2 detik untuk kirim'),
        onLongPressStart: (_) {
          HapticFeedback.selectionClick();
          _hold.forward(from: 0);
        },
        onLongPressEnd: (_) {
          if (_hold.status != AnimationStatus.completed) _hold.reset();
        },
        child: AnimatedBuilder(
          animation: _hold,
          builder: (context, _) => Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              gradient: _hold.value == 0
                  ? null
                  : LinearGradient(colors: const [CT.sosRed, CT.sosRed, Color(0xFFE57373), Color(0xFFE57373)], stops: [0, _hold.value, _hold.value, 1]),
              color: CT.sosRed,
            ),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(LucideIcons.siren, size: 16, color: Colors.white),
              SizedBox(width: 5),
              Text('SOS', style: TextStyle(fontWeight: FontWeight.w700, color: Colors.white, fontSize: 13.5)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// S21 — Pilih jenis SOS; otomatis kirim "Lainnya" setelah 5 detik.
class SosKindScreen extends StatefulWidget {
  const SosKindScreen({super.key});
  @override
  State<SosKindScreen> createState() => _SosKindScreenState();
}

class _SosKindScreenState extends State<SosKindScreen> {
  int left = 5;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (t) {
      setState(() => left--);
      if (left <= 0) {
        t.cancel();
        Navigator.pop(context, 'lainnya');
      }
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const kinds = [
      ('medis', 'Medis', LucideIcons.heartPulse),
      ('kendaraan', 'Kendaraan', LucideIcons.carFront),
      ('keamanan', 'Keamanan', LucideIcons.shieldAlert),
      ('lainnya', 'Lainnya', LucideIcons.circleAlert),
    ];
    return Scaffold(
      backgroundColor: CT.sosRed,
      appBar: AppBar(
        backgroundColor: CT.sosRed,
        foregroundColor: Colors.white,
        title: const Text('Kirim SOS', style: TextStyle(color: Colors.white)),
        leading: IconButton(tooltip: 'Batal', onPressed: () => Navigator.pop(context), icon: const Icon(LucideIcons.x, color: Colors.white)),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Jenis darurat?', style: Theme.of(context).textTheme.displaySmall?.copyWith(color: Colors.white)),
            const SizedBox(height: 6),
            Semantics(
              liveRegion: true,
              child: Text('Terkirim otomatis sebagai "Lainnya" dalam $left detik', style: const TextStyle(color: Colors.white, fontSize: 16)),
            ),
            const SizedBox(height: 24),
            for (final k in kinds)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: SizedBox(
                  height: 64,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: CT.sosRed, textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                    onPressed: () => Navigator.pop(context, k.$1),
                    icon: Icon(k.$3),
                    label: Text(k.$2),
                  ),
                ),
              ),
            const Spacer(),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal, tidak jadi', style: TextStyle(color: Colors.white, fontSize: 16))),
          ]),
        ),
      ),
    );
  }
}

/// S22 — SOS masuk (layar penuh merah).
class IncomingSosScreen extends StatelessWidget {
  const IncomingSosScreen({super.key, required this.sosId});
  final String sosId;

  @override
  Widget build(BuildContext context) {
    final h = Hub.i;
    return StreamBuilder<Map<String, Object?>?>(
      stream: h.s.sos.record(sosId).onSnapshot(h.s.db).map((s) => s?.value),
      builder: (context, snap) {
        final v = snap.data;
        final active = v?['active'] == true;
        final f = LocationSvc.i.last;
        final hasLoc = v?['lat'] != null;
        final dist = (f != null && hasLoc) ? haversine(f.lat, f.lng, (v!['lat'] as num).toDouble(), (v['lng'] as num).toDouble()) : null;
        final brg = (f != null && hasLoc) ? bearing(f.lat, f.lng, (v!['lat'] as num).toDouble(), (v['lng'] as num).toDouble()) : null;
        final responders = ((v?['responders'] as Map?) ?? {});
        final iResponded = responders.containsKey(h.me.id);
        final sender = h.member('${v?['from']}');
        return Scaffold(
          backgroundColor: CT.sosRed,
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: v == null
                  ? const Center(child: CircularProgressIndicator(color: Colors.white))
                  : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Row(children: [
                        const Icon(LucideIcons.siren, color: Colors.white, size: 36),
                        const Spacer(),
                        IconButton(
                          tooltip: 'Tutup',
                          onPressed: () {
                            Notifier.i.cancelSos();
                            Navigator.pop(context);
                          },
                          icon: const Icon(LucideIcons.x, color: Colors.white, size: 28),
                        ),
                      ]),
                      const SizedBox(height: 12),
                      Semantics(
                        liveRegion: true,
                        child: Text(active ? 'SOS · ${Hub.sosKindLabel(v['kind'])}' : 'SOS SELESAI',
                            style: const TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w800, fontFamily: kSans)),
                      ),
                      const SizedBox(height: 8),
                      Text('${v['fn'] ?? sender?.name ?? 'Anggota'} · ${sender?.roleLabel ?? ''}', style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 18),
                      if (dist != null)
                        Text('${fmtDistance(dist)} · ${compassName(brg!)}', style: mono(32, w: FontWeight.w700, color: Colors.white))
                      else
                        Text(hasLoc ? 'Menunggu GPS kamu…' : 'Lokasi pengirim belum ada', style: const TextStyle(color: Colors.white, fontSize: 18)),
                      const SizedBox(height: 8),
                      Text(
                        [
                          if (v['bat'] != null) 'Baterai ${v['bat']}%',
                          'Dikirim ${hhmm((v['at'] as num?)?.toInt() ?? 0)}',
                          if (responders.isNotEmpty) '${responders.length} orang menuju',
                        ].join(' · '),
                        style: const TextStyle(color: Colors.white, fontSize: 15),
                      ),
                      const Spacer(),
                      if (active) ...[
                        SizedBox(
                          height: 60,
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: CT.sosRed, textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                            onPressed: iResponded ? null : () => h.respondSos(sosId),
                            icon: const Icon(LucideIcons.navigation),
                            label: Text(iResponded ? 'Kamu sedang menuju' : 'Saya menuju'),
                          ),
                        ),
                        const SizedBox(height: 12),
                        if (hasLoc)
                          SizedBox(
                            height: 52,
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(foregroundColor: Colors.white, backgroundColor: Colors.transparent, side: const BorderSide(color: Colors.white, width: 2.5)),
                              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                                  builder: (_) => CompassScreen(
                                      target: Target(
                                          id: '${v['from']}',
                                          name: '${v['fn'] ?? 'SOS'}',
                                          role: 'SOS',
                                          lat: (v['lat'] as num).toDouble(),
                                          lng: (v['lng'] as num).toDouble(),
                                          acc: (v['acc'] as num?)?.toDouble(),
                                          at: (v['upd'] as num?)?.toInt() ?? (v['at'] as num).toInt(),
                                          sos: true)))),
                              icon: const Icon(LucideIcons.compass),
                              label: const Text('Lihat kompas'),
                            ),
                          ),
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: () => Notifier.i.cancelSos(),
                          child: const Text('Matikan alarm (SOS tetap tercatat)', style: TextStyle(color: Colors.white, fontSize: 15)),
                        ),
                        if (h.me.isKoord)
                          TextButton(
                            onPressed: () async {
                              if (await confirm(context, title: 'Batalkan SOS ini?', text: 'Alarm di semua HP berhenti.', action: 'Batalkan SOS', danger: true)) {
                                await h.cancelSos(sosId);
                              }
                            },
                            child: const Text('Batalkan SOS (koordinator)', style: TextStyle(color: Colors.white, fontSize: 15, decoration: TextDecoration.underline, decorationColor: Colors.white)),
                          ),
                      ] else
                        SizedBox(
                          height: 56,
                          child: FilledButton(
                            style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: CT.sosRed),
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Tutup'),
                          ),
                        ),
                    ]),
            ),
          ),
        );
      },
    );
  }
}

/// S23 — Banner SOS aktif milik saya (di atas semua layar).
class ActiveSosBanner extends StatelessWidget {
  const ActiveSosBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final h = Hub.i;
    final id = h.mySosId!;
    return StreamBuilder<Map<String, Object?>?>(
      stream: h.s.sos.record(id).onSnapshot(h.s.db).map((s) => s?.value),
      builder: (context, snap) {
        final responders = ((snap.data?['responders'] as Map?) ?? {}).values.cast<Map>().toList();
        return Container(
          width: double.infinity,
          color: CT.sosRed,
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          child: Row(children: [
            const Icon(LucideIcons.siren, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('SOS aktif · dikirim ulang tiap 30 dtk', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                Text(
                  responders.isEmpty ? 'Menunggu respons tim…' : responders.map((r) => '${r['fn']}${r['dist'] != null ? ' ${r['dist']} m' : ''}').join(', ') + ' menuju',
                  style: const TextStyle(color: Colors.white),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ]),
            ),
            TextButton(
              onPressed: () async {
                if (await confirm(context, title: 'Batalkan SOS?', text: 'Alarm di semua HP akan berhenti.', action: 'Batalkan SOS', danger: true)) {
                  await h.cancelSos(id);
                }
              },
              child: const Text('Batalkan', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, decoration: TextDecoration.underline, decorationColor: Colors.white)),
            ),
          ]),
        );
      },
    );
  }
}

/// Daftar SOS aktif (dibuka dari notifikasi SOS offline).
class SosListScreen extends StatelessWidget {
  const SosListScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final h = Hub.i;
    return Scaffold(
      appBar: AppBar(title: const Text('SOS')),
      body: StreamBuilder<List<RecordSnapshot<String, Map<String, Object?>>>>(
        stream: h.watch(h.s.sos),
        builder: (context, snap) {
          // SOS dari anggota yang sudah keluar (pembatalannya bisa tidak sampai kalau dia keluar saat offline) tidak ditampilkan
          final list = (snap.data ?? const [])
              .where((r) => r.value['active'] == true && (r.value['from'] == h.me.id || h.member('${r.value['from']}') != null))
              .toList();
          if (list.isEmpty) return const EmptyState(icon: LucideIcons.check, title: 'Tidak ada SOS aktif', text: 'Semua aman.');
          return ListView(children: [
            for (final r in list)
              ListTile(
                minTileHeight: 64,
                leading: const Icon(LucideIcons.siren, color: CT.sosRed),
                title: Text('${r.value['fn']} · ${Hub.sosKindLabel(r.value['kind'])}'),
                subtitle: Text('Dikirim ${hhmm((r.value['at'] as num).toInt())}'),
                onTap: () => Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => IncomingSosScreen(sosId: r.key))),
              ),
          ]);
        },
      ),
    );
  }
}
