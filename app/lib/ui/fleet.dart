import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:sembast/sembast.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/theme.dart';
import '../data/models.dart';
import '../services/hub.dart';
import 'chat.dart';
import 'widgets.dart';

/// Status armada terbaru per "car|leg" dan check-in per "order|hari|leg".
class FleetData {
  FleetData(this.fleet, this.checkins);
  final Map<String, Map<String, Object?>> fleet;
  final Map<String, Map<String, Object?>> checkins;

  /// Status hari konser ini (hari konser mulai 06.00; status hari konser sebelumnya diabaikan).
  Map<String, Object?>? status(String car, String leg) {
    final v = fleet['$car|$leg'];
    return v != null && Hub.isCurrent(v['at'] as num?) ? v : null;
  }

  bool stale(String car, String leg) {
    final s = status(car, leg);
    if (s == null) return false;
    final st = s['st'];
    if (!(st == 'menuju' || st == 'di_titik' || st == 'berangkat')) return false;
    return DateTime.now().millisecondsSinceEpoch - ((s['at'] as num?)?.toInt() ?? 0) > 15 * 60000;
  }

  String? checkin(ManifestRow r, String leg) => checkins['${r.orderId}|${r.hari}|$leg']?['st'] as String?;
}

/// Status armada + check-in penumpang. Dua sumber didengarkan sekaligus, jadi tombol Naik / Tidak datang
/// langsung terlihat (dulu hanya perubahan status armada yang memicu tampilan diperbarui).
Stream<FleetData> watchFleet() {
  final h = Hub.i;
  late final StreamController<FleetData> ctl;
  List<RecordSnapshot<String, Map<String, Object?>>> fleet = const [], chk = const [];
  var gotFleet = false, gotChk = false;
  StreamSubscription? a, b;
  void emit() {
    if (!gotFleet || !gotChk || ctl.isClosed) return;
    ctl.add(FleetData(
      {for (final r in fleet) '${r.value['car']}|${r.value['leg']}': r.value},
      {for (final r in chk) '${r.value['order']}|${r.value['hari']}|${r.value['leg']}': r.value},
    ));
  }

  ctl = StreamController<FleetData>(
    onListen: () {
      a = h.watch(h.s.fleet).listen((v) {
        fleet = v;
        gotFleet = true;
        emit();
      });
      b = h.watch(h.s.checkins).listen((v) {
        chk = v;
        gotChk = true;
        emit();
      });
    },
    onCancel: () async {
      await a?.cancel();
      await b?.cancel();
    },
  );
  return ctl.stream;
}

/// Tab Armada: driver melihat kartu Mobil Saya di atas, lalu papan armada area; panitia/koordinator melihat semua.
class FleetScreen extends StatefulWidget {
  const FleetScreen({super.key});
  @override
  State<FleetScreen> createState() => _FleetScreenState();
}

class _FleetScreenState extends State<FleetScreen> {
  late final Stream<FleetData> _fleet = watchFleet();
  String? leg; // null = otomatis (pergi dulu, pulang setelah semua mobil tiba)
  bool forcePulang = false; // koordinator membuka leg Pulang walau ada mobil yang belum lapor Tiba
  String area = '';
  String filter = 'semua';

