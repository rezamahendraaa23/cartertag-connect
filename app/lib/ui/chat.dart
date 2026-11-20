import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sembast/sembast.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/theme.dart';
import '../data/models.dart';
import '../services/hub.dart';
import '../services/media.dart';
import '../services/online.dart';
import 'widgets.dart';

typedef Snap = RecordSnapshot<String, Map<String, Object?>>;

/// S07 — Daftar channel & DM.
class ChatListScreen extends StatelessWidget {
  const ChatListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final h = Hub.i;
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        heroTag: 'newdm',
        tooltip: 'Pesan baru',
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MembersScreen())),
        child: const Icon(LucideIcons.messageSquarePlus),
      ),
      body: StreamBuilder<List<Snap>>(
        stream: h.watchAllMessages(),
        builder: (context, snap) {
          final msgs = snap.data ?? const [];
          final last = <String, Map<String, Object?>>{};
          final counts = <String, List<int>>{};
          for (final r in msgs) {
            final ch = '${r.value['ch']}';
            last.putIfAbsent(ch, () => r.value);
            if (r.value['mine'] != true) (counts[ch] ??= []).add((r.value['ts'] as num).toInt());
          }
          final base = h.channels();
          final baseIds = {for (final c in base) c.id};
          // grup yang sudah ada pesannya tapi tidak ada di daftar (grup area dari app versi lama, mobil yang drivernya belum
          // dikenal HP ini) tetap ditampilkan supaya pesannya tidak "hilang"
          final extra = last.keys.where((k) => !k.startsWith('d:') && !baseIds.contains(k) && h.canSee(k)).map(h.channelById);
          final all = [...base, ...extra];
          int tsOf(Channel c) => (last[c.id]?['ts'] as num?)?.toInt() ?? 0;
          final fixed = all.where((c) => !c.id.startsWith('c:')).toList();
          final cars = all.where((c) => c.id.startsWith('c:')).toList();
          // koordinator: grup mobil yang aktif diurut pesan terbaru; yang belum ada pesannya dilipat jadi satu baris
          final activeCars = h.me.isDriver ? cars : (cars.where((c) => last[c.id] != null).toList()..sort((a, b) => tsOf(b).compareTo(tsOf(a))));
          final idleCars = h.me.isDriver ? const <Channel>[] : cars.where((c) => last[c.id] == null).toList();
          final groups = [...fixed, ...activeCars];
          // DM dengan anggota yang sudah keluar disembunyikan (muncul lagi kalau dia gabung kembali)
          final dms = last.keys.where((k) => k.startsWith('d:')).map(h.channelById).where((ch) => ch.peer != null).toList()
            ..sort((a, b) => ((last[b.id]!['ts'] as num).compareTo(last[a.id]!['ts'] as num)));
          return ListView(padding: const EdgeInsets.only(bottom: 96), children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Material(
                color: CT.of(context).cardLow,
                borderRadius: BorderRadius.circular(24),
                child: InkWell(
                  borderRadius: BorderRadius.circular(24),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MembersScreen(search: true))),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(children: [
                      Icon(LucideIcons.search, size: 20, color: CT.of(context).muted),
                      const SizedBox(width: 12),
                      Text('Cari nama atau nomor mobil', style: TextStyle(color: CT.of(context).muted, fontSize: 15)),
                    ]),
                  ),
                ),
              ),
            ),
            const _LatestAnnouncement(),
            for (final ch in groups) _ChannelTile(ch: ch, last: last[ch.id], times: counts[ch.id] ?? const []),
            if (idleCars.isNotEmpty)
              ListTile(
                minTileHeight: 60,
                leading: CircleAvatar(backgroundColor: CT.of(context).accentBg, child: Icon(LucideIcons.carFront, size: 20, color: CT.of(context).accent)),
                title: Text('Grup mobil lain (${idleCars.length})', style: Theme.of(context).textTheme.titleMedium),
                subtitle: const Text('Belum ada pesan'),
                trailing: const Icon(LucideIcons.chevronRight),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => _CarGroupsScreen(cars: idleCars))),
              ),
            if (dms.isNotEmpty) const SectionLabel('Pesan pribadi'),
            for (final ch in dms) _ChannelTile(ch: ch, last: last[ch.id], times: counts[ch.id] ?? const []),
            if (dms.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 0),
                child: Text('Belum ada pesan pribadi.\nTekan tombol + untuk chat ke anggota tim.', textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: CT.of(context).muted)),
              ),
          ]);
        },
      ),
    );
  }
}

/// Grup mobil yang belum ada pesannya (koordinator), supaya daftar chat utama tetap pendek.
class _CarGroupsScreen extends StatelessWidget {
  const _CarGroupsScreen({required this.cars});
  final List<Channel> cars;
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('Grup mobil (${cars.length})')),
        body: ListView(children: [for (final ch in cars) _ChannelTile(ch: ch, last: null, times: const [])]),
      );
}

