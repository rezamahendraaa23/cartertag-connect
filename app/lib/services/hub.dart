import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'dart:typed_data';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sembast/sembast.dart';

import '../core/crypto.dart';
import '../core/envelope.dart';
import '../core/ids.dart';
import '../data/models.dart';
import '../data/store.dart';
import 'api.dart';
import 'bridge_client.dart';
import 'location.dart';
import 'mesh.dart';
import 'my_ids_io.dart' if (dart.library.js_interop) 'my_ids_web.dart';
import 'notifier.dart';
import 'online.dart';
import 'updater.dart';

/// Jalur koneksi untuk pil status (PRD UI/UX K01).
enum Link { online, mesh, bridge, isolated }

/// Status seorang anggota (titik status di daftar anggota & header chat).
enum MemberStatus { online, near, offline }

/// Pusat app: sesi konser, kirim/terima envelope lewat semua jalur, outbox, gateway, dan state UI.
class Hub extends ChangeNotifier with WidgetsBindingObserver {
  Hub._();
  static final i = Hub._();

  late DeviceKeys keys;
  Concert? concert;
  Uint8List _cid = Uint8List(8);
  SecretKey? _groupKey;
  final Map<String, String> _chByHash = {};
  final Map<String, Map<String, dynamic>> _extraRoster = {};

  /// member_id -> (online?, terakhir terlihat ms), realtime dari Firebase (tanpa panggilan GAS).
  final Map<String, (bool, int)> presence = {};
  final _subs = <StreamSubscription>[];
  Timer? _tick, _helloTimer, _refreshTimer, _sosTimer;
  bool netUp = false;
  bool _foreground = true;
  String? openChannel;
  String appVersion = '';
  int queued = 0;
  final _ackBuffer = <String, Set<String>>{}; // channel -> id yang perlu ditandai
  Timer? _ackTimer;
  final _seenMem = <String>{};

  // ----------------------------------------------------------- state turunan

  Store get s => Store.i;
  String get slug => concert?.slug ?? '';
  Member get me => concert!.me;

  List<Member> get roster {
    final c = concert;
    if (c == null) return const [];
    final base = c.roster;
    final ids = base.map((m) => m.id).toSet();
    return [
      ...base,
      for (final e in _extraRoster.values)
        if (!ids.contains(e['mid'])) Member(e),
    ];
  }

  Member? member(String id) {
    for (final m in roster) {
      if (m.id == id) return m;
    }
    return null;
  }

  Link get link {
    if (Online.i.connected) return Link.online;
    if (Bridge.i.connected) return Link.bridge;
    if (Mesh.i.peers.any((p) => p.connected)) return Link.mesh;
    return Link.isolated;
  }

  int get meshPeers => Mesh.i.peers.where((p) => p.connected).length;
  List<Peer> get meshPeersList => Mesh.i.peers;

  /// Status anggota untuk ditampilkan: online / dekat (Bluetooth) / terakhir online.
  MemberStatus statusOf(String mid) {
    final near = Mesh.i.peers.any((p) => p.connected && p.memberId == mid);
    final pr = presence[mid];
    if (pr != null && pr.$1) return MemberStatus.online;
    if (near) return MemberStatus.near;
    return MemberStatus.offline;
  }

  /// Waktu terakhir online (ms), 0 kalau belum pernah terlihat.
  int lastSeenOf(String mid) => presence[mid]?.$2 ?? 0;

  /// Paksa coba kirim ulang antrean sekarang (tombol "Coba kirim sekarang").
  Future<void> retryNow() async {
    if (netUp) await refresh();
    await _flushOutbox();
  }

  /// Channel yang terlihat untuk role saya (PRD Sistem M2.1).
  List<Channel> channels() {
    final c = concert;
    if (c == null) return const [];
    final out = <Channel>[Channel('g', 'Grup Konser', subtitle: 'Semua anggota')];
    final areas = c.areas;
    if (me.isDriver) {
      if (me.area.isNotEmpty) out.add(Channel('a:${me.area}', 'Area ${me.area}', subtitle: 'Driver & koordinator area ini'));
    } else {
      for (final a in areas) {
        out.add(Channel('a:$a', 'Area $a', subtitle: 'Driver & koordinator area ini'));
      }
      out.add(Channel('k', 'Koordinator', subtitle: 'Koordinator & panitia'));
    }
    return out;
  }

  Channel channelById(String id) {
    if (id.startsWith('d:')) {
      final parts = id.split(':');
      final peerId = parts[1] == me.id ? parts[2] : parts[1];
      final p = member(peerId);
      return Channel(id, p?.name ?? 'Anggota', subtitle: p?.roleLabel ?? '', peer: p);
    }
    for (final ch in channels()) {
      if (ch.id == id) return ch;
    }
    if (id.startsWith('a:')) return Channel(id, 'Area ${id.substring(2)}');
    return Channel(id, id == 'k' ? 'Koordinator' : 'Grup Konser');
  }

  // ----------------------------------------------------------- start / sesi