  @override
  Widget build(BuildContext context) {
    final h = Hub.i;
    final c = CT.of(context);
    final cars = h.concert!.carsMap;
    final me = h.me;
    if (me.isDriver && me.car.isNotEmpty) return MyCarScreen(car: me.car, embedded: true);
    return StreamBuilder<FleetData>(
      stream: _fleet,
      builder: (context, snap) {
        final d = snap.data ?? FleetData(const {}, const {});
        final allPergiDone = forcePulang || (cars.isNotEmpty && cars.keys.every((k) => Hub.legDone.contains(d.status(k, 'pergi')?['st'])));
        final leg = allPergiDone ? (this.leg ?? 'pulang') : 'pergi';
        var list = cars.entries.toList()..sort((a, b) => (int.tryParse(a.key) ?? 999).compareTo(int.tryParse(b.key) ?? 999));
        if (me.isDriver && me.area.isNotEmpty) list = list.where((e) => e.value.area == me.area).toList();
        if (area.isNotEmpty) list = list.where((e) => e.value.area == area).toList();
        int rank(MapEntry<String, Member> e) {
          final st = d.status(e.key, leg)?['st'];
          if (st == 'kendala') return 0;
          if (d.stale(e.key, leg)) return 1;
          return 2;
        }

        list.sort((a, b) => rank(a).compareTo(rank(b)));
        final total = list.length;
        final berangkat = list.where((e) => d.status(e.key, leg)?['st'] == 'berangkat').length;
        final tiba = list.where((e) => ['tiba', 'selesai'].contains(d.status(e.key, leg)?['st'])).length;
        final kendala = list.where((e) => d.status(e.key, leg)?['st'] == 'kendala').length;
        final stale = list.where((e) => d.stale(e.key, leg)).length;
        final shown = list.where((e) {
          final st = d.status(e.key, leg)?['st'];
          return switch (filter) {
            'kendala' => st == 'kendala',
            'kabar' => d.stale(e.key, leg),
            'jalan' => st == 'berangkat' || st == 'menuju' || st == 'di_titik',
            'tiba' => st == 'tiba' || st == 'selesai',
            _ => true,
          };
        }).toList();

        return ListView(padding: const EdgeInsets.only(bottom: 32), children: [
          if (me.isDriver && (me.car.isNotEmpty || me.cars.isNotEmpty))
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: PressBox(
                color: c.accentBg,
                semantics: 'Buka Mobil Saya',
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => MyCarScreen(car: me.car.isNotEmpty ? me.car : me.cars.first))),
                child: Row(children: [
                  const Icon(LucideIcons.carFront, size: 30),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Mobil Saya · ${me.carLabel}', style: Theme.of(context).textTheme.titleMedium),
                      Text('Lapor status & centang penumpang', style: Theme.of(context).textTheme.bodyMedium),
                    ]),
                  ),
                  StatusChip.fleet(context, d.status(me.car, leg)?['st'] as String?, dense: true),
                  const Icon(LucideIcons.chevronRight),
                ]),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SegmentedButton<String>(
                segments: [
                  const ButtonSegment(value: 'pergi', label: Text('Pergi'), icon: Icon(LucideIcons.arrowUp)),
                  ButtonSegment(value: 'pulang', label: const Text('Pulang'), icon: Icon(allPergiDone ? LucideIcons.refreshCw : LucideIcons.lock), enabled: allPergiDone),
                ],
                selected: {leg},
                onSelectionChanged: (s) => setState(() => this.leg = s.first),
              ),
              if (!allPergiDone)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(children: [
                    Expanded(child: Text('Pulang terbuka setelah semua mobil lapor Tiba.', style: TextStyle(fontSize: 12.5, color: c.muted))),
                    if (me.isKoord)
                      TextButton(
                        onPressed: () async {
                          if (await confirm(context,
                              title: 'Buka leg Pulang sekarang?', text: 'Masih ada mobil yang belum lapor Tiba. Papan pindah ke leg Pulang.', action: 'Buka Pulang')) {
                            setState(() {
                              forcePulang = true;
                              this.leg = 'pulang';
                            });
                          }
                        },
                        child: const Text('Buka sekarang'),
                      ),
                  ]),
                ),
            ]),
          ),
          SizedBox(
            height: 128,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.fromLTRB(16, 14, 16, 4), children: [
              StatCard(value: '$total', label: 'Total mobil', icon: LucideIcons.carFront),
              const SizedBox(width: 12),
              StatCard(value: '$berangkat', label: 'Berangkat', icon: LucideIcons.navigation, tone: c.accent),
              const SizedBox(width: 12),
              StatCard(value: '$tiba', label: 'Tiba', icon: LucideIcons.check, tone: c.ok),
              const SizedBox(width: 12),
              StatCard(value: '$kendala', label: 'Kendala', icon: LucideIcons.triangleAlert, tone: c.danger),
              const SizedBox(width: 12),
              StatCard(value: '$stale', label: 'Tidak ada kabar', icon: LucideIcons.clock, tone: c.amber),
            ]),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(children: [
              for (final f in const [('semua', 'Semua'), ('kendala', 'Kendala'), ('kabar', 'Tidak ada kabar'), ('jalan', 'Di jalan'), ('tiba', 'Tiba')])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(label: Text(f.$2), selected: filter == f.$1, onSelected: (_) => setState(() => filter = f.$1), selectedColor: c.accentBg),
                ),
              if (!me.isDriver)
                for (final a in h.concert!.areas)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(label: Text(a), selected: area == a, onSelected: (on) => setState(() => area = on ? a : ''), selectedColor: c.accentBg),
                  ),
            ]),
          ),
          if (cars.isEmpty)
            const EmptyState(icon: LucideIcons.carFront, title: 'Belum ada data mobil', text: 'Plotingan mobil belum dibuat di CarterTag Console, atau data belum terunduh.')
          else
            for (final e in shown) _CarCard(car: e.key, driver: e.value, leg: leg, d: d),
        ]);
      },
    );
  }
}