class _LatestAnnouncement extends StatelessWidget {
  const _LatestAnnouncement();
  @override
  Widget build(BuildContext context) {
    final c = CT.of(context);
    return StreamBuilder<List<Snap>>(
      stream: Hub.i.watch(Hub.i.s.anns),
      builder: (context, snap) {
        final list = snap.data ?? const [];
        if (list.isEmpty) return const SizedBox.shrink();
        final a = list.first.value;
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            decoration: BoxDecoration(color: c.amberBg, borderRadius: BorderRadius.circular(14)),
            child: Row(children: [
              Icon(LucideIcons.pin, size: 18, color: c.amber),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${a['title']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
                  if ('${a['body'] ?? ''}'.isNotEmpty)
                    Text('${a['body']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.5, color: c.muted)),
                ]),
              ),
            ]),
          ),
        );
      },
    );
  }
}

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({required this.ch, required this.last, required this.times});
  final Channel ch;
  final Map<String, Object?>? last;
  final List<int> times;

  @override
  Widget build(BuildContext context) {
    final c = CT.of(context);
    return FutureBuilder<int>(
      future: Hub.i.lastRead(ch.id),
      builder: (context, snap) {
        final read = snap.data ?? 0;
        final unread = times.where((t) => t > read).length;
        final preview = last == null ? ch.subtitle : _preview(last!);
        return InkWell(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatRoomScreen(channel: ch.id))),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(children: [
              ch.isDm
                  ? Avatar(name: ch.title, size: 52)
                  : Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(color: c.accentBg, shape: BoxShape.circle),
                      child: Icon(ch.id == 'g' ? LucideIcons.users : (ch.id == 'k' ? LucideIcons.shieldCheck : (ch.id.startsWith('c:') ? LucideIcons.carFront : LucideIcons.mapPin)), size: 22, color: c.accent),
                    ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text(ch.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium)),
                    if (last != null)
                      Text(hhmm((last!['ts'] as num).toInt()),
                          style: TextStyle(fontSize: 12, color: unread > 0 ? c.accent : c.muted, fontWeight: unread > 0 ? FontWeight.w600 : FontWeight.w400)),
                  ]),
                  const SizedBox(height: 3),
                  Row(children: [
                    Expanded(
                      child: Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 14, color: unread > 0 ? c.ink : c.muted, fontWeight: unread > 0 ? FontWeight.w500 : FontWeight.w400)),
                    ),
                    if (unread > 0)
                      Container(
                        constraints: const BoxConstraints(minWidth: 22),
                        height: 22,
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(horizontal: 7),
                        decoration: BoxDecoration(color: c.accent, borderRadius: BorderRadius.circular(999)),
                        child: Text('$unread', semanticsLabel: '$unread belum dibaca', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: c.onAccent)),
                      ),
                  ]),
                ]),
              ),
            ]),
          ),
        );
      },
    );
  }

  static String _preview(Map<String, Object?> m) {
    final who = m['mine'] == true ? 'Kamu' : '${m['fn'] ?? ''}';
    final media = m['media'] as Map?;
    final body = media != null ? (media['kind'] == 'audio' ? 'Voice note' : 'Foto') : '${m['text'] ?? ''}';
    return '$who: $body';
  }
}

/// S10 — Anggota & mulai DM.
class MembersScreen extends StatefulWidget {
  const MembersScreen({super.key, this.search = false});

  /// true = dibuka dari kolom cari: keyboard langsung muncul.
  final bool search;
  @override
  State<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends State<MembersScreen> {
  String q = '';

  void _changed() => mounted ? setState(() {}) : null;

  @override
  void initState() {
    super.initState();
    Hub.i.addListener(_changed); // titik status online/offline berubah realtime
  }

  @override
  void dispose() {
    Hub.i.removeListener(_changed);
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    final h = Hub.i;
    final c = CT.of(context);
    final list = h.roster.where((m) => m.id != h.me.id && m.matches(q)).toList()
      ..sort((a, b) {
        // driver urut nomor mobil, lalu yang lain urut nama
        if (a.isDriver != b.isDriver) return a.isDriver ? -1 : 1;
        if (a.isDriver) return (int.tryParse(a.car) ?? 9999).compareTo(int.tryParse(b.car) ?? 9999);
        return a.name.compareTo(b.name);
      });
    return Scaffold(
      appBar: AppBar(title: Text(widget.search ? 'Cari' : 'Anggota (${h.roster.length})')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            autofocus: widget.search,
            decoration: const InputDecoration(hintText: 'Nama, nomor mobil (mis. 3), atau plat', prefixIcon: Icon(LucideIcons.search)),
            onChanged: (v) => setState(() => q = v.toLowerCase().trim()),
          ),
        ),
        if (list.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(q.isEmpty ? 'Belum ada anggota lain yang gabung.' : 'Tidak ada yang cocok dengan "$q".', style: TextStyle(color: c.muted)),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: list.length,
            itemBuilder: (context, i) {
              final m = list[i];
              final canDm = m.pubX.isNotEmpty;
              return ListTile(
                minTileHeight: 64,
                leading: StatusAvatar(member: m),
                title: Text(m.displayName, style: Theme.of(context).textTheme.titleMedium),
                subtitle: Text([m.roleLabel, if (m.area.isNotEmpty) 'Area ${m.area}', statusText(m)].join(' · '),
                    style: TextStyle(color: Hub.i.statusOf(m.id) == MemberStatus.online ? c.ok : null)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (m.hp.isNotEmpty)
                    IconButton(
                      tooltip: 'Telepon ${m.name}',
                      onPressed: () => launchUrl(Uri.parse('tel:+${m.hp}')),
                      icon: Icon(LucideIcons.phone, color: c.accent),
                    ),
                ]),
                enabled: canDm,
                onTap: canDm
                    ? () => Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ChatRoomScreen(channel: dmChannelOf(h.me.id, m.id))))
                    : null,
              );
            },
          ),
        ),
      ]),
    );
  }
}

