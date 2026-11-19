import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:sembast/sembast.dart';

import '../core/theme.dart';
import '../services/hub.dart';
import 'chat.dart';
import 'radar.dart';
import 'widgets.dart';

typedef _Snap = RecordSnapshot<String, Map<String, Object?>>;

/// S18 — Info: absen aktif + pengumuman pinned.
class InfoScreen extends StatelessWidget {
  const InfoScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final h = Hub.i;
    final koord = h.me.isKoord;
    return Scaffold(
      floatingActionButton: koord
          ? FloatingActionButton.extended(
              heroTag: 'ann',
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NewAnnouncementScreen())),
              icon: const Icon(LucideIcons.megaphone),
              label: const Text('Pengumuman'),
            )
          : null,
      body: ListView(padding: const EdgeInsets.only(bottom: 100), children: [
        StreamBuilder<List<_Snap>>(
          stream: h.watch(h.s.rollcalls),
          builder: (context, snap) {
            final list = (snap.data ?? const []).where((r) => r.value['closed'] == null).toList();
            return Column(children: [
              for (final r in list) _RollcallCard(id: r.key, v: r.value),
              if (koord)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final ok = await confirm(context, title: 'Mulai absen?', text: 'Semua anggota diminta menandai kondisi: Aman atau Butuh bantuan.', action: 'Mulai absen');
                      if (!ok) return;
                      final id = await h.startRollcall();
                      if (context.mounted) Navigator.of(context).push(MaterialPageRoute(builder: (_) => RollcallScreen(id: id)));
                    },
                    icon: const Icon(LucideIcons.clipboardCheck),
                    label: const Text('Mulai absen'),
                  ),
                ),
              if (koord)
                for (final r in (snap.data ?? const []).where((r) => r.value['closed'] != null).take(3))
                  ListTile(
                    leading: const Icon(LucideIcons.clipboardCheck),
                    title: Text('Absen ${hhmm((r.value['at'] as num?)?.toInt() ?? 0)} (selesai)'),
                    trailing: const Icon(LucideIcons.chevronRight),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => RollcallScreen(id: r.key))),
                  ),
            ]);
          },
        ),
        const SectionLabel('Pengumuman'),
        StreamBuilder<List<_Snap>>(
          stream: h.watch(h.s.anns),
          builder: (context, snap) {
            final list = snap.data ?? const [];
            if (list.isEmpty) {
              return const EmptyState(icon: LucideIcons.megaphone, title: 'Belum ada pengumuman', text: 'Pengumuman dari koordinator muncul di sini dan tetap tersimpan walau offline.');
            }
            return Column(children: [for (final a in list) _AnnCard(v: a.value, koord: koord)]);
          },
        ),
      ]),
    );
  }
}

class _AnnCard extends StatelessWidget {
  const _AnnCard({required this.v, required this.koord});
  final Map<String, Object?> v;
  final bool koord;

  @override
  Widget build(BuildContext context) {
    final c = CT.of(context);
    final important = (v['prio'] as num? ?? 0) > 0;
    final active = {for (final m in Hub.i.roster) if (m.id != Hub.i.me.id) m.id};
    final dlv = ((v['dlv'] as Map?)?.keys ?? const []).where((k) => active.contains('$k')).length;
    final total = active.length;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      decoration: brutalBox(context, color: important ? c.amberBg : c.card),
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (important) Container(width: 8, decoration: BoxDecoration(color: c.amber, borderRadius: const BorderRadius.horizontal(left: Radius.circular(9)))),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(important ? LucideIcons.pin : LucideIcons.megaphone, size: 18),
                  const SizedBox(width: 6),
                  if (important) const Text('PENTING  ', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                  Expanded(child: Text('${v['byName'] ?? ''} · ${hhmm((v['at'] as num?)?.toInt() ?? 0)}', style: mono(12))),
                ]),
                const SizedBox(height: 8),
                Text('${v['title']}', style: Theme.of(context).textTheme.titleLarge),
                if ('${v['body'] ?? ''}'.isNotEmpty) ...[const SizedBox(height: 6), Text('${v['body']}', style: Theme.of(context).textTheme.bodyLarge)],
                if (koord && v['by'] == Hub.i.me.id) ...[
                  const SizedBox(height: 8),
                  Text('Diterima $dlv/$total lewat mesh', style: mono(12, w: FontWeight.w600)),
                ],
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

class _RollcallCard extends StatelessWidget {
  const _RollcallCard({required this.id, required this.v});
  final String id;
  final Map<String, Object?> v;