class _CarCard extends StatelessWidget {
  const _CarCard({required this.car, required this.driver, required this.leg, required this.d});
  final String car;
  final Member driver;
  final String leg;
  final FleetData d;

  @override
  Widget build(BuildContext context) {
    final c = CT.of(context);
    final s = d.status(car, leg);
    final rows = Hub.i.concert!.manifest.where((r) => r.car == car && r.hasLeg(leg)).toList();
    final pax = rows.fold<int>(0, (a, r) => a + r.pax);
    final naik = rows.where((r) => d.checkin(r, leg) == 'naik').fold<int>(0, (a, r) => a + r.pax);
    final peer = Hub.i.meshPeersList.where((p) => p.memberId == driver.id).firstOrNull;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: PressBox(
        semantics: '${carName(car)}, ${driver.name}',
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => MyCarScreen(car: car))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(carName(car), style: mono(24, w: FontWeight.w700)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(driver.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium),
                Text([if (driver.plat.isNotEmpty) driver.plat, if (driver.area.isNotEmpty) driver.area].join(' · '), style: mono(12, color: c.muted)),
              ]),
            ),
            StatusChip.fleet(context, s?['st'] as String?, stale: d.stale(car, leg)),
          ]),
          const SizedBox(height: 10),
          Wrap(spacing: 14, runSpacing: 6, children: [
            if (rows.isNotEmpty) _meta(context, LucideIcons.users, 'Naik $naik/$pax'),
            _meta(context, LucideIcons.clock, s == null ? 'Belum lapor' : timeAgo((s['at'] as num).toInt())),
            if (peer != null) _meta(context, LucideIcons.network, 'Dekat (mesh)'),
            if ('${s?['note'] ?? ''}'.isNotEmpty) _meta(context, LucideIcons.info, '${s!['note']}'),
          ]),
        ]),
      ),
    );
  }

  Widget _meta(BuildContext context, IconData i, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(i, size: 15),
        const SizedBox(width: 4),
        Text(t, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      ]);
}

/// S14 — Mobil Saya: status perjalanan + manifest + check-in.
class MyCarScreen extends StatefulWidget {
  const MyCarScreen({super.key, required this.car, this.embedded = false});
  final String car;

  /// true = tampil langsung di tab Armada (driver), tanpa app bar sendiri.
  final bool embedded;
  @override
  State<MyCarScreen> createState() => _MyCarScreenState();
}

class _MyCarScreenState extends State<MyCarScreen> {
  late final Stream<FleetData> _fleet = watchFleet();
  String? leg; // null = otomatis: pergi dulu, pulang setelah pergi Tiba/Selesai
  bool forcePulang = false; // koordinator membuka leg Pulang mobil ini
  String? day; // konser multi-hari: hari yang manifest-nya ditampilkan
  String? undoFrom;
  int undoUntil = 0;

  bool get canEdit => Hub.i.me.isKoord || Hub.i.me.cars.contains(widget.car) || Hub.i.me.car == widget.car;

  /// Leg yang sedang dilihat: pulang hanya kalau pergi mobil ini sudah Tiba/Selesai.
  String _leg() => Hub.i.pergiDone(widget.car) || forcePulang ? (leg ?? 'pulang') : 'pergi';