String dmChannelOf(String a, String b) {
  final l = [a, b]..sort();
  return 'd:${l[0]}:${l[1]}';
}

/// S08 — Ruang chat.
class ChatRoomScreen extends StatefulWidget {
  const ChatRoomScreen({super.key, required this.channel});
  final String channel;
  @override
  State<ChatRoomScreen> createState() => _ChatRoomScreenState();
}

class _ChatRoomScreenState extends State<ChatRoomScreen> {
  final text = TextEditingController();
  final focus = FocusNode();
  Map<String, Object?>? replyTo;
  String? replyId;
  bool sending = false;
  bool walkie = false;
  final _recorder = AudioRecorder();
  bool recording = false;
  DateTime? recStart;
  Timer? recTimer;
  int recLeft = 15;
  StreamSubscription? _sub;

  /// Tag @ di grup: label yang sudah dipilih -> member_id, dan saran yang sedang tampil.
  final Map<String, String> _tags = {};
  List<Member> _suggest = const [];
  int _atStart = -1;

  String get ch => widget.channel;

  /// Dibuat sekali: kalau dibuat di build(), setiap ketikan membuat langganan baru dan daftar pesan berkedip.
  late final Stream<List<Snap>> _msgs = Hub.i.watchMessages(widget.channel);

  /// Cari token "@..." tepat sebelum kursor; isi daftar saran anggota.
  void _updateMention() {
    if (ch.startsWith('d:')) return;
    final sel = text.selection.baseOffset;
    final before = sel < 0 ? text.text : text.text.substring(0, sel);
    final at = before.lastIndexOf('@');
    var list = const <Member>[];
    if (at >= 0 && (at == 0 || RegExp(r'\s').hasMatch(before[at - 1]))) {
      final q = before.substring(at + 1);
      if (!q.contains('\n') && q.length <= 20) {
        list = Hub.i.membersOf(ch).where((m) => m.id != Hub.i.me.id && m.joined && m.matches(q)).toList()
          ..sort((a, b) {
            if (a.isDriver != b.isDriver) return a.isDriver ? -1 : 1;
            return (int.tryParse(a.car) ?? 9999).compareTo(int.tryParse(b.car) ?? 9999);
          });
        if (list.length > 6) list = list.sublist(0, 6);
      }
    }
    _atStart = list.isEmpty ? -1 : at;
    if (list.length != _suggest.length || !list.every(_suggest.contains)) setState(() => _suggest = list);
  }

  void _pickMention(Member m) {
    final sel = text.selection.baseOffset < 0 ? text.text.length : text.selection.baseOffset;
    if (_atStart < 0) return;
    final label = m.tagLabel;
    final next = '${text.text.substring(0, _atStart)}@$label ${text.text.substring(sel)}';
    _tags[m.id] = label;
    text.value = TextEditingValue(text: next, selection: TextSelection.collapsed(offset: _atStart + label.length + 2));
    setState(() => _suggest = const []);
  }

  @override
  void initState() {
    super.initState();
    Hub.i.openChannel = ch;
    Hub.i.markRead(ch);
    _sub = Hub.i.s.messages
        .query(finder: Finder(filter: Filter.and([Filter.equals('slug', Hub.i.slug), Filter.equals('ch', ch)])))
        .onCount(Hub.i.s.db)
        .skip(1)
        .listen((_) => Hub.i.markRead(ch));
    Hub.i.s.get<String>('draft_${Hub.i.slug}_$ch').then((d) => text.text = d ?? '');
    Hub.i.s.get<bool>('walkie_${Hub.i.slug}_$ch').then((v) => setState(() => walkie = v ?? false));
    text.addListener(() {
      _updateMention();
      setState(() {});
    });
    Hub.i.pttIncoming.addListener(_autoPlay);
  }