  @override
  Widget build(BuildContext context) {
    final c = CT.of(context);
    final h = Hub.i;
    final answers = (v['answers'] as Map?) ?? {};
    final mine = (answers[h.me.id] as Map?)?['ans'];
    final by = h.member('${v['by']}')?.name ?? 'Koordinator';
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.all(14),
      decoration: brutalBox(context, color: c.amberBg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(LucideIcons.clipboardCheck),
          const SizedBox(width: 8),
          Expanded(child: Text('Absen dari $by', style: Theme.of(context).textTheme.titleMedium)),
          if (h.me.isKoord)
            TextButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => RollcallScreen(id: id))), child: const Text('Rekap')),
        ]),
        const SizedBox(height: 4),
        Text(mine == null ? 'Tandai kondisimu sekarang.' : 'Jawabanmu: ${mine == 'aman' ? 'Aman' : 'Butuh bantuan'}. Bisa diubah.'),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: SizedBox(
              height: 52,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: mine == 'aman' ? c.ok : c.card, foregroundColor: mine == 'aman' ? Colors.white : c.ink),
                onPressed: () => h.answerRollcall(id, 'aman'),
                icon: const Icon(LucideIcons.check),
                label: const Text('Aman'),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SizedBox(
              height: 52,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: mine == 'bantuan' ? c.danger : c.card, foregroundColor: mine == 'bantuan' ? Colors.white : c.danger),
                onPressed: () => h.answerRollcall(id, 'bantuan'),
                icon: const Icon(LucideIcons.circleAlert),
                label: const Text('Butuh bantuan'),
              ),
            ),
          ),
        ]),
      ]),
    );
  }
}