  Future<void> _set(String status, {String note = ''}) async {
    final leg = _leg();
    final prev = (await Hub.i.s.fleet.record('${Hub.i.slug}|${widget.car}|$leg').get(Hub.i.s.db))?['st'] as String?;
    await Hub.i.sendFleet(widget.car, leg, status, note: note);
    setState(() {
      undoFrom = prev ?? 'siap';
      undoUntil = DateTime.now().add(const Duration(minutes: 2)).millisecondsSinceEpoch;
    });
    if (!mounted) return;
    toast(context, 'Status: ${fleetLabels[status]}', action: 'Urungkan', onAction: _undo);
  }

  Future<void> _undo() async {
    if (undoFrom == null || DateTime.now().millisecondsSinceEpoch > undoUntil) return;
    final to = undoFrom!;
    undoFrom = null;
    await Hub.i.sendFleet(widget.car, _leg(), to, note: 'koreksi');
    if (mounted) setState(() {});
  }

  Future<void> _kendala() async {
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Lapor kendala'),
        content: TextField(controller: note, autofocus: true, maxLength: 120, decoration: const InputDecoration(labelText: 'Kendala apa?', helperText: 'mis. Ban bocor di tol, butuh 20 menit')),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: CT.of(ctx).danger, foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Kirim kendala')),
        ],
      ),
    );
    if (ok == true) await _set('kendala', note: note.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final h = Hub.i;
    final c = CT.of(context);
    final driver = h.concert!.carsMap[widget.car];
    final manifestOn = h.concert!.manifestEnabled;
    final body = StreamBuilder<FleetData>(
        stream: _fleet,
        builder: (context, snap) {
          final d = snap.data ?? FleetData(const {}, const {});
          final pulangOpen = forcePulang || Hub.legDone.contains(d.status(widget.car, 'pergi')?['st']);
          final days = {for (final r in h.concert!.manifest.where((r) => r.car == widget.car)) r.hari}.where((x) => x.isNotEmpty).toList()..sort();
          final today = Hub.concertDay(); // lewat tengah malam (sebelum 06.00) tetap hari konser kemarin
          final dayNow = day ?? (days.contains(today) ? today : (days.isEmpty ? '' : days.first));
          final leg = pulangOpen ? (this.leg ?? 'pulang') : 'pergi';
          final s = d.status(widget.car, leg);
          final st = s?['st'] as String?;
          final idx = st == null ? -1 : fleetSteps.indexOf(st);
          final next = st == 'kendala' ? (s?['prev'] as String? ?? 'siap') : (idx + 1 < fleetSteps.length ? fleetSteps[idx + 1] : null);
          final rows = h.concert!.manifest
              .where((r) => r.car == widget.car && r.hasLeg(leg) && (days.length < 2 || r.hari.isEmpty || r.hari == dayNow))
              .toList()
            ..sort((a, b) => a.jam.compareTo(b.jam));
          final pax = rows.fold<int>(0, (a, r) => a + r.pax);
          final naik = rows.where((r) => d.checkin(r, leg) == 'naik').fold<int>(0, (a, r) => a + r.pax);
          return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 40), children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: brutalBox(context, color: c.accentBg),
              child: Row(children: [
                Text(carName(widget.car), style: mono(32, w: FontWeight.w700)),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(driver?.name ?? '-', style: Theme.of(context).textTheme.titleMedium),
                    if ((driver?.plat ?? '').isNotEmpty) Text(driver!.plat, style: mono(14, w: FontWeight.w600)),
                    if ((driver?.area ?? '').isNotEmpty) Text('Area ${driver!.area}'),
                  ]),
                ),
                if (driver != null && driver.id != h.me.id)
                  IconButton(
                    tooltip: 'Chat driver',
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatRoomScreen(channel: dmChannelOf(h.me.id, driver.id)))),
                    icon: const Icon(LucideIcons.messageCircle),
                  ),
              ]),
            ),
            const SizedBox(height: 14),
            SegmentedButton<String>(
              segments: [
                const ButtonSegment(value: 'pergi', label: Text('Pergi'), icon: Icon(LucideIcons.arrowUp)),
                ButtonSegment(value: 'pulang', label: const Text('Pulang'), icon: Icon(pulangOpen ? LucideIcons.refreshCw : LucideIcons.lock), enabled: pulangOpen),
              ],
              selected: {leg},
              onSelectionChanged: (v) => setState(() => this.leg = v.first),
            ),
            if (!pulangOpen)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(children: [
                  Expanded(child: Text('Pulang terbuka setelah perjalanan pergi ditandai Tiba.', style: TextStyle(fontSize: 12.5, color: c.muted))),
                  if (h.me.isKoord)
                    TextButton(onPressed: () => setState(() => forcePulang = true), child: const Text('Buka sekarang')),
                ]),
              ),
            if (days.length > 1) ...[
              const SizedBox(height: 12),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  for (var i = 0; i < days.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text('Hari ${i + 1} · ${_shortDate(days[i])}'),
                        selected: dayNow == days[i],
                        onSelected: (_) => setState(() => day = days[i]),
                      ),
                    ),
                ]),
              ),
            ],
            const SizedBox(height: 18),
            _Stepper(current: st),
            if (st == 'kendala') ...[
              const SizedBox(height: 12),
              InfoBanner(margin: EdgeInsets.zero, tone: Tone.danger, text: 'Kendala: ${s?['note'] ?? '-'}'),
            ],
            if (canEdit) ...[
              const SizedBox(height: 18),
              if (next != null)
                SizedBox(
                  height: 56,
                  child: FilledButton(onPressed: () => _set(next), child: Text(st == 'kendala' ? 'Kendala selesai: lanjut ${fleetLabels[next]}' : 'Tandai: ${fleetLabels[next]}')),
                ),
              const SizedBox(height: 10),
              if (st != 'kendala')
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: c.danger),
                  onPressed: _kendala,
                  icon: const Icon(LucideIcons.triangleAlert),
                  label: const Text('Lapor kendala'),
                ),
              if (undoFrom != null && DateTime.now().millisecondsSinceEpoch < undoUntil)
                TextButton(onPressed: _undo, child: Text('Urungkan (kembali ke ${fleetLabels[undoFrom]})')),
            ],
            const SizedBox(height: 8),
            Text(s == null ? 'Belum ada laporan untuk leg ini.' : 'Terakhir: ${fleetLabels[st]} · ${timeAgo((s['at'] as num).toInt())}', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 24),
            if (!manifestOn)
              const InfoBanner(margin: EdgeInsets.zero, tone: Tone.info, text: 'Manifest penumpang tidak diaktifkan untuk konser ini.')
            else ...[
              Row(children: [
                Expanded(child: Text('Penumpang $naik/$pax naik', style: Theme.of(context).textTheme.titleLarge)),
              ]),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(value: pax == 0 ? 0 : naik / pax, minHeight: 10, color: c.ok, backgroundColor: c.cardLow),
              ),
              const SizedBox(height: 12),
              if (rows.isEmpty) const Text('Belum ada penumpang di mobil ini untuk leg ini.'),
              for (final r in rows) _PaxRow(r: r, leg: leg, st: d.checkin(r, leg), canEdit: canEdit),
              const SizedBox(height: 10),
              Text('Sumber: ${h.concert!.manifestSource == 'upload' ? 'Upload tim' : 'Plotingan'} · diperbarui ${h.concert!.manifestUpdated}',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ]);
        },
      );
    if (widget.embedded) return body;
    return Scaffold(appBar: AppBar(title: Text('Mobil ${carName(widget.car)}')), body: body);
  }
}