  @override
  void dispose() {
    if (Hub.i.openChannel == ch) Hub.i.openChannel = null;
    Hub.i.s.put('draft_${Hub.i.slug}_$ch', text.text);
    Hub.i.pttIncoming.removeListener(_autoPlay);
    _sub?.cancel();
    recTimer?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  void _autoPlay() {
    final p = Hub.i.pttIncoming.value;
    if (p == null || p['ch'] != ch) return;
    Hub.i.pttIncoming.value = null;
    AudioClip.play(context, ch, (p['media'] as Map).cast<String, dynamic>(), from: '${p['from']}');
  }

  Future<void> _send() async {
    final t = text.text.trim();
    if (t.isEmpty || sending) return;
    if (t.length > 1000) return;
    setState(() => sending = true);
    try {
      await Hub.i.sendText(ch, t, replyTo: replyId, tags: Map.of(_tags));
      _tags.clear();
      text.clear();
      setState(() {
        replyTo = null;
        replyId = null;
      });
      HapticFeedback.lightImpact();
    } catch (e) {
      if (mounted) toast(context, '$e'.replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> _quick() async {
    final r = await showModalBottomSheet<(String, String, String?)>(context: context, builder: (_) => const QuickSheet());
    if (r == null) return;
    try {
      await Hub.i.sendQuick(ch, r.$1, r.$2, fleetStatus: r.$3);
      if (!mounted) return;
      toast(context, 'Terkirim ke ${Hub.i.channelById(ch).title}');
    } catch (e) {
      if (mounted) toast(context, '$e'.replaceFirst('Bad state: ', ''));
    }
  }

  Future<void> _photo() async {
    if (!Media.i.canUpload) {
      toast(context, 'Foto butuh internet. Tanpa sinyal, kirim teks dulu.');
      return;
    }
    final src = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(minTileHeight: 56, leading: const Icon(LucideIcons.camera), title: const Text('Kamera'), onTap: () => Navigator.pop(ctx, ImageSource.camera)),
          ListTile(minTileHeight: 56, leading: const Icon(LucideIcons.image), title: const Text('Galeri'), onTap: () => Navigator.pop(ctx, ImageSource.gallery)),
        ]),
      ),
    );
    if (src == null) return;
    final x = await ImagePicker().pickImage(source: src, maxWidth: 1600, maxHeight: 1600, imageQuality: 60);
    if (x == null) return;
    final bytes = await x.readAsBytes();
    if (!mounted) return;
    toast(context, 'Mengunggah foto…', duration: const Duration(seconds: 20));
    try {
      await Media.i.send(ch, bytes, kind: 'image', mime: 'image/jpeg', text: text.text.trim());
      text.clear();
      if (mounted) toast(context, 'Foto terkirim');
    } catch (e) {
      if (mounted) toast(context, 'Gagal kirim foto: $e');
    }
  }

  // ---- voice note & push-to-talk (tahan tombol mic)