  Future<void> boot() async {
    keys = await DeviceKeys.load();
    try {
      appVersion = (await PackageInfo.fromPlatform()).version;
    } catch (_) {}
    WidgetsBinding.instance.addObserver(this);
    _subs.add(Connectivity().onConnectivityChanged.listen((r) {
      final up = r.any((x) => x != ConnectivityResult.none);
      if (up && !netUp) _onNetworkBack();
      netUp = up;
      notifyListeners();
    }));
    netUp = (await Connectivity().checkConnectivity()).any((x) => x != ConnectivityResult.none);
    final active = await s.get<String>('active');
    if (active != null) {
      final b = await s.concerts.record(active).get(s.db);
      if (b != null) await _activate(Concert(Map<String, dynamic>.from(b)));
    }
    if (kIsWeb) Bridge.i.autoConnect();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground && concert != null) {
      _drainMesh();
      LocationSvc.i.setForeground(true);
    } else {
      LocationSvc.i.setForeground(false);
    }
  }

  Future<List<Map<String, dynamic>>> savedConcerts() async {
    final recs = await s.concerts.find(s.db);
    return recs.map((r) => Map<String, dynamic>.from(r.value)).toList();
  }

  /// Gabung pakai kode driver / koordinator (butuh internet sekali). Driver wajib isi nomor mobil.
  Future<Concert> join({required String kode, required String nama, String car = '', String hp = ''}) async {
    final fcm = await Online.i.fcmToken();
    final code = kode.toUpperCase().replaceAll(RegExp(r'^CT-?'), '').replaceAll(RegExp(r'[^A-Z0-9]'), '');
    final b = await Api.call('join', {
      'kode': code,
      'nama': nama,
      'car': car.trim(),
      'hp': normHp(hp),
      'pub_x': keys.pubXb64,
      'pub_ed': keys.pubEdB64,
      'fcm_token': fcm ?? '',
      'platform': kIsWeb ? 'web' : 'android',
      'app_version': appVersion,
    });
    final c = Concert(b);
    await s.concerts.record(c.slug).put(s.db, b);
    await s.put('active', c.slug);
    await s.put('code_${c.slug}', code);
    await s.put('car_${c.slug}', car.trim());
    await s.put('profile_name', nama.trim());
    if (normHp(hp).isNotEmpty) await s.put('profile_hp', hp.trim());
    await _activate(c);
    // token FCM baru bisa diambil setelah Firebase terpasang (opsi datang dari server)
    if ((fcm ?? '').isEmpty) unawaited(refresh());
    return c;
  }

  /// Gabung offline dari QR undangan (role mengikuti kode pengundang). Disahkan otomatis ke server begitu ada internet.
  Future<Concert> joinFromInvite(Map<String, dynamic> qr, {required String nama, String car = ''}) async {
    final slugQ = '${qr['s']}';
    final mid = await memberIdFor(slugQ, keys.pubEdB64);
    final role = '${qr['r'] ?? 'driver'}';
    final b = <String, dynamic>{
      'konser': {'slug': slugQ, 'nama': qr['n'] ?? 'Konser', 'venue': qr['v'] ?? '', 'dates': qr['d'] ?? []},
      'epoch': qr['e'],
      'group_key': qr['k'],
      'member': {'mid': mid, 'n': nama, 'r': role, 'car': role == 'driver' ? car.trim() : '', 'px': keys.pubXb64, 'pe': keys.pubEdB64, 'st': 'aktif'},
      'member_token': '',
      'roster': [],
      'manifest': {'enabled': false, 'rows': []},
      'unverified': true,
    };
    await s.concerts.record(slugQ).put(s.db, b);
    await s.put('active', slugQ);
    await s.put('car_$slugQ', car.trim());
    if (qr['c'] != null) await s.put('code_$slugQ', '${qr['c']}');
    final c = Concert(b);
    await _activate(c);
    return c;
  }

  /// Dipakai klien web Mode Jembatan: bundle dari HP Android host.
  Future<Concert> joinFromBridge(Map<String, dynamic> bundle) async {
    final c = Concert(bundle);
    await s.concerts.record(c.slug).put(s.db, bundle);
    await s.put('active', c.slug);
    await _activate(c);
    return c;
  }

  /// Perbarui roster, manifest, kunci (epoch), token Firebase. Dipanggil saat online & tiap 30 menit.
  Future<void> refresh() async {
    final c = concert;
    if (c == null) return;
    if (!c.verified || c.token.isEmpty) {
      await _verifyInvite();
      return;
    }
    try {
      final b = await Api.call('refresh', {'member_token': c.token, 'fcm_token': await Online.i.fcmToken() ?? '', 'app_version': appVersion});
      await s.concerts.record(c.slug).put(s.db, b);
      concert = Concert(b);
      // roster bisa bertambah (DM baru) dan kunci bisa berganti (epoch naik): bangun ulang keduanya
      await _setupKeys();
      await Online.i.attach(concert!);
      await Mesh.i.setNames(_names());
      await _syncReports();
      notifyListeners();
    } on ApiError catch (e) {
      if (e.isAuth) {
        lastError = e.message;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('refresh gagal: $e');
    }
  }

  String? lastError;

  Future<void> _verifyInvite() async {
    final code = await s.get<String>('code_$slug');
    if (code == null) return;
    try {
      await join(kode: code, nama: me.name, car: (await s.get<String>('car_$slug')) ?? me.car);
    } on ApiError catch (e) {
      if (!e.isNetwork) {
        lastError = e.message;
        notifyListeners();
      }
    }
  }

  Future<void> switchTo(String slugTo) async {
    final b = await s.concerts.record(slugTo).get(s.db);
    if (b == null) return;
    await s.put('active', slugTo);
    await _activate(Concert(Map<String, dynamic>.from(b)));
  }

  /// Keluar dari konser: hapus semua data lokal konser itu.
  Future<void> leave() async {
    final sl = slug;
    if (sl.isEmpty) return;
    await _teardown();
    final f = Finder(filter: Filter.equals('slug', sl));
    for (final st in [s.messages, s.outbox, s.anns, s.rollcalls, s.fleet, s.checkins, s.sos, s.locations, s.reports]) {
      await st.delete(s.db, finder: f);
    }
    await s.concerts.record(sl).delete(s.db);
    for (final k in ['active', 'code_$sl', 'car_$sl', 'extra_$sl', 'my_sos_$sl', 'online_since_$sl']) {
      await s.put(k, null);
    }
    _extraRoster.clear();
    mySosId = null;
    concert = null;
    unawaited(Online.i.syncTopics(const []));
    notifyListeners();
  }

  /// Lepas konser aktif (data tetap tersimpan) supaya layar Gabung tampil untuk konser lain.
  Future<void> detachForNewJoin() async {
    await _teardown();
    concert = null;
    await s.put('active', null);
    notifyListeners();
  }

  Map<String, String> _names() => {for (final m in roster) m.id: m.name};

  /// member_id saya di semua konser tersimpan, dibaca handler push latar (main.dart) supaya push dari diri sendiri diabaikan.
  Future<void> _writeMyIds() async {
    if (kIsWeb) return;
    try {
      final ids = [
        for (final b in await savedConcerts()) '${(b['member'] as Map?)?['mid'] ?? ''}',
      ]..removeWhere((e) => e.isEmpty);
      await writeMyIdsFile(ids);
    } catch (_) {}
  }

  Future<void> _setupKeys() async {
    final c = concert!;
    _cid = await concertCid(c.slug);
    _groupKey = SecretKey(base64Decode(c.groupKey));
    _chByHash.clear();
    final ids = <String>{'g', 'k', for (final a in c.areas) 'a:$a', for (final m in roster) if (m.id != c.me.id) dmChannel(c.me.id, m.id)};
    for (final id in ids) {
      _chByHash[hex(await channelHash(c.slug, id))] = id;
    }
  }

  /// stopMesh=false saat mengaktifkan konser: service mesh tetap hidup (MeshService sendiri mengganti konser kalau cid berubah),
  /// supaya relay untuk HP lain tidak putus setiap app dibuka.
  Future<void> _teardown({bool stopMesh = true}) async {
    for (final sub in _subs.skip(1)) {
      await sub.cancel();
    }
    if (_subs.length > 1) _subs.removeRange(1, _subs.length);
    _tick?.cancel();
    _helloTimer?.cancel();
    _refreshTimer?.cancel();
    _sosTimer?.cancel();
    try {
      await Online.i.detach();
    } catch (_) {}
    if (stopMesh) {
      try {
        await Mesh.i.stop();
      } catch (_) {}
    }
    LocationSvc.i.stop();
  }

  Future<void> _activate(Concert c) async {
    await _teardown(stopMesh: false);
    concert = c;
    final extra = await s.get<String>('extra_${c.slug}');
    _extraRoster
      ..clear()
      ..addAll(extra == null ? {} : (jsonDecode(extra) as Map).map((k, v) => MapEntry('$k', (v as Map).cast<String, dynamic>())));
    await _setupKeys();
    presence.clear();
    unawaited(_writeMyIds());
    fleetCache.clear();
    for (final r in await s.fleet.find(s.db, finder: Finder(filter: Filter.equals('slug', c.slug)))) {
      fleetCache['${r.value['car']}|${r.value['leg']}'] = ('${r.value['st']}', (r.value['at'] as num?)?.toInt() ?? 0);
    }
    // SOS saya yang masih aktif sebelum app ditutup: lanjutkan kirim ulang berkala
    mySosId = await s.get<String>('my_sos_${c.slug}');
    if (mySosId != null) {
      final rec = await s.sos.record(mySosId!).get(s.db);
      if (rec?['active'] == true) {
        LocationSvc.i.setSosMode(true);
        _sosTimer = Timer.periodic(const Duration(seconds: 30), (_) => _sosUpdate());
      } else {
        mySosId = null;
      }
    }
    await Notifier.i.init(onTap: (payload) => pendingRoute.value = payload);

    _subs.add(Online.i.envelopes.listen((b) => receive(b, 'online')));
    _subs.add(Online.i.connection.listen((up) {
      if (up) _flushOutbox();
      notifyListeners();
    }));
    _subs.add(Online.i.consoleAnnouncements.listen(_onConsoleAnn));
    _subs.add(Online.i.presence.listen((e) {
      final old = presence[e.key];
      presence[e.key] = e.value;
      if (old?.$1 != e.value.$1) notifyListeners();
    }));
    _subs.add(Online.i.locations.listen((e) {
      if (e.key != me.id) _applyLoc(e.value, e.key);
    }));
    _subs.add(Mesh.i.envelopes.listen((e) => receive(e.$1, e.$2)));
    _subs.add(Mesh.i.peerStream.listen((_) {
      _flushOutbox();
      notifyListeners();
    }));
    _subs.add(Bridge.i.envelopes.listen((b) => receive(b, 'bridge')));
    _subs.add(Bridge.i.state.listen((_) {
      _flushOutbox();
      notifyListeners();
    }));

    if (Mesh.i.supported) {
      await Mesh.i.start(cidHex: hex(_cid), memberId: c.me.id, concertName: c.name, names: _names());
      await _drainMesh();
    }
    unawaited(Online.i.attach(c).then((_) => notifyListeners()));
    _tick = Timer.periodic(const Duration(seconds: 4), (_) => _flushOutbox());
    _helloTimer = Timer.periodic(const Duration(minutes: 15), (_) => _hello());
    // data tim jarang berubah & pesan realtime lewat Firebase: refresh ke GAS cukup tiap 2 jam (hemat kuota akun Google)
    _refreshTimer = Timer.periodic(const Duration(hours: 2), (_) {
      if (netUp) refresh();
    });
    Future.delayed(const Duration(seconds: 3), _hello);
    await _countQueue();
    LocationSvc.i.start(onFix: (fix) => sendLocation(fix));
    _pruneOld();
    notifyListeners();
    if (netUp && !kIsWeb) {
      unawaited(refresh());
      unawaited(Updater.i.check());
    }
    if (netUp && kIsWeb && !Bridge.i.connected) unawaited(refresh());
  }

  void _onNetworkBack() {
    unawaited(Updater.i.check());
    if (concert == null) return;
    refresh();
    _flushOutbox();
  }

  Future<void> _drainMesh() async {
    for (final b in await Mesh.i.drainInbox()) {
      await receive(b, 'ble');
    }
  }

  /// Rute yang diminta dari notifikasi (dibaca HomeShell).
  final pendingRoute = ValueNotifier<String?>(null);

  Future<void> _pruneOld() async {
    final limit = DateTime.now().subtract(const Duration(days: 14)).millisecondsSinceEpoch;
    await s.messages.delete(s.db, finder: Finder(filter: Filter.lessThan('ts', limit)));
    final seenLimit = DateTime.now().subtract(const Duration(days: 2)).millisecondsSinceEpoch;
    await s.seen.delete(s.db, finder: Finder(filter: Filter.lessThan('t', seenLimit)));
  }

  // ----------------------------------------------------------- kirim

  Future<SecretKey?> keyFor(String channel) async {
    if (!channel.startsWith('d:')) return _groupKey;
    final parts = channel.split(':');
    final peerId = parts[1] == me.id ? parts[2] : parts[1];
    final p = member(peerId);
    if (p == null || p.pubX.isEmpty) return null;
    return keys.dmKey(base64Decode(p.pubX));
  }

  /// Bangun + simpan ke outbox + kirim ke semua jalur yang ada. Mengembalikan id hex.
  /// [meshOnly] = hanya disiarkan ke HP sekitar (tidak ke server, tidak masuk outbox, tanpa push).
  Future<String> _send(int type, String channel, Map<String, dynamic> payload, {int prio = Prio.normal, int? ttl, bool meshOnly = false}) async {
    final key = await keyFor(channel);
    if (key == null) throw StateError('Kunci lawan bicara belum ada. Tunggu dia online sekali.');
    final idb = newIdBytes();
    final env = await buildEnvelope(
      keys: keys,
      type: type,
      prio: prio,
      id: idb,
      cid: _cid,
      ch: await channelHash(slug, channel),
      from: me.id,
      payload: {...payload, 'ch': channel, 'fn': me.name},
      key: key,
      dm: channel.startsWith('d:'),
      ttl: ttl,
    );
    final id = hex(idb);
    _markSeen(id);
    final bytes = env.encode();
    if (meshOnly) {
      if (Mesh.i.running) await Mesh.i.send(bytes);
      return id;
    }
    // lokasi tidak masuk outbox (basi kalau terlambat)
    if (type != EType.loc) {
      await s.outbox.record(id).put(s.db, {
        'slug': slug,
        'env': base64Encode(bytes),
        'online': false,
        'mesh': false,
        'bridge': false,
        'at': env.ts,
        'type': type,
        'ch': channel,
        'prio': prio,
      });
    }
    await _dispatch(id, bytes, outboxed: type != EType.loc, meta: {'type': type, 'ch': channel, 'prio': prio, 'id': id});
    return id;
  }

  /// [meta] dipakai untuk minta push FCM ke server begitu pesan berhasil masuk server.
  Future<void> _dispatch(String id, Uint8List bytes, {bool outboxed = true, Map<String, Object?>? meta}) async {
    var online = false, mesh = false, bridge = false;
    // lokasi tidak ditulis ke aliran pesan server (terlalu sering); jalur online-nya lewat presence (sendLocation)
    final isLoc = meta?['type'] == EType.loc;
    if (Online.i.connected && !isLoc) {
      online = await Online.i.push(id, bytes, me.id);
      if (online && meta != null) _notifyServer(meta);
    }
    if (Mesh.i.running) {
      await Mesh.i.send(bytes);
      mesh = true;
    }
    if (Bridge.i.approved) {
      Bridge.i.send(bytes);
      bridge = true;
    }
    if (!outboxed) return;
    await _afterSend(id, online: online, mesh: mesh, bridge: bridge);
  }

  Future<void> _afterSend(String id, {required bool online, required bool mesh, required bool bridge}) async {
    final rec = s.outbox.record(id);
    final cur = await rec.get(s.db);
    if (cur == null) return;
    final next = {
      ...cur,
      'online': cur['online'] == true || online,
      'mesh': cur['mesh'] == true || mesh,
      'bridge': cur['bridge'] == true || bridge,
    };
    final any = next['online'] == true || next['mesh'] == true || next['bridge'] == true;
    // Selesai kalau sudah masuk server, atau tidak ada server sama sekali dan sudah diserahkan ke mesh/jembatan.
    final done = next['online'] == true || (!Online.i.ready && any && DateTime.now().millisecondsSinceEpoch - (cur['at'] as int) > 3600000);
    if (done) {
      await rec.delete(s.db);
    } else {
      await rec.put(s.db, next);
    }
    if (any) {
      final m = s.messages.record(id);
      final msg = await m.get(s.db);
      if (msg != null && msg['out'] == 'antre') {
        await m.put(s.db, {...msg, 'out': 'terkirim', 'path': next['online'] == true ? 'online' : (next['bridge'] == true ? 'bridge' : 'mesh')});
      } else if (msg != null && next['online'] == true && msg['path'] != 'online') {
        await m.put(s.db, {...msg, 'path': 'online'});
      }
    }
    await _countQueue();
  }

  bool _flushing = false;
  Future<void> _flushOutbox() async {
    if (_flushing || concert == null) return;
    _flushing = true;
    try {
      final recs = await s.outbox.find(s.db, finder: Finder(filter: Filter.equals('slug', slug), sortOrders: [SortOrder('at')]));
      for (final r in recs) {
        final v = r.value;
        final bytes = base64Decode(v['env'] as String);
        var online = false, mesh = false, bridge = false;
        if (v['online'] != true && Online.i.connected) {
          online = await Online.i.push(r.key, bytes, me.id);
          if (online) _notifyServer({...v, 'id': r.key});
        }
        if (v['mesh'] != true && Mesh.i.running) {
          await Mesh.i.send(bytes);
          mesh = true;
        }
        if (v['bridge'] != true && Bridge.i.approved) {
          Bridge.i.send(bytes);
          bridge = true;
        }
        if (online || mesh || bridge) await _afterSend(r.key, online: online, mesh: mesh, bridge: bridge);
      }
    } finally {
      _flushing = false;
    }
    if (netUp) unawaited(_syncReports());
  }

  /// Minta GAS mengirim push FCM untuk pesan yang baru masuk server (kalau Firebase aktif).
  /// Hemat kuota GAS (dibagi dengan form registrasi di akun yang sama): chat biasa paling banyak
  /// 1 permintaan per channel per 15 detik (pesan beruntun digabung); SOS, pengumuman, absen, kendala langsung.
  final _notifyQueue = <String, List<String>>{};
  final _lastNotify = <String, int>{};
  final _notifyTimers = <String, Timer>{};
  static const _notifyGapMs = 15000;

  void _notifyServer(Map v) {
    final type = v['type'] as int? ?? 0;
    final prio = (v['prio'] as num?)?.toInt() ?? 0;
    // tidak perlu push: lokasi, tanda terima, profil, check-in penumpang, status armada biasa (bukan kendala)
    if (type == EType.loc || type == EType.ack || type == EType.control || type == EType.checkin) return;
    if (type == EType.fleet && prio < Prio.high) return;
    final ch = '${v['ch']}';
    final key = '$ch|$prio|$type';
    (_notifyQueue[key] ??= []).add('${v['id'] ?? v['at']}');
    final urgent = prio >= Prio.high || type == EType.sos || type == EType.ann || type == EType.rollcall;
    final now = DateTime.now().millisecondsSinceEpoch;
    final wait = urgent ? 1500 : max(1500, _notifyGapMs - (now - (_lastNotify[key] ?? 0)));
    if (_notifyTimers[key] != null) return; // sudah dijadwalkan: pesan ini ikut digabung
    _notifyTimers[key] = Timer(Duration(milliseconds: wait), () async {
      _notifyTimers.remove(key);
      final ids = _notifyQueue.remove(key) ?? const [];
      if (ids.isEmpty || concert == null) return;
      _lastNotify[key] = DateTime.now().millisecondsSinceEpoch;
      final kind = switch (type) { EType.sos => 'sos', EType.ann => 'ann', EType.rollcall => 'rollcall', EType.fleet => 'fleet', _ => 'msg' };
      try {
        await Api.call('notify', {'member_token': concert!.token, 'ch': ch, 'prio': prio, 'kind': kind, 'msg_ids': ids.take(20).toList()});
      } catch (_) {}
    });
  }

  Future<void> _countQueue() async {
    queued = await s.outbox.count(s.db, filter: Filter.equals('slug', slug));
    notifyListeners();
  }

  Future<void> _saveMessage(String id, Map<String, dynamic> m) => s.messages.record(id).put(s.db, m);

  // ---- API kirim untuk UI

  /// [tags] = member_id -> label yang ditulis di pesan (mis. "Mobil 3"). Yang di-tag dapat notifikasi khusus.
  Future<void> sendText(String channel, String text, {String? replyTo, Map<String, String> tags = const {}}) async {
    final t = text.trim();
    if (t.isEmpty) return;
    final used = {for (final e in tags.entries) if (t.contains('@${e.value}')) e.key: e.value};
    final payload = <String, dynamic>{
      'k': 'text',
      'text': t,
      'reply': ?replyTo,
      if (used.isNotEmpty) 'tags': used.keys.toList(),
      if (used.isNotEmpty) 'tl': used.values.toList(),
    };
    final id = await _sendChat(channel, payload);
    _countQueue();
    debugPrint('kirim $id');
  }

  Future<String> _sendChat(String channel, Map<String, dynamic> payload) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    // Simpan dulu (status antre) supaya muncul instan; id baru diketahui setelah envelope dibuat,
    // jadi envelope dibangun dulu lalu pesan disimpan sebelum dispatch selesai.
    final key = await keyFor(channel);
    if (key == null) throw StateError('Kunci lawan bicara belum ada. Tunggu dia online sekali.');
    final idb = newIdBytes();
    final id = hex(idb);
    await _saveMessage(id, {
      'slug': slug,
      'ch': channel,
      'from': me.id,
      'fn': me.name,
      'type': EType.chat,
      ...payload,
      'ts': now,
      'out': 'antre',
      'path': '',
      'mine': true,
    });
    final env = await buildEnvelope(
      keys: keys,
      type: EType.chat,
      prio: Prio.normal,
      id: idb,
      cid: _cid,
      ch: await channelHash(slug, channel),
      from: me.id,
      payload: {...payload, 'ch': channel, 'fn': me.name, 'fr': me.roleLabel},
      key: key,
      dm: channel.startsWith('d:'),
    );
    _markSeen(id);
    final bytes = env.encode();
    await s.outbox.record(id).put(s.db, {'slug': slug, 'env': base64Encode(bytes), 'online': false, 'mesh': false, 'bridge': false, 'at': env.ts, 'type': EType.chat, 'ch': channel, 'prio': 0});
    await _dispatch(id, bytes, meta: {'type': EType.chat, 'ch': channel, 'prio': 0, 'id': id});
    return id;
  }

  /// Pesan cepat (S11). fleetStatus != null juga memperbarui status armada mobil saya.
  Future<void> sendQuick(String channel, String code, String text, {String? fleetStatus}) async {
    await _sendChat(channel, {'k': 'quick', 'code': code, 'text': text});
    if (fleetStatus != null && me.isDriver && me.car.isNotEmpty) {
      await sendFleet(me.car, currentLeg(), fleetStatus);
    }
  }

  Future<void> sendMedia(String channel, Map<String, dynamic> media, {String text = ''}) =>
      _sendChat(channel, {'k': 'media', 'text': text, 'media': media});

  /// Status armada (PRD §8.5). Disimpan lokal + laporan GAS + cermin RTDB untuk Console.
  Future<void> sendFleet(String car, String leg, String status, {String note = ''}) async {
    final fix = LocationSvc.i.last;
    final eid = newId();
    final now = DateTime.now().millisecondsSinceEpoch;
    final p = {'car': car, 'leg': leg, 'st': status, 'note': note, 'eid': eid, 'at': now, 'lat': fix?.lat, 'lng': fix?.lng, 'by': me.id};
    await _applyFleet(p, me.id);
    await s.reports.record(eid).put(s.db, {'slug': slug, 'kind': 'fleet', 'event_id': eid, ...p, 'at_iso': DateTime.now().toIso8601String()});
    await _send(EType.fleet, me.isDriver && me.area.isNotEmpty ? 'a:${me.area}' : 'g', p, prio: status == 'kendala' ? Prio.high : Prio.normal);
    Online.i.mirror('fleet/${car}_$leg', {'st': status, 'note': note, 'by': me.id, 'name': me.name, 'at': now, 'lat': fix?.lat, 'lng': fix?.lng});
  }

  Future<void> sendCheckin(ManifestRow r, String leg, String status) async {
    final eid = newId();
    final now = DateTime.now().millisecondsSinceEpoch;
    final p = {'order': r.orderId, 'hari': r.hari, 'leg': leg, 'st': status, 'car': r.car, 'eid': eid, 'at': now, 'by': me.id};
    await _applyCheckin(p);
    await s.reports.record(eid).put(s.db, {'slug': slug, 'kind': 'checkin', 'event_id': eid, ...p, 'at_iso': DateTime.now().toIso8601String()});
    await _send(EType.checkin, 'g', p);
  }

  Future<void> sendAnnouncement(String title, String body, {bool important = false}) async {
    final id = 'ann_${newId().substring(0, 16)}';
    final p = {'id': id, 'title': title, 'body': body, 'prio': important ? 1 : 0, 'at': DateTime.now().millisecondsSinceEpoch};
    await _applyAnn(p, me.id, me.name);
    await _send(EType.ann, 'g', p, prio: Prio.high);
  }

  Future<String> startRollcall() async {
    final id = 'rc_${newId().substring(0, 16)}';
    final p = {'op': 'start', 'id': id, 'at': DateTime.now().millisecondsSinceEpoch};
    await _applyRollcall(p, me.id);
    await _send(EType.rollcall, 'g', p, prio: Prio.high);
    return id;
  }

  Future<void> answerRollcall(String id, String ans) async {
    final p = {'op': 'answer', 'id': id, 'ans': ans, 'at': DateTime.now().millisecondsSinceEpoch};
    await _applyRollcall(p, me.id);
    await _send(EType.rollcall, 'g', p, prio: Prio.high);
  }

  Future<void> closeRollcall(String id) async {
    final p = {'op': 'close', 'id': id, 'at': DateTime.now().millisecondsSinceEpoch};
    await _applyRollcall(p, me.id);
    await _send(EType.rollcall, 'g', p);
  }

  String? mySosId;

  Future<void> startSos(String kind) async {
    final fix = LocationSvc.i.last ?? await LocationSvc.i.current();
    final bat = await _battery();
    final id = 'sos_${newId().substring(0, 16)}';
    mySosId = id;
    await s.put('my_sos_$slug', id);
    final p = {'op': 'start', 'id': id, 'kind': kind, 'lat': fix?.lat, 'lng': fix?.lng, 'acc': fix?.acc, 'bat': bat, 'at': DateTime.now().millisecondsSinceEpoch};
    await _applySos(p, me.id, me.name);
    await _send(EType.sos, 'g', p, prio: Prio.sos);
    LocationSvc.i.setSosMode(true);
    _sosTimer?.cancel();
    _sosTimer = Timer.periodic(const Duration(seconds: 30), (_) => _sosUpdate());
    Online.i.mirror('sos/$id', {'by': me.id, 'name': me.name, 'kind': kind, 'lat': fix?.lat, 'lng': fix?.lng, 'bat': bat, 'at': p['at'], 'active': true});
    notifyListeners();
  }

  Future<void> _sosUpdate() async {
    final id = mySosId;
    if (id == null) return;
    final rec = await s.sos.record(id).get(s.db);
    if (rec == null || rec['active'] != true) {
      _sosTimer?.cancel();
      return;
    }
    if (DateTime.now().millisecondsSinceEpoch - (rec['at'] as int) > 2 * 3600000) {
      await cancelSos(id);
      return;
    }
    final fix = LocationSvc.i.last;
    final p = {'op': 'update', 'id': id, 'kind': rec['kind'], 'lat': fix?.lat, 'lng': fix?.lng, 'acc': fix?.acc, 'bat': await _battery(), 'at': rec['at']};
    await _applySos(p, me.id, me.name);
    await _send(EType.sos, 'g', p, prio: Prio.sos);
  }

  Future<void> cancelSos(String id) async {
    final p = {'op': 'cancel', 'id': id, 'at': DateTime.now().millisecondsSinceEpoch};
    await _applySos(p, me.id, me.name);
    await _send(EType.sos, 'g', p, prio: Prio.sos);
    if (id == mySosId) {
      mySosId = null;
      _sosTimer?.cancel();
      LocationSvc.i.setSosMode(false);
      await s.put('my_sos_$slug', null);
    }
    Online.i.mirror('sos/$id', {'active': false, 'cancelled_by': me.id, 'cancelled_at': p['at']});
    notifyListeners();
  }

  Future<void> respondSos(String id) async {
    final fix = LocationSvc.i.last;
    final rec = await s.sos.record(id).get(s.db);
    double? dist;
    if (fix != null && rec?['lat'] != null) dist = distanceM(fix.lat, fix.lng, (rec!['lat'] as num).toDouble(), (rec['lng'] as num).toDouble());
    final p = {'op': 'respond', 'id': id, 'dist': dist?.round(), 'at': DateTime.now().millisecondsSinceEpoch};
    await _applySos(p, me.id, me.name);
    await _send(EType.sos, 'g', p, prio: Prio.sos);
  }

  Future<void> sendLocation(Fix fix) async {
    if (concert == null) return;
    final bat = await _battery();
    await _applyLoc({'lat': fix.lat, 'lng': fix.lng, 'acc': fix.acc, 'bat': bat, 'at': DateTime.now().millisecondsSinceEpoch}, me.id);
    if (await s.get<bool>('share_loc') == false) return;
    await _send(EType.loc, 'g', {'lat': fix.lat, 'lng': fix.lng, 'acc': fix.acc, 'bat': bat});
    Online.i.presenceExtra({'bat': bat, 'path': link.name, 'lat': fix.lat, 'lng': fix.lng, 'acc': fix.acc, 'at': DateTime.now().millisecondsSinceEpoch});
  }

  Future<int?> _battery() async {
    try {
      return await Battery().batteryLevel;
    } catch (_) {
      return null;
    }
  }

  /// Pengumuman profil di mesh (supaya anggota baru/offline saling kenal tanpa server).
  Future<void> _hello() async {
    final c = concert;
    if (c == null || _groupKey == null) return;
    try {
      await _send(EType.control, 'g', {
        'op': 'hello',
        'mid': me.id,
        'n': me.name,
        'r': me.role,
        'car': me.car,
        'area': me.area,
        'px': keys.pubXb64,
        'pe': keys.pubEdB64,
      }, ttl: 3);
      await s.outbox.delete(s.db, finder: Finder(filter: Filter.equals('type', EType.control)));
    } catch (_) {}
  }

  /// Tandai pesan sudah dibaca saat channel dibuka (DM: envelope ack; grup: online acks).
  Future<void> markRead(String channel) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await s.put('read_${slug}_$channel', now);
    final recs = await s.messages.find(s.db,
        finder: Finder(filter: Filter.and([Filter.equals('slug', slug), Filter.equals('ch', channel), Filter.isNull('mine'), Filter.isNull('readSent')])));
    for (final r in recs) {
      await s.messages.record(r.key).put(s.db, {...r.value, 'readSent': true});
      _queueAck(channel, r.key, 'r');
    }
    notifyListeners();
  }

  void _queueAck(String channel, String id, String kind) {
    if (!channel.startsWith('d:')) {
      Online.i.ackGroup(id, me.id, kind);
      return;
    }
    (_ackBuffer['$channel|$kind'] ??= {}).add(id);
    _ackTimer ??= Timer(const Duration(seconds: 3), () async {
      _ackTimer = null;
      final buf = Map.of(_ackBuffer);
      _ackBuffer.clear();
      for (final e in buf.entries) {
        final p = e.key.split('|');
        try {
          await _send(EType.ack, p[0], {'ids': e.value.toList(), 'k': p[1]});
        } catch (_) {}
      }
    });
  }

  // ----------------------------------------------------------- terima

  void _markSeen(String id) {
    _seenMem.add(id);
    s.seen.record(id).put(s.db, {'t': DateTime.now().millisecondsSinceEpoch});
  }

  Future<bool> _isSeen(String id) async {
    if (_seenMem.contains(id)) return true;
    final hit = await s.seen.record(id).exists(s.db);
    if (hit) _seenMem.add(id);
    return hit;
  }

  Future<void> receive(Uint8List bytes, String via) async {
    final c = concert;
    if (c == null || _groupKey == null) return;
    final env = Envelope.decode(bytes);
    if (env == null || !listEquals(env.cid, _cid)) return;
    final id = env.idHex;
    if (await _isSeen(id)) return;
    _markSeen(id);

    // Gateway: pesan dari mesh/jembatan diteruskan ke server; pesan dari server diteruskan ke mesh/jembatan.
    if (via != 'online' && Online.i.connected && env.type != EType.loc) {
      unawaited(Online.i.push(id, bytes, env.from));
    }
    if (via == 'online') {
      if (Mesh.i.running) unawaited(Mesh.i.send(bytes));
      if (Bridge.i.approved) Bridge.i.send(bytes);
    }
    if (via == 'bridge' && Mesh.i.running) {
      // Host Android: Kotlin sudah meneruskan ke BLE & klien lain; di web tidak ada mesh.
    }

    final chHex = hex(env.ch);
    var channel = _chByHash[chHex];
    if (env.isDm && channel == null) return; // DM orang lain: cukup diteruskan (sudah oleh router Kotlin)
    final sender = member(env.from);
    SecretKey? key;
    if (env.isDm) {
      if (sender == null || sender.pubX.isEmpty) return;
      key = await keys.dmKey(base64Decode(sender.pubX));
    } else {
      key = _groupKey;
    }
    final p = await openBody(env.body, key!, env.aad);
    if (p == null) return;
    var verified = false;
    if (sender != null && sender.pubEd.isNotEmpty) {
      verified = await DeviceKeys.verify(env.signedBytes, env.sig, base64Decode(sender.pubEd));
      if (!verified) return; // tanda tangan palsu: buang
    } else if (env.type == EType.control && p['op'] == 'hello' && p['pe'] is String) {
      verified = await DeviceKeys.verify(env.signedBytes, env.sig, base64Decode(p['pe'] as String));
      if (!verified) return;
    }
    channel ??= '${p['ch'] ?? 'g'}';
    final fromName = sender?.name ?? '${p['fn'] ?? 'Anggota'}';

    switch (env.type) {
      case EType.chat:
        await _onChat(id, env, p, channel, fromName, via, verified);
      case EType.ack:
        await _onAck(p, env.from);
      case EType.loc:
        await _applyLoc({...p, 'at': env.ts}, env.from);
      case EType.fleet:
        await _applyFleet(p, env.from);
        if (p['st'] == 'kendala' && me.isKoord) {
          Notifier.i.show(title: '${carName('${p['car']}')} kendala', body: '${p['note'] ?? ''}', route: 'fleet');
        }
        if (me.isKoord && netUp) {
          await s.reports.record('${p['eid']}').put(s.db, {'slug': slug, 'kind': 'fleet', 'event_id': p['eid'], ...p, 'at_iso': DateTime.fromMillisecondsSinceEpoch((p['at'] as num?)?.toInt() ?? env.ts).toIso8601String()});
        }
      case EType.ann:
        await _applyAnn(p, env.from, fromName);
        _queueAckGroupItem(p['id'] as String?, 'd');
        Notifier.i.show(title: 'Pengumuman: ${p['title']}', body: '${p['body'] ?? ''}', route: 'info', important: true);
      case EType.rollcall:
        await _applyRollcall(p, env.from);
        if (p['op'] == 'start') {
          Notifier.i.show(title: 'Absen dari $fromName', body: 'Tandai kondisimu: Aman atau Butuh bantuan', route: 'info', important: true);
        }
      case EType.sos:
        await _applySos(p, env.from, fromName);
        if (p['op'] == 'start') {
          Notifier.i.sos(title: 'SOS ${_sosKind(p['kind'])} — $fromName', body: 'Buka untuk melihat arah & jarak', route: 'sos:${p['id']}');
        } else if (p['op'] == 'cancel') {
          Notifier.i.cancelSos();
        }
      case EType.checkin:
        await _applyCheckin(p);
        if (me.isKoord && netUp) {
          await s.reports.record('${p['eid']}').put(s.db, {'slug': slug, 'kind': 'checkin', 'event_id': p['eid'], ...p, 'at_iso': DateTime.fromMillisecondsSinceEpoch((p['at'] as num?)?.toInt() ?? env.ts).toIso8601String()});
        }
      case EType.control:
        await _onControl(p, env.from);
    }
    notifyListeners();
  }

  void _queueAckGroupItem(String? id, String kind) {
    if (id == null) return;
    (_ackBuffer['g|$kind'] ??= {}).add(id);
    _ackTimer ??= Timer(const Duration(seconds: 3), () async {
      _ackTimer = null;
      final buf = Map.of(_ackBuffer);
      _ackBuffer.clear();
      for (final e in buf.entries) {
        final parts = e.key.split('|');
        try {
          await _send(EType.ack, parts[0], {'ids': e.value.toList(), 'k': parts[1]});
        } catch (_) {}
      }
    });
  }

  Future<void> _onChat(String id, Envelope env, Map<String, dynamic> p, String channel, String fromName, String via, bool verified) async {
    await _saveMessage(id, {
      'slug': slug,
      'ch': channel,
      'from': env.from,
      'fn': fromName,
      'fr': p['fr'],
      'type': EType.chat,
      'k': p['k'] ?? 'text',
      'text': p['text'] ?? '',
      'code': p['code'],
      'reply': p['reply'],
      'media': p['media'],
      'tags': p['tags'],
      'tl': p['tl'],
      'ts': env.ts,
      'recv': DateTime.now().millisecondsSinceEpoch,
      'path': via,
      'verified': verified,
    });
    _queueAck(channel, id, 'd');
    final viewing = _foreground && openChannel == channel;
    if (viewing) {
      _queueAck(channel, id, 'r');
      await s.messages.record(id).update(s.db, {'readSent': true});
    } else if (((p['tags'] as List?) ?? const []).contains(me.id)) {
      Notifier.i.show(title: '$fromName menyebut kamu · ${channelById(channel).title}', body: '${p['text'] ?? ''}', route: 'chat:$channel', important: true);
    } else if (await s.get<bool>('mute_${slug}_$channel') != true) {
      final title = channel.startsWith('d:') ? fromName : '$fromName · ${channelById(channel).title}';
      final media = p['media'] as Map?;
      Notifier.i.show(title: title, body: media != null ? (media['kind'] == 'audio' ? 'Voice note' : 'Foto') : '${p['text'] ?? ''}', route: 'chat:$channel');
    }
    final media = p['media'] as Map?;
    if (media != null && media['ptt'] == true && _foreground && await s.get<bool>('walkie_${slug}_$channel') == true) {
      pttIncoming.value = {'id': id, 'from': fromName, 'media': media, 'ch': channel};
    }
  }

  /// Voice push-to-talk yang perlu diputar otomatis (didengar layar aktif).
  final pttIncoming = ValueNotifier<Map?>(null);

  Future<void> _onAck(Map<String, dynamic> p, String from) async {
    final ids = ((p['ids'] as List?) ?? const []).map((e) => '$e');
    final kind = p['k'] == 'r' ? 'read' : 'dlv';
    for (final id in ids) {
      final m = await s.messages.record(id).get(s.db);
      if (m != null) {
        final map = Map<String, dynamic>.from((m[kind] as Map?) ?? {});
        map[from] = DateTime.now().millisecondsSinceEpoch;
        await s.messages.record(id).put(s.db, {...m, kind: map});
        continue;
      }
      final a = await s.anns.record(id).get(s.db);
      if (a != null) {
        final map = Map<String, dynamic>.from((a[kind] as Map?) ?? {});
        map[from] = DateTime.now().millisecondsSinceEpoch;
        await s.anns.record(id).put(s.db, {...a, kind: map});
      }
    }
  }

  Future<void> _onControl(Map<String, dynamic> p, String from) async {
    if (p['op'] != 'hello') return;
    final mid = '${p['mid']}';
    if (mid != from || concert!.member(mid) != null) return;
    _extraRoster[mid] = {'mid': mid, 'n': p['n'], 'r': p['r'], 'car': p['car'] ?? '', 'area': p['area'] ?? '', 'px': p['px'], 'pe': p['pe'], 'st': 'aktif', 'mesh': true};
    await s.put('extra_$slug', jsonEncode(_extraRoster));
    _chByHash[hex(await channelHash(slug, dmChannel(me.id, mid)))] = dmChannel(me.id, mid);
    await Mesh.i.setNames(_names());
  }

  void _onConsoleAnn(Map<String, dynamic> a) async {
    final id = '${a['id']}';
    if (await s.anns.record(id).exists(s.db)) return;
    await _applyAnn({'id': id, 'title': a['title'], 'body': a['body'], 'prio': a['prio'], 'at': a['at']}, 'console', '${a['by'] ?? 'Console'}');
    Notifier.i.show(title: 'Pengumuman: ${a['title']}', body: '${a['body'] ?? ''}', route: 'info', important: true);
    // teruskan ke mesh supaya anggota offline ikut menerima (ditandatangani ulang oleh HP ini)
    try {
      await _send(EType.ann, 'g', {'id': id, 'title': a['title'], 'body': a['body'], 'prio': a['prio'], 'at': a['at'], 'via': 'console', 'by': a['by']},
          prio: Prio.high, meshOnly: true);
    } catch (_) {}
    notifyListeners();
  }

  // ----------------------------------------------------------- terapkan state

  Future<void> _applyAnn(Map<String, dynamic> p, String from, String fromName) async {
    final id = '${p['id']}';
    final cur = await s.anns.record(id).get(s.db);
    if (cur != null) return;
    await s.anns.record(id).put(s.db, {
      'slug': slug,
      'id': id,
      'title': p['title'],
      'body': p['body'],
      'prio': p['prio'] ?? 0,
      'by': p['via'] == 'console' ? 'console' : from,
      'byName': p['via'] == 'console' ? (p['by'] ?? 'Console') : fromName,
      'at': p['at'] ?? DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> _applyRollcall(Map<String, dynamic> p, String from) async {
    final id = '${p['id']}';
    final rec = s.rollcalls.record(id);
    final cur = Map<String, dynamic>.from(await rec.get(s.db) ?? {'slug': slug, 'id': id, 'answers': {}});
    switch (p['op']) {
      case 'start':
        cur['by'] = from;
        cur['at'] = p['at'];
      case 'answer':
        final ans = Map<String, dynamic>.from((cur['answers'] as Map?) ?? {});
        ans[from] = {'ans': p['ans'], 'at': p['at']};
        cur['answers'] = ans;
      case 'close':
        cur['closed'] = p['at'];
    }
    cur['at'] ??= p['at'];
    await rec.put(s.db, cur);
  }

  Future<void> _applySos(Map<String, dynamic> p, String from, String fromName) async {
    final id = '${p['id']}';
    final rec = s.sos.record(id);
    final cur = Map<String, dynamic>.from(await rec.get(s.db) ?? {'slug': slug, 'id': id, 'responders': {}});
    switch (p['op']) {
      case 'start':
      case 'update':
        if (cur['cancelled'] != null) return;
        cur.addAll({'from': from, 'fn': fromName, 'kind': p['kind'], 'lat': p['lat'], 'lng': p['lng'], 'acc': p['acc'], 'bat': p['bat'], 'at': p['at'], 'active': true, 'upd': DateTime.now().millisecondsSinceEpoch});
      case 'respond':
        final r = Map<String, dynamic>.from((cur['responders'] as Map?) ?? {});
        r[from] = {'at': p['at'], 'dist': p['dist'], 'fn': fromName};
        cur['responders'] = r;
      case 'cancel':
        cur['active'] = false;
        cur['cancelled'] = p['at'];
        cur['cancelledBy'] = from;
    }
    await rec.put(s.db, cur);
  }

  Future<void> _applyFleet(Map<String, dynamic> p, String from) async {
    final key = '$slug|${p['car']}|${p['leg']}';
    final rec = s.fleet.record(key);
    final cur = await rec.get(s.db);
    final at = (p['at'] as num?)?.toInt() ?? 0;
    if (cur != null && ((cur['at'] as num?)?.toInt() ?? 0) > at) return;
    await rec.put(s.db, {'slug': slug, 'car': '${p['car']}', 'leg': p['leg'], 'st': p['st'], 'note': p['note'] ?? '', 'at': at, 'by': from, 'lat': p['lat'], 'lng': p['lng'], 'prev': cur?['st']});
    fleetCache['${p['car']}|${p['leg']}'] = ('${p['st']}', at);
  }

  Future<void> _applyCheckin(Map<String, dynamic> p) async {
    final key = '$slug|${p['order']}|${p['hari']}|${p['leg']}';
    final rec = s.checkins.record(key);
    final cur = await rec.get(s.db);
    final at = (p['at'] as num?)?.toInt() ?? 0;
    if (cur != null && ((cur['at'] as num?)?.toInt() ?? 0) > at) return;
    await rec.put(s.db, {'slug': slug, 'order': p['order'], 'hari': p['hari'], 'leg': p['leg'], 'st': p['st'], 'car': p['car'], 'at': at, 'by': p['by']});
  }

  Future<void> _applyLoc(Map<String, dynamic> p, String from) async {
    if (p['lat'] == null) return;
    await s.locations.record('$slug|$from').put(s.db, {'slug': slug, 'mid': from, 'lat': p['lat'], 'lng': p['lng'], 'acc': p['acc'], 'bat': p['bat'], 'at': p['at'] ?? DateTime.now().millisecondsSinceEpoch});
  }

  /// Kirim laporan armada & check-in ke sheet (GAS). Pengirim asli + koordinator yang online.
  bool _syncing = false;
  Future<void> _syncReports() async {
    final c = concert;
    if (_syncing || c == null || c.token.isEmpty) return;
    final recs = await s.reports.find(s.db, finder: Finder(filter: Filter.equals('slug', slug), limit: 300));
    if (recs.isEmpty) return;
    _syncing = true;
    try {
      final fleet = <Map>[], chk = <Map>[];
      for (final r in recs) {
        final v = r.value;
        if (v['kind'] == 'fleet') {
          fleet.add({'event_id': v['event_id'], 'car': v['car'], 'leg': v['leg'], 'status': v['st'], 'note': v['note'], 'lat': v['lat'], 'lng': v['lng'], 'at': v['at_iso'], 'by': v['by']});
        } else {
          chk.add({'event_id': v['event_id'], 'order_id': v['order'], 'hari': v['hari'], 'leg': v['leg'], 'status': v['st'], 'car': v['car'], 'at': v['at_iso'], 'by': v['by']});
        }
      }
      final res = await Api.call('sync_reports', {'member_token': c.token, 'fleet': fleet, 'checkins': chk});
      for (final id in ((res['accepted_ids'] as List?) ?? const [])) {
        await s.reports.record('$id').delete(s.db);
      }
    } catch (_) {
      // dicoba lagi saat flush berikutnya
    } finally {
      _syncing = false;
    }
  }

  // ----------------------------------------------------------- query untuk UI

  Stream<List<RecordSnapshot<String, Map<String, Object?>>>> watchMessages(String channel) => s.messages
      .query(finder: Finder(filter: Filter.and([Filter.equals('slug', slug), Filter.equals('ch', channel)]), sortOrders: [SortOrder('ts', false)], limit: 400))
      .onSnapshots(s.db);

  Stream<List<RecordSnapshot<String, Map<String, Object?>>>> watchAllMessages() =>
      s.messages.query(finder: Finder(filter: Filter.equals('slug', slug), sortOrders: [SortOrder('ts', false)], limit: 1500)).onSnapshots(s.db);

  Stream<List<RecordSnapshot<String, Map<String, Object?>>>> watch(StoreRef<String, Map<String, Object?>> st, {String sort = 'at'}) =>
      st.query(finder: Finder(filter: Filter.equals('slug', slug), sortOrders: [SortOrder(sort, false)])).onSnapshots(s.db);

  Future<int> lastRead(String channel) async => (await s.get<int>('read_${slug}_$channel')) ?? 0;

  /// Status armada terakhir per "mobil|leg" -> (status, waktu ms). Cermin store fleet untuk keputusan cepat.
  final Map<String, (String, int)> fleetCache = {};

  static const legDone = {'tiba', 'selesai'};

  /// "Hari konser": dimulai jam 06.00, bukan 00.00. Pulang lewat tengah malam tetap ikut hari konser yang sama
  /// dengan pergi sorenya; mulai 06.00 status armada & manifest pindah ke hari konser berikutnya.
  static const dayStartHour = 6;
  static String concertDay([int? ms]) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms ?? DateTime.now().millisecondsSinceEpoch).subtract(const Duration(hours: dayStartHour));
    return '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }

  /// Status armada ini milik hari konser yang sedang berjalan?
  static bool isCurrent(num? at) => at != null && concertDay(at.toInt()) == concertDay();

  /// Leg pergi mobil ini (hari ini) sudah selesai (Tiba / Selesai)?
  bool pergiDone(String car) {
    final v = fleetCache['$car|pergi'];
    return v != null && legDone.contains(v.$1) && isCurrent(v.$2);
  }

  /// Leg aktif: selalu "pergi" dulu; "pulang" setelah leg pergi mobil itu Tiba/Selesai.
  String currentLeg([String? car]) {
    final c = car ?? me.car;
    return c.isNotEmpty && pergiDone(c) ? 'pulang' : 'pergi';
  }

  static String _sosKind(Object? k) => switch (k) { 'medis' => 'MEDIS', 'kendaraan' => 'KENDARAAN', 'keamanan' => 'KEAMANAN', _ => 'DARURAT' };
  static String sosKindLabel(Object? k) => _sosKind(k);

  /// QR undangan offline (PRD M1.3): berlaku 15 menit.
  Future<String> inviteQr() async {
    final c = concert!;
    final code = await s.get<String>('code_$slug');
    return jsonEncode({
      't': 'ct-invite',
      's': c.slug,
      'n': c.name,
      'v': c.venue,
      'd': c.dates,
      'e': c.epoch,
      'k': c.groupKey,
      'c': code,
      'r': me.role,
      'by': me.id,
      'x': DateTime.now().add(const Duration(minutes: 15)).millisecondsSinceEpoch,
    });
  }

  /// Bundle untuk klien web yang masuk lewat Mode Jembatan (dikirim host setelah disetujui).
  Map<String, dynamic> bridgeBundleFor(Map<String, dynamic> hello) {
    final c = concert!;
    return {
      'konser': c.b['konser'],
      'epoch': c.epoch,
      'group_key': c.groupKey,
      'member': {'mid': hello['mid'], 'n': hello['n'], 'r': hello['r'] ?? 'panitia', 'px': hello['px'], 'pe': hello['pe'], 'st': 'aktif', 'car': hello['car'] ?? '', 'area': hello['area'] ?? ''},
      'member_token': hello['token_known'] == true ? '' : '',
      'roster': [for (final m in roster) m.m],
      'manifest': {'enabled': false, 'rows': []},
      'unverified': c.member('${hello['mid']}') == null,
      'via_bridge': true,
    };
  }
}

/// Jarak Haversine dalam meter.
double distanceM(double lat1, double lng1, double lat2, double lng2) => haversine(lat1, lng1, lat2, lng2);