/// "2026-09-27" -> "27 Sep"
String _shortDate(String iso) {
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun', 'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des'];
  final d = DateTime.tryParse(iso);
  return d == null ? iso : '${d.day} ${m[d.month - 1]}';
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.current});
  final String? current;
  @override
  Widget build(BuildContext context) {
    final c = CT.of(context);
    final idx = current == null ? -1 : fleetSteps.indexOf(current!);
    return Row(children: [
      for (var i = 0; i < fleetSteps.length; i++) ...[
        Expanded(
          child: Semantics(
            label: '${fleetLabels[fleetSteps[i]]}${i == idx ? ', sekarang' : (i < idx ? ', selesai' : '')}',
            child: Column(children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: i <= idx ? c.accent : c.card,
                  shape: BoxShape.circle,
                  border: Border.all(color: i <= idx ? c.accent : c.line, width: 1.5),
                ),
                child: i < idx
                    ? Icon(LucideIcons.check, size: 16, color: c.onAccent)
                    : Text('${i + 1}', style: mono(13, w: FontWeight.w700, color: i <= idx ? c.onAccent : c.ink)),
              ),
              const SizedBox(height: 4),
              Text(fleetShort[fleetSteps[i]]!, textAlign: TextAlign.center, maxLines: 2, style: TextStyle(fontSize: 11, fontWeight: i == idx ? FontWeight.w700 : FontWeight.w500)),
            ]),
          ),
        ),
      ],
    ]);
  }
}