  Future<void> _recStart() async {
    if (kIsWeb) {
      toast(context, 'Voice note hanya di app Android.');
      return;
    }
    if (!await _recorder.hasPermission()) {
      if (mounted) toast(context, 'Izin mikrofon ditolak.');
      return;
    }
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/vn_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 24000, sampleRate: 16000, numChannels: 1), path: path);
    HapticFeedback.mediumImpact();
    final max = walkie ? 15 : 60;
    setState(() {
      recording = true;
      recStart = DateTime.now();
      recLeft = max;
    });
    recTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      setState(() => recLeft--);
      if (recLeft <= 0) _recStop(send: true);
    });
  }

  Future<void> _recStop({required bool send}) async {
    if (!recording) return;
    recTimer?.cancel();
    final path = await _recorder.stop();
    final dur = DateTime.now().difference(recStart!).inMilliseconds;
    setState(() => recording = false);
    if (!send || path == null || dur < 700) return;
    if (!Media.i.canUpload) {
      if (mounted) toast(context, 'Voice note butuh internet. Tanpa sinyal, kirim teks atau pesan cepat.');
      return;
    }
    try {
      final bytes = await XFile(path).readAsBytes();
      await Media.i.send(ch, bytes, kind: 'audio', mime: 'audio/mp4', durMs: dur, ptt: walkie);
      HapticFeedback.lightImpact();
    } catch (e) {
      if (mounted) toast(context, 'Gagal kirim suara: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = CT.of(context);
    final info = Hub.i.channelById(ch);
    final empty = text.text.trim().isEmpty;
    final over = text.text.length > 1000;
    return Scaffold(
      backgroundColor: c.chatBg,
      appBar: AppBar(
        titleSpacing: 0,
        title: ListenableBuilder(
          listenable: Hub.i,
          builder: (context, _) => Row(children: [
          info.isDm && info.peer != null
              ? StatusAvatar(member: info.peer!, size: 38)
              : info.isDm
              ? Avatar(name: info.title, size: 38)
              : Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(color: c.accentBg, shape: BoxShape.circle),
                  child: Icon(ch == 'g' ? LucideIcons.users : (ch == 'k' ? LucideIcons.shieldCheck : (ch.startsWith('c:') ? LucideIcons.carFront : LucideIcons.mapPin)), size: 18, color: c.accent),
                ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(info.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium),
              Text(info.isDm ? (info.peer != null ? statusText(info.peer!) : info.subtitle) : '${Hub.i.membersOf(ch).length} anggota',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
        ]),
        ),
        actions: [
          if (!kIsWeb)
            IconButton(
              tooltip: walkie ? 'Mode walkie aktif (voice diputar otomatis)' : 'Aktifkan mode walkie',
              onPressed: () async {
                setState(() => walkie = !walkie);
                await Hub.i.s.put('walkie_${Hub.i.slug}_$ch', walkie);
                if (context.mounted) toast(context, walkie ? 'Mode walkie: voice dari channel ini diputar otomatis.' : 'Mode walkie dimatikan.');
              },
              icon: Icon(LucideIcons.radio, color: walkie ? c.accent : c.muted),
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: StreamBuilder<List<Snap>>(
            stream: _msgs,
            builder: (context, snap) {
              final list = snap.data;
              if (list == null) return const Center(child: CircularProgressIndicator());
              if (list.isEmpty) {
                return EmptyState(icon: LucideIcons.messageCircle, title: 'Belum ada pesan', text: info.isDm ? 'Sapa ${info.title}.' : 'Mulai koordinasi dengan tim di sini.');
              }
              return ListView.builder(
                reverse: true,
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final m = list[i];
                  final prev = i + 1 < list.length ? list[i + 1].value : null;
                  final showDay = prev == null || !_sameDay((prev['ts'] as num).toInt(), (m.value['ts'] as num).toInt());
                  final showName = !info.isDm && m.value['mine'] != true && (prev == null || prev['from'] != m.value['from'] || showDay);
                  return Column(children: [
                    if (showDay) _DayDivider(ms: (m.value['ts'] as num).toInt()),
                    Dismissible(
                      key: ValueKey(m.key),
                      direction: DismissDirection.startToEnd,
                      confirmDismiss: (_) async {
                        setState(() {
                          replyTo = m.value;
                          replyId = m.key;
                        });
                        focus.requestFocus();
                        return false;
                      },
                      background: const Align(alignment: Alignment.centerLeft, child: Padding(padding: EdgeInsets.only(left: 16), child: Icon(LucideIcons.reply))),
                      child: Bubble(id: m.key, m: m.value, channel: ch, showName: showName, all: list),
                    ),
                  ]);
                },
              );
            },
          ),
        ),
        if (replyTo != null)
          Container(
            margin: const EdgeInsets.fromLTRB(10, 0, 10, 4),
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
            decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(14), border: Border(left: BorderSide(color: c.accent, width: 4))),
            child: Row(children: [
              Icon(LucideIcons.reply, size: 18, color: c.accent),
              const SizedBox(width: 8),
              Expanded(child: Text('Balas ${replyTo!['fn']}: ${replyTo!['text']}', maxLines: 1, overflow: TextOverflow.ellipsis)),
              IconButton(tooltip: 'Batal balas', onPressed: () => setState(() => replyTo = replyId = null), icon: const Icon(LucideIcons.x)),
            ]),
          ),
        if (recording)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(10, 0, 10, 4),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            decoration: BoxDecoration(color: c.danger, borderRadius: BorderRadius.circular(999)),
            child: Row(children: [
              const Icon(LucideIcons.mic, color: Colors.white),
              const SizedBox(width: 10),
              Expanded(child: Text(walkie ? 'Bicara… lepas untuk kirim · geser kiri batal' : 'Merekam… lepas untuk kirim · geser kiri batal', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600))),
              Text('0:${recLeft.toString().padLeft(2, '0')}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
            ]),
          ),
        if (_suggest.isNotEmpty)
          Container(
            margin: const EdgeInsets.fromLTRB(10, 0, 10, 4),
            decoration: brutalBox(context),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final m in _suggest)
                ListTile(
                  dense: true,
                  minTileHeight: 52,
                  leading: Avatar(name: m.name, size: 34),
                  title: Text(m.tagLabel, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(m.isDriver && m.car.isNotEmpty ? m.name : m.roleLabel),
                  onTap: () => _pickMention(m),
                ),
            ]),
          ),
        _composer(c, empty, over),
      ]),
    );
  }

  Widget _composer(CT c, bool empty, bool over) {
    Widget round(Widget child, {VoidCallback? onTap, String? label, Color? color}) => Semantics(
          button: true,
          label: label,
          child: Material(
            color: color ?? c.accent,
            shape: const CircleBorder(),
            child: InkWell(customBorder: const CircleBorder(), onTap: onTap, child: SizedBox(width: 48, height: 48, child: Center(child: child))),
          ),
        );
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 48),
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 4, offset: const Offset(0, 1))],
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                IconButton(tooltip: 'Pesan cepat', onPressed: _quick, icon: Icon(LucideIcons.zap, color: c.muted)),
                Expanded(
                  child: TextField(
                    controller: text,
                    focusNode: focus,
                    minLines: 1,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    style: const TextStyle(fontSize: 16),
                    decoration: InputDecoration(
                      hintText: 'Pesan',
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      focusedErrorBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 13),
                      counterText: text.text.length > 800 ? '${text.text.length}/1000' : null,
                      errorText: over ? 'Maksimal 1000 karakter' : null,
                    ),
                  ),
                ),
                IconButton(tooltip: 'Kirim foto', onPressed: _photo, icon: Icon(LucideIcons.camera, color: c.muted)),
              ]),
            ),
          ),
          const SizedBox(width: 6),
          if (empty && !kIsWeb)
            GestureDetector(
              onLongPressStart: (_) => _recStart(),
              onLongPressEnd: (_) => _recStop(send: true),
              onLongPressMoveUpdate: (d) {
                if (d.offsetFromOrigin.dx < -80) _recStop(send: false);
              },
              child: Tooltip(
                message: walkie ? 'Tahan untuk bicara (walkie)' : 'Tahan untuk voice note',
                child: round(Icon(LucideIcons.mic, color: c.onAccent), label: 'Tahan untuk merekam suara', color: recording ? c.danger : c.accent),
              ),
            )
          else
            round(
              sending ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2, color: c.onAccent)) : Icon(LucideIcons.sendHorizontal, color: c.onAccent),
              onTap: over ? null : _send,
              label: 'Kirim',
            ),
        ]),
      ),
    );
  }

  static bool _sameDay(int a, int b) {
    final x = DateTime.fromMillisecondsSinceEpoch(a), y = DateTime.fromMillisecondsSinceEpoch(b);
    return x.year == y.year && x.month == y.month && x.day == y.day;
  }
}