/// S20 — Rekap absen (koordinator).
class RollcallScreen extends StatelessWidget {
  const RollcallScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context) {
    final h = Hub.i;
    final c = CT.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Rekap absen')),
      body: StreamBuilder<Map<String, Object?>?>(
        stream: h.s.rollcalls.record(id).onSnapshot(h.s.db).map((s) => s?.value),
        builder: (context, snap) {
          final v = snap.data;
          if (v == null) return const Center(child: CircularProgressIndicator());
          final answers = ((v['answers'] as Map?) ?? {}).cast<String, Object?>();
          final members = h.roster.where((m) => m.id != h.me.id).toList();
          final aman = members.where((m) => (answers[m.id] as Map?)?['ans'] == 'aman').toList();
          final bantuan = members.where((m) => (answers[m.id] as Map?)?['ans'] == 'bantuan').toList();
          final belum = members.where((m) => answers[m.id] == null).toList();
          final closed = v['closed'] != null;
          return ListView(padding: const EdgeInsets.only(bottom: 32), children: [
            SizedBox(
              height: 128,
              child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.fromLTRB(16, 16, 16, 4), children: [
                StatCard(value: '${aman.length}', label: 'Aman', icon: LucideIcons.check, tone: c.ok),
                const SizedBox(width: 12),
                StatCard(value: '${bantuan.length}', label: 'Butuh bantuan', icon: LucideIcons.circleAlert, tone: c.danger),
                const SizedBox(width: 12),
                StatCard(value: '${belum.length}', label: 'Belum jawab', icon: LucideIcons.hourglass, tone: c.amber),
              ]),
            ),
            if (bantuan.isNotEmpty) ...[
              const SectionLabel('Butuh bantuan'),
              for (final m in bantuan)
                ListTile(
                  leading: Avatar(name: m.name, size: 40),
                  title: Text(m.name),
                  subtitle: Text(m.roleLabel),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                        tooltip: 'Chat',
                        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatRoomScreen(channel: dmChannelOf(h.me.id, m.id)))),
                        icon: const Icon(LucideIcons.messageCircle)),
                    IconButton(tooltip: 'Kompas', onPressed: () => _compass(context, m.id), icon: const Icon(LucideIcons.compass)),
                  ]),
                ),
            ],
            SectionLabel('Belum jawab (${belum.length})'),
            for (final m in belum) ListTile(leading: Avatar(name: m.name, size: 40), title: Text(m.name), subtitle: Text(m.roleLabel)),
            SectionLabel('Aman (${aman.length})'),
            for (final m in aman) ListTile(leading: Avatar(name: m.name, size: 40), title: Text(m.name), subtitle: Text(m.roleLabel)),
            if (!closed && h.me.isKoord)
              Padding(
                padding: const EdgeInsets.all(16),
                child: OutlinedButton(
                  onPressed: () async {
                    if (await confirm(context, title: 'Tutup absen?', text: 'Anggota tidak bisa menjawab lagi.', action: 'Tutup absen')) {
                      await h.closeRollcall(id);
                    }
                  },
                  child: const Text('Tutup absen'),
                ),
              ),
          ]);
        },
      ),
    );
  }

  Future<void> _compass(BuildContext context, String mid) async {
    final l = await Hub.i.s.locations.record('${Hub.i.slug}|$mid').get(Hub.i.s.db);
    if (!context.mounted) return;
    if (l == null) {
      toast(context, 'Lokasi anggota ini belum ada.');
      return;
    }
    final m = Hub.i.member(mid);
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => CompassScreen(
            target: Target(id: mid, name: m?.name ?? 'Anggota', role: m?.roleLabel ?? '', lat: (l['lat'] as num).toDouble(), lng: (l['lng'] as num).toDouble(), at: (l['at'] as num).toInt()))));
  }
}

/// S19 — Buat pengumuman (koordinator).
class NewAnnouncementScreen extends StatefulWidget {
  const NewAnnouncementScreen({super.key});
  @override
  State<NewAnnouncementScreen> createState() => _NewAnnouncementScreenState();
}

class _NewAnnouncementScreenState extends State<NewAnnouncementScreen> {
  final title = TextEditingController();
  final body = TextEditingController();
  bool important = true;
  final _form = GlobalKey<FormState>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pengumuman baru')),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          TextFormField(
            controller: title,
            maxLength: 80,
            decoration: const InputDecoration(labelText: 'Judul', helperText: 'mis. Titik jemput pindah ke Gate 5'),
            validator: (v) => (v ?? '').trim().isEmpty ? 'Judul wajib diisi' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(controller: body, maxLines: 5, maxLength: 1000, decoration: const InputDecoration(labelText: 'Isi (opsional)')),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Tandai penting'),
            subtitle: const Text('Tampil paling atas dengan sorotan kuning'),
            value: important,
            onChanged: (v) => setState(() => important = v),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () async {
              if (!_form.currentState!.validate()) return;
              await Hub.i.sendAnnouncement(title.text.trim(), body.text.trim(), important: important);
              if (!context.mounted) return;
              Navigator.pop(context);
              toast(context, 'Pengumuman dikirim ke semua anggota');
            },
            icon: const Icon(LucideIcons.send),
            label: const Text('Kirim ke semua'),
          ),
          const SizedBox(height: 8),
          const Text('Anggota yang sedang terputus menerima begitu tersambung lagi (disimpan 6 jam di jaringan mesh).'),
        ]),
      ),
    );
  }
}