class _PaxRow extends StatelessWidget {
  const _PaxRow({required this.r, required this.leg, required this.st, required this.canEdit});
  final ManifestRow r;
  final String leg;
  final String? st;
  final bool canEdit;

  @override
  Widget build(BuildContext context) {
    final c = CT.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: brutalBox(context, shadow: false, color: st == 'naik' ? c.okBg : (st == 'tidak_datang' ? c.cardLow : c.card)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PassengerScreen(r: r))),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(r.name, style: Theme.of(context).textTheme.titleMedium),
                Text('${r.pax} orang · ${r.titik.isEmpty ? r.area : r.titik}', maxLines: 2, overflow: TextOverflow.ellipsis),
              ]),
            ),
            if (r.jam.isNotEmpty) Text(r.jam, style: mono(15, w: FontWeight.w700)),
            const Icon(LucideIcons.chevronRight),
          ]),
        ),
        if (canEdit) ...[
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: _seg(context, 'Naik', LucideIcons.check, st == 'naik', c.ok, () => Hub.i.sendCheckin(r, leg, 'naik')),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _seg(context, 'Tidak datang', LucideIcons.x, st == 'tidak_datang', c.muted, () => Hub.i.sendCheckin(r, leg, 'tidak_datang')),
            ),
          ]),
        ],
      ]),
    );
  }

  Widget _seg(BuildContext context, String label, IconData icon, bool on, Color tone, VoidCallback onTap) {
    final c = CT.of(context);
    return Semantics(
      selected: on,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: on ? tone : c.cardLow, borderRadius: BorderRadius.circular(999)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 18, color: on ? Colors.white : c.ink),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontWeight: FontWeight.w700, color: on ? Colors.white : c.ink)),
          ]),
        ),
      ),
    );
  }
}

/// S15 — Detail penumpang.
class PassengerScreen extends StatelessWidget {
  const PassengerScreen({super.key, required this.r});
  final ManifestRow r;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final canContact = r.wa.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Penumpang')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(r.name, style: t.displaySmall),
        const SizedBox(height: 4),
        Text('#${r.orderId}', style: mono(15, w: FontWeight.w600)),
        const SizedBox(height: 18),
        _row(context, LucideIcons.users, 'Jumlah', '${r.pax} orang'),
        _row(context, LucideIcons.bus, 'Trip', r.trip.isEmpty ? '-' : r.trip),
        _row(context, LucideIcons.mapPin, 'Area', r.area.isEmpty ? '-' : r.area),
        _row(context, LucideIcons.mapPinned, 'Titik kumpul', r.titik.isEmpty ? '-' : r.titik),
        _row(context, LucideIcons.clock, 'Jam jemput', r.jam.isEmpty ? '-' : r.jam),
        _row(context, LucideIcons.carFront, 'Mobil', carName(r.car)),
        if (r.catatan.isNotEmpty) _row(context, LucideIcons.info, 'Catatan', r.catatan),
        const SizedBox(height: 20),
        if (canContact) ...[
          FilledButton.icon(onPressed: () => launchUrl(Uri.parse('tel:+${r.wa}')), icon: const Icon(LucideIcons.phone), label: const Text('Telepon')),
          const SizedBox(height: 10),
          OutlinedButton.icon(
              onPressed: () => launchUrl(Uri.parse('https://wa.me/${r.wa}'), mode: LaunchMode.externalApplication),
              icon: const Icon(LucideIcons.messageCircle),
              label: const Text('WhatsApp')),
          const SizedBox(height: 8),
          Text('Telepon & WhatsApp butuh sinyal seluler.', style: t.bodySmall),
        ],
      ]),
    );
  }

  Widget _row(BuildContext context, IconData i, String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(i, size: 20),
          const SizedBox(width: 12),
          SizedBox(width: 110, child: Text(k, style: const TextStyle(fontWeight: FontWeight.w700))),
          Expanded(child: Text(v, style: const TextStyle(fontSize: 16))),
        ]),
      );
}