class _DayDivider extends StatelessWidget {
  const _DayDivider({required this.ms});
  final int ms;

  static String _label(DateTime d, List<String> months) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day), day = DateTime(d.year, d.month, d.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Hari ini';
    if (diff == 1) return 'Kemarin';
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun', 'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des'];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(color: CT.of(context).card, borderRadius: BorderRadius.circular(8)),
          child: Text(_label(d, months), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: CT.of(context).muted)),
        ),
      ),
    );
  }
}

/// K03 + K04 — Gelembung pesan beserta meta (jam · jalur · status).
class Bubble extends StatelessWidget {
  const Bubble({super.key, required this.id, required this.m, required this.channel, required this.showName, required this.all});
  final String id;
  final Map<String, Object?> m;
  final String channel;
  final bool showName;
  final List<Snap> all;

  @override
  Widget build(BuildContext context) {
    final c = CT.of(context);
    final mine = m['mine'] == true;
    final quick = m['k'] == 'quick';
    final media = (m['media'] as Map?)?.cast<String, dynamic>();
    final tagged = !mine && ((m['tags'] as List?) ?? const []).contains(Hub.i.me.id);
    final bg = mine ? c.bubbleMine : (quick || tagged ? c.amberBg : c.bubbleOther);
    final fg = mine ? c.onBubbleMine : c.ink;
    const nameColors = [Color(0xFF1D5DAA), Color(0xFF047857), Color(0xFF7C3AED), Color(0xFFB45309), Color(0xFFBE185D), Color(0xFF0E7490)];
    final nameColor = nameColors['${m['from']}'.codeUnits.fold<int>(0, (a, b) => a + b) % nameColors.length];
    final queued = m['out'] == 'antre';
    final reply = m['reply'] == null ? null : all.where((s) => s.key == m['reply']).map((s) => s.value).firstOrNull;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        child: Column(crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
          GestureDetector(
            onLongPress: () => _menu(context),
            child: Container(
              margin: EdgeInsets.only(bottom: 4, top: showName ? 6 : 0),
              padding: const EdgeInsets.fromLTRB(11, 7, 11, 6),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(!mine && showName ? 4 : 16),
                  topRight: Radius.circular(mine ? 4 : 16),
                  bottomLeft: const Radius.circular(16),
                  bottomRight: const Radius.circular(16),
                ),
                border: queued ? Border.all(color: c.muted.withValues(alpha: 0.5)) : null,
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 2, offset: const Offset(0, 1))],
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                if (showName)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text.rich(TextSpan(children: [
                      TextSpan(text: '${m['fn'] ?? ''}', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: nameColor)),
                      if (m['fr'] != null) TextSpan(text: '  ${m['fr']}', style: TextStyle(fontSize: 11.5, color: c.muted)),
                    ])),
                  ),
                if (reply != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: c.ink.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(8), border: Border(left: BorderSide(color: c.accent, width: 3))),
                    child: Text('${reply['fn']}: ${reply['text']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: fg, fontSize: 13)),
                  ),
                if (quick)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(LucideIcons.zap, size: 13, color: c.amber),
                      const SizedBox(width: 4),
                      Text('Pesan cepat', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: c.amber)),
                    ]),
                  ),
                if (media != null) MediaView(channel: channel, media: media, fg: fg),
                if ('${m['text'] ?? ''}'.isNotEmpty)
                  Text.rich(
                    _withTags('${m['text']}', ((m['tl'] as List?) ?? const []).map((e) => '@$e').toList(), c.accent),
                    style: TextStyle(fontSize: 15.5, height: 1.35, color: fg, fontWeight: quick ? FontWeight.w600 : FontWeight.w400),
                  ),
                const SizedBox(height: 2),
                Align(alignment: Alignment.centerRight, widthFactor: 1, child: _Meta(id: id, m: m, fg: c.muted, channel: channel)),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  void _menu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            minTileHeight: 56,
            leading: const Icon(LucideIcons.copy),
            title: const Text('Salin'),
            onTap: () {
              Clipboard.setData(ClipboardData(text: '${m['text'] ?? ''}'));
              Navigator.pop(ctx);
            },
          ),
          if (m['mine'] == true)
            ListTile(
              minTileHeight: 56,
              leading: const Icon(LucideIcons.info),
              title: const Text('Info pesan'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => MessageInfoScreen(id: id, channel: channel)));
              },
            ),
          if (m['out'] == 'antre')
            ListTile(
              minTileHeight: 56,
              leading: const Icon(LucideIcons.refreshCw),
              title: const Text('Coba kirim sekarang'),
              onTap: () {
                Navigator.pop(ctx);
                Hub.i.retryNow();
              },
            ),
          ListTile(
            minTileHeight: 56,
            leading: const Icon(LucideIcons.trash2),
            title: const Text('Hapus untuk saya'),
            onTap: () {
              Hub.i.s.messages.record(id).delete(Hub.i.s.db);
              Hub.i.s.outbox.record(id).delete(Hub.i.s.db);
              Navigator.pop(ctx);
            },
          ),
        ]),
      ),
    );
  }
}

/// Teks pesan dengan bagian "@Mobil 3" / "@Nama" dicetak tebal biru.
TextSpan _withTags(String text, List<String> tags, Color color) {
  if (tags.isEmpty) return TextSpan(text: text);
  final spans = <InlineSpan>[];
  var i = 0;
  while (i < text.length) {
    var hit = -1, len = 0;
    for (final t in tags) {
      final j = text.indexOf(t, i);
      if (j >= 0 && (hit < 0 || j < hit)) {
        hit = j;
        len = t.length;
      }
    }
    if (hit < 0) {
      spans.add(TextSpan(text: text.substring(i)));
      break;
    }
    if (hit > i) spans.add(TextSpan(text: text.substring(i, hit)));
    spans.add(TextSpan(text: text.substring(hit, hit + len), style: TextStyle(color: color, fontWeight: FontWeight.w700)));
    i = hit + len;
  }
  return TextSpan(children: spans);
}

class _Meta extends StatelessWidget {
  const _Meta({required this.id, required this.m, required this.fg, required this.channel});
  final String id;
  final Map<String, Object?> m;
  final Color fg;
  final String channel;

  @override
  Widget build(BuildContext context) {
    final mine = m['mine'] == true;
    final path = '${m['path'] ?? ''}';
    final pathIcon = switch (path) { 'online' => LucideIcons.cloud, 'bridge' => LucideIcons.link, '' => null, _ => LucideIcons.network };
    final pathName = switch (path) { 'online' => 'internet', 'bridge' => 'jembatan', '' => '', _ => 'mesh' };
    final dlv = (m['dlv'] as Map?)?.length ?? 0;
    final read = (m['read'] as Map?)?.length ?? 0;
    IconData? status;
    String statusText = '';
    if (mine) {
      if (m['out'] == 'antre') {
        status = LucideIcons.hourglass;
        statusText = 'Menunggu jalur';
      } else if (read > 0) {
        status = LucideIcons.checkCheck;
        statusText = 'Dibaca';
      } else if (dlv > 0) {
        status = LucideIcons.checkCheck;
        statusText = 'Sampai';
      } else {
        status = LucideIcons.check;
        statusText = 'Terkirim';
      }
    }
    final style = TextStyle(fontSize: 11, color: fg);
    return Semantics(
      label: '${hhmm((m['ts'] as num).toInt())}${pathName.isEmpty ? '' : ', lewat $pathName'}${statusText.isEmpty ? '' : ', $statusText'}',
      excludeSemantics: true,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(hhmm((m['ts'] as num).toInt()), style: style),
        if (pathIcon != null) ...[const SizedBox(width: 5), Icon(pathIcon, size: 11, color: fg)],
        if (status != null) ...[
          const SizedBox(width: 5),
          Icon(status, size: 15, color: read > 0 ? CT.of(context).accent : fg),
          if (m['out'] == 'antre') Text(' menunggu jalur', style: style),
        ],
      ]),
    );
  }
}

/// S09 — Info pesan (status per penerima).
class MessageInfoScreen extends StatelessWidget {
  const MessageInfoScreen({super.key, required this.id, required this.channel});
  final String id;
  final String channel;

  @override
  Widget build(BuildContext context) {
    final h = Hub.i;
    return Scaffold(
      appBar: AppBar(title: const Text('Info pesan')),
      body: StreamBuilder<Map<String, Object?>?>(
        stream: h.s.messages.record(id).onSnapshot(h.s.db).map((s) => s?.value),
        builder: (context, snap) {
          final m = snap.data;
          if (m == null) return const SizedBox.shrink();
          final dlv = ((m['dlv'] as Map?) ?? {}).cast<String, Object?>();
          final read = ((m['read'] as Map?) ?? {}).cast<String, Object?>();
          return StreamBuilder<Map<String, Map>>(
            stream: channel.startsWith('d:') ? const Stream.empty() : Online.i.watchAcks(id),
            builder: (context, ackSnap) {
              final acks = ackSnap.data ?? const {};
              final d = {...dlv.keys, ...acks.keys.where((k) => acks[k]?['dlv'] != null || acks[k]?['d'] != null)};
              final r = {...read.keys, ...acks.keys.where((k) => acks[k]?['r'] != null || acks[k]?['read'] != null)};
              final members = channel.startsWith('d:') ? [h.channelById(channel).peer].whereType<Member>().toList() : h.membersOf(channel).where((x) => x.id != h.me.id).toList();
              return ListView(children: [
                InfoBanner(
                  text: 'Lewat ${m['path'] == 'online' ? 'internet' : (m['path'] == 'bridge' ? 'jembatan' : 'mesh')} · Sampai ${d.length} dari ${members.length} · Dibaca ${r.length}',
                  icon: LucideIcons.info,
                ),
                if (!channel.startsWith('d:'))
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Text('Tanda terima grup dihitung lewat internet saja, supaya jaringan mesh tidak penuh.'),
                  ),
                for (final x in members)
                  ListTile(
                    leading: Avatar(name: x.name, size: 40),
                    title: Text(x.displayName),
                    subtitle: Text(x.roleLabel),
                    trailing: Text(r.contains(x.id) ? 'Dibaca' : (d.contains(x.id) ? 'Sampai' : 'Belum'), style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
              ]);
            },
          );
        },
      ),
    );
  }
}

/// S11 — Pesan cepat. Hasil: (kode, teks, status armada?)
class QuickSheet extends StatelessWidget {
  const QuickSheet({super.key});

  static const driver = [
    ('di_titik', 'Sudah di titik jemput', LucideIcons.mapPinned, null),
    ('berangkat', 'Berangkat', LucideIcons.navigation, null),
    ('tiba', 'Tiba di venue', LucideIcons.check, null),
    ('macet', 'Macet ±15 menit', LucideIcons.clock, null),
    ('kurang', 'Penumpang kurang', LucideIcons.users, null),
    ('mogok', 'Mobil bermasalah', LucideIcons.wrench, null),
    ('bantuan', 'Butuh bantuan', LucideIcons.circleAlert, null),
  ];
  static const panitia = [
    ('gerbang', 'Saya di gerbang', LucideIcons.mapPin, null),
    ('kumpul', 'Penumpang sudah dikumpulkan', LucideIcons.users, null),
    ('parkir', 'Menuju parkiran', LucideIcons.navigation, null),
    ('cari', 'Ada penumpang hilang', LucideIcons.search, null),
    ('bantuan', 'Butuh bantuan', LucideIcons.circleAlert, null),
  ];

  @override
  Widget build(BuildContext context) {
    final items = Hub.i.me.isDriver ? driver : panitia;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Pesan cepat', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 2.2,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (final it in items)
                PressBox(
                  padding: const EdgeInsets.all(10),
                  semantics: it.$2,
                  color: it.$1 == 'mogok' || it.$1 == 'bantuan' ? CT.of(context).dangerBg : null,
                  onTap: () => Navigator.pop(context, (it.$1, it.$2, it.$4)),
                  child: Row(children: [
                    Icon(it.$3, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(it.$2, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                      ]),
                    ),
                  ]),
                ),
            ],
          ),
        ]),
      ),
    );
  }
}

/// Foto / voice note dalam gelembung (unduh saat dibuka).
class MediaView extends StatefulWidget {
  const MediaView({super.key, required this.channel, required this.media, required this.fg});
  final String channel;
  final Map<String, dynamic> media;
  final Color fg;
  @override
  State<MediaView> createState() => _MediaViewState();
}

class _MediaViewState extends State<MediaView> {
  Uint8List? bytes;
  bool loading = false;
  String? error;

  @override
  void initState() {
    super.initState();
    if (widget.media['kind'] == 'image' && Media.i.canUpload) _load();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final b = await Media.i.get(widget.channel, '${widget.media['file']}');
      if (mounted) setState(() => bytes = b);
    } catch (e) {
      if (mounted) setState(() => error = 'Butuh internet untuk membuka');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fg = widget.fg;
    if (widget.media['kind'] == 'audio') {
      final dur = ((widget.media['dur'] as num?) ?? 0) / 1000;
      return InkWell(
        onTap: () => AudioClip.play(context, widget.channel, widget.media),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(LucideIcons.play, color: fg),
            const SizedBox(width: 8),
            Text(widget.media['ptt'] == true ? 'Walkie · ${dur.toStringAsFixed(0)} dtk' : 'Voice note · ${dur.toStringAsFixed(0)} dtk',
                style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
          ]),
        ),
      );
    }
    if (bytes != null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: GestureDetector(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => Scaffold(appBar: AppBar(title: const Text('Foto')), body: InteractiveViewer(child: Center(child: Image.memory(bytes!)))))),
          child: ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.memory(bytes!, height: 200, fit: BoxFit.cover)),
        ),
      );
    }
    return InkWell(
      onTap: loading ? null : _load,
      child: Container(
        height: 120,
        width: 220,
        alignment: Alignment.center,
        margin: const EdgeInsets.only(bottom: 4),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: fg.withValues(alpha: 0.5), width: 1.5)),
        child: loading
            ? CircularProgressIndicator(color: fg)
            : Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(error != null ? LucideIcons.cloudOff : LucideIcons.image, color: fg),
                const SizedBox(height: 4),
                Text(error ?? 'Ketuk untuk membuka foto', style: TextStyle(color: fg, fontSize: 13)),
              ]),
      ),
    );
  }
}

/// Pemutar voice note / walkie.
class AudioClip {
  static final _player = AudioPlayer();

  static Future<void> play(BuildContext context, String channel, Map<String, dynamic> media, {String? from}) async {
    try {
      final b = await Media.i.get(channel, '${media['file']}');
      if (b == null) return;
      await _player.setAudioSource(AudioSource.uri(Uri.dataFromBytes(b, mimeType: '${media['mime'] ?? 'audio/mp4'}')));
      if (from != null && context.mounted) toast(context, 'Memutar dari $from', action: 'Jeda', onAction: () => _player.pause());
      await _player.play();
    } catch (e) {
      if (context.mounted) toast(context, 'Tidak bisa memutar suara (butuh internet).');
    }
  }
}
