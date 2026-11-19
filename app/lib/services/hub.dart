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

  /// Anggota yang keluar sendiri (member_id -> waktu keluar ms). Disembunyikan dari daftar, hitungan, dan radar.
  final Map<String, int> _left = {};

  /// Waktu hello terbaru per anggota (jam pengirim): bye yang lebih tua dari ini tidak menyembunyikan lagi.
  final Map<String, int> _helloAt = {};

  /// Sedang proses keluar: hello, lokasi, dan presence berhenti supaya tidak membatalkan tanda keluar sendiri.
  bool _leaving = false;
  bool get leaving => _leaving;

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
      for (final m in base)
        if (m.id == c.me.id || !_left.containsKey(m.id)) _withProfile(m),
      for (final e in _extraRoster.values)
        if (!ids.contains(e['mid']) && !_left.containsKey(e['mid'])) Member(e),
    ];
  }

  /// Profil terbaru dari hello anggota (nama, nomor mobil, area) yang lebih baru dari data server, mis. driver salah isi
  /// nomor mobil lalu menggantinya: HP lain langsung ikut tanpa menunggu refresh. Peran TIDAK ikut (tidak bisa mengaku koordinator).
  final Map<String, Map<String, dynamic>> _prof = {};

  Member _withProfile(Member m) {
    final p = _prof[m.id];
    if (p == null || m.id == concert?.me.id) return m;
    return Member({...m.m, 'n': p['n'] ?? m.name, 'car': p['car'] ?? m.car, 'cars': [if ('${p['car'] ?? ''}'.isNotEmpty) p['car']], 'area': p['area'] ?? m.area});
  }

  /// Hello anggota roster server: simpan profilnya kalau berubah DAN pengirim memegang data server yang lebih baru
  /// (st = server_time bundle pengirim, jam server). Hello basi dari HP yang belum refresh tidak menimpa perubahan admin.
  Future<void> _applyProfile(String mid, Map<String, dynamic> p) async {
    final c = concert;
    final base = c?.member(mid);
    if (c == null || base == null || mid == c.me.id) return;
    final st = (p['st'] as num?)?.toInt() ?? 0; // hello versi lama tanpa st: diabaikan
    final serverAt = (c.b['server_time'] as num?)?.toInt() ?? 0;
    if (st <= serverAt || st <= ((_prof[mid]?['st'] as num?)?.toInt() ?? 0)) return;
    final at = st;
    final n = '${p['n'] ?? ''}', car = '${p['car'] ?? ''}', area = '${p['area'] ?? ''}';
    if (n.isEmpty) return;
    final same = n == base.name && car == base.car && area == base.area;
    if (same) {
      if (_prof.remove(mid) == null) return;
    } else {
      _prof[mid] = {'n': n, 'car': car, 'area': area, 'st': at};
    }
    await s.put('prof_${c.slug}', jsonEncode(_prof));
    unawaited(Mesh.i.setNames(_names()));
    notifyListeners();
  }

  /// Data server baru (refresh/join): profil yang lebih tua dari server tidak dipakai lagi.
  void _pruneProfiles() {
    final st = (concert?.b['server_time'] as num?)?.toInt() ?? 0;
    _prof.removeWhere((_, v) => ((v['st'] as num?)?.toInt() ?? 0) <= st);
  }

  /// Driver salah isi nomor mobil: gabung ulang dengan kode yang sama (HP sama = anggota sama, server memperbarui mobilnya),
  /// lalu profil baru disebar lewat hello (internet + Bluetooth). Butuh internet.
  Future<void> changeCar(String car) async {
    final c = concert;
    if (c == null || !me.isDriver) return;
    final code = await s.get<String>('code_${c.slug}');
    if (code == null || code.isEmpty) throw ApiError('code', 'Kode konser tidak tersimpan. Keluar lalu gabung lagi pakai link / kode.');
    final old = me.car;
    final mine = await myCheckinsOnCar(old);
    await join(kode: code, nama: me.name, car: car, hp: me.hp);
    // centang penumpang yang terlanjur diisi di mobil yang salah dikosongkan (status 'batal' = belum), supaya driver & koordinator
    // mobil itu tidak mengira penumpangnya sudah naik
    for (final r in mine) {
      try {
        await sendCheckin(ManifestRow({'order_id': r['order'], 'hari': r['hari'], 'car': old}), '${r['leg']}', 'batal');
      } catch (_) {}
    }
  }

  /// Centang penumpang (hari konser ini) yang saya isi di mobil [car].
  Future<List<Map<String, Object?>>> myCheckinsOnCar(String car) async {
    final recs = await s.checkins.find(s.db,
        finder: Finder(filter: Filter.and([Filter.equals('slug', slug), Filter.equals('car', car), Filter.equals('by', me.id)])));
    return [
      for (final r in recs)
        if (isCurrent(r.value['at'] as num?) && '${r.value['st'] ?? ''}'.isNotEmpty && r.value['st'] != 'batal') r.value,
    ];
  }

  Member? member(String id) {
    for (final m in roster) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// Termasuk anggota yang disembunyikan (keluar): untuk kunci DM & verifikasi tanda tangan, bukan untuk tampilan.
  Member? _memberAny(String id) {
    final c = concert;
    if (c == null) return null;
    final m = c.member(id);
    if (m != null) return m;
    final e = _extraRoster[id];
    return e == null ? null : Member(e);
  }

  /// Mobil -> driver aktif (yang keluar tidak dihitung).
  Map<String, Member> get carsMap {
    final out = <String, Member>{};
    for (final m in roster) {
      if (!m.isDriver) continue;
      for (final car in (m.cars.isEmpty ? [m.car] : m.cars)) {
        if (car.isNotEmpty) out[car] = m;
      }
    }
    return out;
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
      return Channel(id, p?.displayName ?? 'Anggota', subtitle: p?.roleLabel ?? '', peer: p);
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
    if (netUp) unawaited(_flushPendingLeaves());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (concert != null) _pushNet();
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
    // keluar lalu langsung gabung lagi: tunggu pemberitahuan keluar yang sedang dikirim, supaya tidak tiba di server sesudah gabung
    for (var i = 0; _flushingLeaves && i < 60; i++) {
      await Future.delayed(const Duration(milliseconds: 250));
    }
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
    await _dropPendingLeave(c.slug);
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
    await _dropPendingLeave(slugQ);
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
      _pruneProfiles();
      await s.put('prof_${c.slug}', _prof.isEmpty ? null : jsonEncode(_prof));
      await _applyServerMembership();
      // roster bisa bertambah (DM baru) dan kunci bisa berganti (epoch naik): bangun ulang keduanya
      await _setupKeys();
      await Online.i.attach(concert!);
      await Mesh.i.setNames(_names());
      await _syncReports();
      notifyListeners();
      // refresh berhasil = internet sungguhan (bukan Wi-Fi tanpa internet): kirim pemberitahuan keluar yang tertunda
      unawaited(_flushPendingLeaves());
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

  /// Keluar dari konser: beri tahu server (admin melihat status "Keluar"), lalu hapus semua data lokal konser itu.
  /// Offline: pemberitahuan disimpan dan dikirim begitu ada internet (_flushPendingLeaves).
  /// Hasil: true kalau HP lain sempat dikabari (internet atau Bluetooth); false = mereka baru tahu setelah HP ini online.
  Future<bool> leave() async {
    final sl = slug;
    if (sl.isEmpty || _leaving) return false;
    _leaving = true;
    Online.i.leaving = true;
    try {
      return await _leave(sl);
    } catch (_) {
      // gagal di tengah jalan (mis. hapus data lokal): pulihkan konser supaya timer, lokasi & presence jalan lagi
      _leaving = false;
      Online.i.leaving = false;
      final c = concert;
      if (c != null) {
        try {
          await _activate(c);
        } catch (_) {}
      }
      rethrow;
    } finally {
      _leaving = false;
      Online.i.leaving = false;
    }
  }

  Future<bool> _leave(String sl) async {
    final token = concert!.token;
    final mid = me.id;
    final at = DateTime.now().millisecondsSinceEpoch;
    _helloTimer?.cancel();
    LocationSvc.i.stop();
    if (mySosId != null) {
      try {
        await cancelSos(mySosId!).timeout(const Duration(seconds: 8));
      } catch (_) {}
    }
    final reached = Online.i.connected || Mesh.i.peers.any((p) => p.connected);
    // kabari HP lain (internet + Bluetooth) supaya saya langsung hilang dari daftar anggota & radar mereka
    // bye + tanda presence jalan bersamaan, masing-masing dibatasi 4 dtk (tombol Keluar tidak boleh terasa macet)
    await Future.wait([
      _send(EType.control, 'g', {'op': 'bye', 'mid': mid, 'at': at}, ttl: 6).timeout(const Duration(seconds: 4)).then((_) {}, onError: (_) {}),
      Online.i.markLeft(),
    ]);
    if (Mesh.i.peers.any((p) => p.connected)) await Future.delayed(const Duration(milliseconds: 1500));
    // pemberitahuan ke server (admin melihat "Keluar") dikirim di belakang lewat antrean: tidak ditunggu di sini
    if (token.isNotEmpty) {
      final pend = await _pendingLeaves()
        ..removeWhere((e) => e['s'] == sl)
        ..add({'s': sl, 'm': mid, 't': token, 'at': at, 'now': true});
      await s.put('pending_leaves', jsonEncode(pend));
    }
    await _teardown();
    final f = Finder(filter: Filter.equals('slug', sl));
    for (final st in [s.messages, s.outbox, s.anns, s.rollcalls, s.fleet, s.checkins, s.sos, s.locations, s.reports]) {
      await st.delete(s.db, finder: f);
    }
    await s.concerts.record(sl).delete(s.db);
    for (final k in ['active', 'code_$sl', 'car_$sl', 'extra_$sl', 'left_$sl', 'gone_applied_$sl', 'ann_del_$sl', 'ann_del_pending_$sl', 'reach_cfg_$sl', 'reach_disband_$sl', 'prof_$sl','my_sos_$sl', 'online_since_$sl']) {
      await s.put(k, null);
    }
    _extraRoster.clear();
    _left.clear();
    _prof.clear();
    _helloAt.clear();
    mySosId = null;
    concert = null;
    unawaited(_writeMyIds());
    await s.put('pending_unsub', true); // dilepas oleh _retryUnsub di _flushPendingLeaves di bawah
    notifyListeners();
    unawaited(_flushPendingLeaves());
    return reached;
  }

  Future<List<Map<String, dynamic>>> _pendingLeaves() async {
    final raw = await s.get<String>('pending_leaves');
    if (raw == null) return [];
    try {
      return [
        for (final e in (jsonDecode(raw) as List? ?? const []))
          if (e is Map) e.cast<String, dynamic>() else {'t': '$e'}, // format lama: token saja
      ];
    } catch (_) {
      return [];
    }
  }

  /// Gabung lagi ke konser yang pemberitahuan keluarnya masih tertunda: buang supaya tidak mengeluarkan diri sendiri.
  Future<void> _dropPendingLeave(String sl) async {
    final pend = await _pendingLeaves();
    final before = pend.length;
    pend.removeWhere((e) => e['s'] == sl);
    if (pend.length != before) await s.put('pending_leaves', pend.isEmpty ? null : jsonEncode(pend));
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
      final saved = await savedConcerts();
      final ids = [
        'v2', // penanda: daftar 'slug:' di bawah lengkap, push untuk konser lain diabaikan
        for (final b in saved) '${(b['member'] as Map?)?['mid'] ?? ''}',
        for (final b in saved) 'slug:${(b['konser'] as Map?)?['slug'] ?? ''}',
      ]..removeWhere((e) => e.isEmpty || e == 'slug:');
      await writeMyIdsFile(ids);
    } catch (_) {}
  }

  Future<void> _setupKeys() async {
    final c = concert!;
    _cid = await concertCid(c.slug);
    _groupKey = SecretKey(base64Decode(c.groupKey));
    _chByHash.clear();
    // DM juga untuk anggota yang sedang disembunyikan: kalau dia gabung lagi, pesannya tetap terbaca
    final all = <String>{for (final m in c.roster) m.id, ..._extraRoster.keys}..remove(c.me.id);
    final ids = <String>{'g', 'k', for (final a in c.areas) 'a:$a', for (final mid in all) dmChannel(c.me.id, mid)};
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
    for (final t in _dropTimers.values) {
      t.cancel();
    }
    _dropTimers.clear();
    reachEvents.clear();
    _reachSent.clear();
    _myReachSt = 'idle';
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
    final leftRaw = await s.get<String>('left_${c.slug}');
    _left
      ..clear()
      ..addAll(leftRaw == null ? {} : (jsonDecode(leftRaw) as Map).map((k, v) => MapEntry('$k', (v as num).toInt())));
    _helloAt.clear();
    final prof = await s.get<String>('prof_${c.slug}');
    _prof
      ..clear()
      ..addAll(prof == null ? {} : (jsonDecode(prof) as Map).map((k, v) => MapEntry('$k', (v as Map).cast<String, dynamic>())));
    _pruneProfiles();
    final annDel = await s.get<String>('ann_del_${c.slug}');
    _annDel
      ..clear()
      ..addAll(annDel == null ? const [] : (jsonDecode(annDel) as List).map((e) => '$e'));
    await _loadReach(c.slug);
    await _applyServerMembership();
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
      if (up) {
        _flushOutbox();
        unawaited(_flushAnnDel());
      }
      _pushNet();
      notifyListeners();
    }));
    _subs.add(Online.i.consoleAnnouncements.listen(_onConsoleAnn));
    _subs.add(Online.i.presence.listen((e) {
      final old = presence[e.key];
      presence[e.key] = e.value;
      if (old?.$1 != e.value.$1) notifyListeners();
    }));
    _subs.add(Online.i.left.listen((e) {
      final (isLeft, isOn, ls, ss) = e.value; // ls/ss = jam server Firebase
      if (isLeft) {
        _markLeft(e.key, ls > 0 ? ls : DateTime.now().millisecondsSinceEpoch);
        return;
      }
      final la = _left[e.key];
      if (la == null) return;
      // gabung lagi dengan identitas yang sama: sesi app baru (ss) dimulai sesudah waktu keluar, atau sedang online sesudahnya.
      // Bukan dari 'ls' saja: putusnya koneksi HP lama (onDisconnect) bisa tercatat berjam-jam sesudah orangnya keluar.
      if (ss > la || (isOn && ls > la)) _unmarkLeft(e.key);
    }));
    _subs.add(Online.i.locations.listen((e) {
      if (e.key != me.id) _applyLoc(e.value, e.key);
    }));
    _subs.add(Mesh.i.envelopes.listen((e) => receive(e.$1, e.$2)));
    _subs.add(Mesh.i.peerStream.listen((_) {
      _flushOutbox();
      notifyListeners();
    }));
    _subs.add(Mesh.i.linkDownStream.listen(_onLinkDown));
    _subs.add(Mesh.i.reachStream.listen(_watchMyReach));
    _subs.add(Bridge.i.envelopes.listen((b) => receive(b, 'bridge')));
    _subs.add(Bridge.i.state.listen((_) {
      _flushOutbox();
      notifyListeners();
    }));

    if (Mesh.i.supported) {
      await Mesh.i.start(cidHex: hex(_cid), memberId: c.me.id, concertName: c.name, names: _names());
      await _drainMesh();
    }
    _attachAt = DateTime.now().millisecondsSinceEpoch;
    unawaited(Online.i.attach(c).then((_) => notifyListeners()));
    var ticks = 0;
    _tick = Timer.periodic(const Duration(seconds: 4), (_) {
      _flushOutbox();
      if (++ticks % 5 == 0) _pushNet(); // tiap 20 dtk: service menganggap status internet basi setelah 45 dtk
    });
    _pushNet();
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

  /// Kirim pemberitahuan "keluar" yang tertunda karena saat itu offline.
  bool _flushingLeaves = false;
  Future<void> _flushPendingLeaves() async {
    if (_flushingLeaves) return;
    _flushingLeaves = true;
    try {
      final pend = await _pendingLeaves();
      if (pend.isEmpty) return;
      final keep = <Map<String, dynamic>>[];
      for (final e in pend) {
        // sudah gabung lagi ke konser itu: jangan dikirim
        if (e['s'] != null && e['s'] == slug) continue;
        try {
          // 'now' = percobaan pertama tepat setelah tombol Keluar (bukan tertunda): server selalu mencatatnya
          await Api.call('leave', {'member_token': e['t'], if (e['at'] != null) 'at': e['at'], 'late': e['now'] != true},
              timeout: const Duration(seconds: 10));
        } on ApiError catch (err) {
          if (err.isNetwork) keep.add({...e}..remove('now')); // coba lagi nanti; error lain (token kedaluwarsa dll.) dibuang
        } catch (_) {
          keep.add({...e}..remove('now'));
        }
      }
      // entri yang ditambah/dibuang selama pengiriman (gabung lagi) tetap dihormati
      final now = await _pendingLeaves();
      final tried = {for (final e in pend) e['t']};
      final kept = {for (final e in keep) e['t']: e};
      final result = [
        for (final e in now)
          if (!tried.contains(e['t'])) e else if (kept.containsKey(e['t'])) kept[e['t']]!,
      ];
      await s.put('pending_leaves', result.isEmpty ? null : jsonEncode(result));
    } finally {
      _flushingLeaves = false;
      // langganan push konser yang sudah ditinggalkan: lepas begitu ada internet (juga saat antrean kosong)
      await _retryUnsub();
    }
  }

  /// Lepas langganan push konser yang ditinggalkan saat offline. Diberi batas waktu: unsubscribe Android bisa lama di internet setengah ada.
  Future<void> _retryUnsub() async {
    if (concert != null || await s.get<bool>('pending_unsub') != true) return;
    if (concert != null) return; // gabung lagi selama menunggu: langganan konser baru yang berlaku
    try {
      await Online.i.syncTopics(const []).timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  void _onNetworkBack() {
    unawaited(_flushPendingLeaves());
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
      await Mesh.i.send(bytes);
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
    mesh = await Mesh.i.send(bytes);
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
  int _meshRetryAt = 0;

  /// Service mesh belum jalan (mis. izin Bluetooth baru diberikan, atau service dimatikan sistem): coba lagi tiap 30 detik.
  Future<void> _ensureMesh() async {
    final c = concert;
    if (c == null || !Mesh.i.supported || Mesh.i.running) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now < _meshRetryAt) return;
    _meshRetryAt = now + 30000;
    if (await Mesh.i.start(cidHex: hex(_cid), memberId: c.me.id, concertName: c.name, names: _names())) {
      await _drainMesh();
      notifyListeners();
    }
  }

  /// Pesan tim (bukan milik saya) yang lewat saat internet putus: disimpan di outbox bertanda relay, hanya jalur online.
  Future<void> _queueRelay(String id, Uint8List bytes, Envelope env) async {
    final rec = s.outbox.record(id);
    if (await rec.exists(s.db)) return;
    final n = await s.outbox.count(s.db, filter: Filter.and([Filter.equals('slug', slug), Filter.equals('relay', true)]));
    if (n >= 500) return; // batas: jangan memenuhi HP penerus
    await rec.put(s.db, {
      'slug': slug, 'env': base64Encode(bytes), 'online': false, 'mesh': true, 'bridge': true, 'relay': true,
      'from': env.from, 'at': env.ts, 'type': env.type,
    });
  }

  Future<void> _flushOutbox() async {
    if (_flushing || concert == null) return;
    await _ensureMesh();
    _flushing = true;
    try {
      final all = await s.outbox.find(s.db, finder: Finder(filter: Filter.equals('slug', slug), sortOrders: [SortOrder('at')]));
      final now = DateTime.now().millisecondsSinceEpoch;
      // pesan & SOS saya dulu; titipan HP lain di belakang, maks 20 per putaran, berhenti di gagal pertama
      final recs = [...all.where((r) => r.value['relay'] != true), ...all.where((r) => r.value['relay'] == true)];
      var relays = 0;
      var relayFailed = false;
      for (final r in recs) {
        final v = r.value;
        if (v['relay'] == true) {
          // titipan HP lain: cukup sampai server (push FCM diminta pengirim aslinya); basi > 6 jam dibuang
          if (now - ((v['at'] as num?)?.toInt() ?? now) > 6 * 3600000) {
            await s.outbox.record(r.key).delete(s.db);
            continue;
          }
          if (relayFailed || !Online.i.connected || relays >= 20) continue;
          relays++;
          if (await Online.i.push(r.key, base64Decode(v['env'] as String), '${v['from']}')) {
            await s.outbox.record(r.key).delete(s.db);
          } else {
            relayFailed = true;
          }
          continue;
        }
        final bytes = base64Decode(v['env'] as String);
        var online = false, mesh = false, bridge = false;
        if (v['online'] != true && Online.i.connected) {
          online = await Online.i.push(r.key, bytes, me.id);
          if (online) _notifyServer({...v, 'id': r.key});
        }
        if (v['mesh'] != true) mesh = await Mesh.i.send(bytes);
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
    // titipan HP lain (relay) bukan pesan saya yang menunggu
    queued = await s.outbox.count(s.db, filter: Filter.and([Filter.equals('slug', slug), Filter.isNull('relay')]));
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

  // ----------------------------------------------------------- jangkauan tim

  /// Ambang RSSI "melemah" (dBm) & radius jangkauan (m) hasil kalibrasi koordinator; default sebelum kalibrasi.
  double reachWeak = -88, reachRadius = 30;
  int _reachAt = 0;
  String reachBy = '';
  bool reachAlerts = true;

  /// Peringatan didiamkan sampai (ms), mis. driver sedang menyetir. 0 = tidak.
  int reachMuteUntil = 0;

  Future<void> _loadReach(String sl) async {
    final raw = await s.get<String>('reach_cfg_$sl');
    final j = raw == null ? const {} : (jsonDecode(raw) as Map);
    reachWeak = (j['weak'] as num?)?.toDouble() ?? -88;
    reachRadius = (j['r'] as num?)?.toDouble() ?? 30;
    _reachAt = (j['at'] as num?)?.toInt() ?? 0;
    reachBy = '${j['by'] ?? ''}';
    reachAlerts = (await s.get<bool>('reach_on')) ?? true;
    reachMuteUntil = (await s.get<int>('reach_mute')) ?? 0;
    final dis = await s.get<String>('reach_disband_$sl');
    reachDisband = dis == null ? const {} : (jsonDecode(dis) as Map).cast<String, dynamic>();
    await _syncReach();
  }

  /// Tanggal konser (yyyy-MM-dd; dipotong kalau server mengirim format berjam).
  List<String> get _concertDates => [for (final e in concert?.dates ?? const <String>[]) e.length >= 10 ? e.substring(0, 10) : e];

  /// Hari ini (mulai 06.00) termasuk tanggal konser? Tanpa tanggal di data konser: tidak diketahui -> false.
  bool get concertToday => _concertDates.contains(concertDay());

  /// Peringatan jangkauan hanya di hari konser. Konser tanpa tanggal: tetap boleh (alarm biasa baru bunyi setelah bertemu tim).
  bool get reachDay => _concertDates.isEmpty || concertToday;

  /// Koordinator membubarkan tim (acara selesai): {day, by, at}. Peringatan jangkauan mati sampai hari konser berikutnya.
  Map<String, dynamic> reachDisband = const {};
  bool get disbandedToday => reachDisband['day'] == concertDay();

  String _reachSig = '';
  Future<void> _syncReach({bool force = true}) async {
    final enabled = reachAlerts && !disbandedToday && reachDay;
    // alarm "internet hilang saat sendirian" hanya di tanggal konser yang pasti (bukan di rumah)
    final active = concertToday && !disbandedToday;
    // hari ikut di signature: Kotlin mematikan "aktif" tiap 06.00, hari ke-2 konser harus dikirim ulang
    final sig = '$enabled|$active|$reachWeak|$reachMuteUntil|${concertDay()}';
    if (!force && sig == _reachSig) return; // dicek ulang tiap 20 dtk (ganti hari 06.00) tanpa memanggil service terus
    _reachSig = sig;
    await Mesh.i.setReach(enabled: enabled, weakDbm: reachWeak, muteUntil: reachMuteUntil, active: active);
  }

  // ---- kabar "anggota lepas" ke koordinator

  /// Kejadian jangkauan terbaru untuk koordinator: {mid, kind: weak|lost, by, near, at}. Hanya di memori (30 mnt terakhir).
  final List<Map<String, dynamic>> reachEvents = [];
  final Map<String, Timer> _dropTimers = {};
  String _myReachSt = 'idle';
  final Map<String, int> _reachNotified = {}; // member_id -> kapan koordinator terakhir diberi tahu

  bool get _reachLive => reachAlerts && !disbandedToday && reachDay;

  /// Kapan kabar jangkauan (kind|peer) terakhir dikirim HP ini / didengar dari HP lain: cegah banjir N kabar per kejadian.
  final Map<String, int> _reachSent = {};

  /// Link ke anggota putus (dari service, juga saat layar mati). Sinyal terakhirnya lemah & 30 dtk kemudian dia tidak terlihat
  /// lagi (cek snapshot segar dari service) -> kabari koordinator. HP ini yang terakhir melihatnya.
  void _onLinkDown(Map ev) {
    final mid = '${ev['mid'] ?? ''}';
    final rs = (ev['rs'] as num?)?.toDouble();
    if (mid.isEmpty || mid == me.id || member(mid) == null) return;
    // putus saat sinyal masih kuat: putus-sambung biasa, bukan karena menjauh
    if (rs != null && rs != 0 && rs > reachWeak + 3) return;
    final dropAt = (ev['at'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;
    _dropTimers[mid]?.cancel();
    // 30 dtk + jeda acak 0–10 dtk: kalau HP lain lebih dulu melapor, HP ini tidak ikut mengirim
    _dropTimers[mid] = Timer(Duration(milliseconds: 30000 + Random().nextInt(10000)), () async {
      _dropTimers.remove(mid);
      if (concert == null || !_reachLive || !Mesh.i.running) return;
      // HP ini sendiri sedang menjauh dari tim: yang "lepas" justru saya, jangan laporkan yang ditinggal
      if (_myReachSt == 'weak' || _myReachSt == 'lost') return;
      final fresh = await Mesh.i.snapshot();
      if (concert == null) return; // keluar konser selama menunggu
      final back = fresh.any((p) => p.memberId == mid && (p.connected || p.lastSeen > dropAt + 3000));
      if (back) return;
      final p = {'op': 'reachev', 'mid': me.id, 'peer': mid, 'kind': 'lost', 'rssi': rs?.round(), 'at': DateTime.now().millisecondsSinceEpoch};
      // hanya kalau HP ini masih bersama tim (ada HP tim lain di sekitar). Sendirian = mungkin saya yang pergi:
      // jangan menuduh di grup; koordinator cukup mencatat untuk dirinya sendiri.
      final withTeam = fresh.any((x) => x.memberId != mid && x.memberId.isNotEmpty && (x.connected || x.lastSeen > dropAt));
      if (!withTeam) {
        if (me.isKoord) _onReachEvent(p, me.id);
        return;
      }
      await _sendReachEvent(p, 'lost|$mid');
    });
  }

  /// Kirim kabar jangkauan paling banyak sekali per (jenis, anggota) per 10 mnt; koordinator pengirim langsung menerimanya sendiri.
  Future<void> _sendReachEvent(Map<String, dynamic> p, String key) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - (_reachSent[key] ?? 0) < 10 * 60000) return;
    _reachSent[key] = now;
    try {
      await _send(EType.control, 'g', p, prio: Prio.high);
    } catch (_) {}
    if (me.isKoord) _onReachEvent(p, me.id); // kiriman sendiri tidak kembali ke HP ini
  }

  /// Kondisi jangkauan HP ini berubah: saat mulai melemah (masih tersambung) kabari koordinator.
  void _watchMyReach(Map r) {
    final st = '${r['st'] ?? 'idle'}';
    if (st == _myReachSt) return;
    final prev = _myReachSt;
    _myReachSt = st;
    if (st == 'weak' && prev == 'ok' && _reachLive && !me.isKoord) {
      unawaited(_sendReachEvent(
          {'op': 'reachev', 'mid': me.id, 'peer': me.id, 'kind': 'weak', 'near': '${r['mid'] ?? ''}', 'at': DateTime.now().millisecondsSinceEpoch}, 'weak|${me.id}'));
    }
  }

  /// Kabar jangkauan diterima (semua HP mencatat supaya tidak ikut melapor kejadian yang sama; hanya koordinator yang diberi tahu).
  void _onReachEvent(Map<String, dynamic> p, String from) {
    final peer = '${p['peer'] ?? ''}';
    final kind = '${p['kind']}';
    if (from != me.id) {
      _reachSent['$kind|$peer'] = DateTime.now().millisecondsSinceEpoch;
      if (kind == 'lost') _dropTimers.remove(peer)?.cancel();
    }
    final m = member(peer);
    if (!me.isKoord || m == null || peer == me.id) return;
    final at = _clampAt((p['at'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - at > 30 * 60000) return; // kabar basi (tertahan lama di relay)
    reachEvents
      ..removeWhere((e) => e['mid'] == peer || now - (e['at'] as int) > 30 * 60000)
      ..insert(0, {'mid': peer, 'kind': kind, 'by': from, 'near': '${p['near'] ?? ''}', 'at': at});
    notifyListeners();
    // anggota itu sedang online lewat internet: pesannya tetap sampai, tidak perlu diganggu
    // presence hanya bisa dipercaya kalau HP koordinator sendiri sedang tersambung ke server
    if ((Online.i.connected && presence[peer]?.$1 == true) || !_reachLive) return;
    if (now - (_reachNotified[peer] ?? 0) < 10 * 60000) return;
    _reachNotified[peer] = now;
    final who = m.displayName;
    final seenBy = member(from)?.displayName;
    Notifier.i.show(
      title: kind == 'weak' ? '$who menjauh dari tim' : '$who lepas dari jangkauan tim',
      body: kind == 'weak'
          ? 'Sinyal Bluetooth-nya melemah. Pesan ke dia bisa segera tidak sampai.'
          : 'Terakhir terlihat${seenBy == null || from == peer ? '' : ' dekat $seenBy'}. Pesan tidak sampai sampai dia kembali / dapat sinyal.',
      route: 'reach',
      important: true,
    );
  }

  /// Koordinator: "Selesai, bubarkan tim" (undo = batalkan). Disebar ke semua HP lewat internet + mesh.
  Future<void> disbandTeam({bool undo = false}) async {
    if (!me.isKoord) return;
    // selalu lebih baru dari keputusan sebelumnya (jam HP antar-koordinator bisa beda beberapa menit)
    final at = max(DateTime.now().millisecondsSinceEpoch, ((reachDisband['at'] as num?)?.toInt() ?? 0) + 1);
    await _applyDisband(undo ? '' : concertDay(), me.name, at);
    try {
      await _send(EType.control, 'g', {'op': 'disband', 'mid': me.id, 'day': undo ? '' : concertDay(), 'by': me.name, 'at': at}, prio: Prio.high);
    } catch (_) {}
  }

  Future<void> _applyDisband(String day, String by, int at) async {
    if (at <= ((reachDisband['at'] as num?)?.toInt() ?? 0)) return; // yang terbaru menang
    reachDisband = {'day': day, 'by': by, 'at': at};
    await s.put('reach_disband_$slug', jsonEncode(reachDisband));
    await _syncReach();
    notifyListeners();
  }

  Future<void> setReachAlerts(bool on) async {
    reachAlerts = on;
    await s.put('reach_on', on);
    await _syncReach();
    notifyListeners();
  }

  /// Diamkan peringatan jangkauan sementara (null = aktifkan lagi).
  Future<void> muteReach(Duration? d) async {
    reachMuteUntil = d == null ? 0 : DateTime.now().add(d).millisecondsSinceEpoch;
    await s.put('reach_mute', reachMuteUntil);
    await _syncReach();
    notifyListeners();
  }

  bool get reachMuted => reachMuteUntil > DateTime.now().millisecondsSinceEpoch;

  /// Kabari service: internet nyata (Firebase tersambung) + app di layar.
  int _attachAt = 0;
  void _pushNet() {
    // Firebase butuh beberapa detik untuk tersambung setelah app dibuka: jangan laporkan "offline" palsu di 15 dtk pertama
    // (service memakai status lamanya / probe sendiri)
    final early = DateTime.now().millisecondsSinceEpoch - _attachAt < 15000;
    unawaited(Mesh.i.setNet(online: Online.i.connected ? true : (early ? null : false), foreground: _foreground));
    unawaited(_syncReach(force: false)); // hari konser berganti jam 06.00
  }

  Future<void> _storeReach(double weak, double r, int at, String by) async {
    reachWeak = weak.clamp(-100, -60).toDouble();
    reachRadius = r.clamp(5, 150).toDouble();
    _reachAt = at;
    reachBy = by;
    await s.put('reach_cfg_$slug', jsonEncode({'weak': reachWeak, 'r': reachRadius, 'at': at, 'by': by}));
    await _syncReach();
    notifyListeners();
  }

  /// Hasil kalibrasi (koordinator): dipakai di HP ini lalu disebar ke semua HP tim (internet + mesh).
  Future<void> applyReachCalibration({required double weakDbm, required double radiusM}) async {
    if (!me.isKoord) return;
    final at = DateTime.now().millisecondsSinceEpoch;
    await _storeReach(weakDbm, radiusM, at, me.name);
    try {
      await _send(EType.control, 'g', {'op': 'reach', 'mid': me.id, 'weak': reachWeak, 'r': reachRadius, 'at': at, 'by': me.name}, prio: Prio.high);
    } catch (_) {}
  }

  /// Pengumuman yang sudah dihapus (id). Disimpan supaya kiriman ulang lewat mesh / riwayat online tidak memunculkannya lagi.
  final Set<String> _annDel = {};

  /// Hapus pengumuman (koordinator). Disebar sebagai control (tanpa push & notifikasi) lewat internet + mesh.
  Future<void> deleteAnnouncement(String id) async {
    if (!me.isKoord) return;
    final cur = await s.anns.record(id).get(s.db);
    await _removeAnn(id);
    // pengumuman Console: tandai juga di server supaya Console & HP yang gabung belakangan tidak menampilkannya lagi
    if (cur?['by'] == 'console' && concert!.token.isNotEmpty) {
      // offline (paling sering di lapangan): antrekan, dikirim begitu ada internet (_flushAnnDel)
      final pend = {...((jsonDecode((await s.get<String>('ann_del_pending_$slug')) ?? '[]') as List).map((e) => '$e')), id};
      await s.put('ann_del_pending_$slug', jsonEncode(pend.toList()));
      unawaited(_flushAnnDel());
    }
    try {
      await _send(EType.control, 'g', {'op': 'anndel', 'mid': me.id, 'id': id, 'at': DateTime.now().millisecondsSinceEpoch}, prio: Prio.high);
    } catch (_) {}
  }

  bool _flushingAnnDel = false;
  Future<void> _flushAnnDel() async {
    final c = concert;
    if (c == null || c.token.isEmpty || _flushingAnnDel) return;
    final key = 'ann_del_pending_${c.slug}';
    final raw = await s.get<String>(key);
    if (raw == null) return;
    _flushingAnnDel = true;
    try {
      final keep = <String>[];
      for (final id in (jsonDecode(raw) as List).map((e) => '$e')) {
        try {
          await Api.call('ann_del', {'member_token': c.token, 'id': id}, timeout: const Duration(seconds: 10));
        } on ApiError catch (e) {
          if (e.isNetwork) keep.add(id); // error lain (bukan koordinator lagi, id tidak ada): buang
        } catch (_) {
          keep.add(id);
        }
      }
      await s.put(key, keep.isEmpty ? null : jsonEncode(keep));
    } finally {
      _flushingAnnDel = false;
    }
  }

  Future<void> _removeAnn(String id) async {
    if (id.isEmpty) return;
    if (_annDel.add(id)) await s.put('ann_del_$slug', jsonEncode(_annDel.toList()));
    await s.anns.record(id).delete(s.db);
    notifyListeners();
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
    if (concert == null || _leaving) return;
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
    if (c == null || _groupKey == null || _leaving) return;
    try {
      final helloId = await _send(EType.control, 'g', {
        'op': 'hello',
        'mid': me.id,
        'n': me.name,
        'r': me.role,
        'car': me.car,
        'area': me.area,
        'px': keys.pubXb64,
        'pe': keys.pubEdB64,
        'at': DateTime.now().millisecondsSinceEpoch,
        // umur data server profil ini (jam server): penerima hanya memakai profil yang lebih baru dari data servernya sendiri
        'st': (c.b['server_time'] as num?)?.toInt() ?? 0,
      }, ttl: 3);
      // hello cukup sekali jalan (dikirim ulang tiap 15 mnt). Hanya envelope hello ini yang dibuang: control lain yang
      // masih menunggu (hapus pengumuman, kalibrasi, bye) dan titipan HP lain tetap di outbox sampai terkirim.
      await s.outbox.record(helloId).delete(s.db);
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
    if (via != 'online' && env.type != EType.loc) {
      if (Online.i.connected) {
        unawaited(Online.i.push(id, bytes, env.from));
      } else if (Online.i.ready) {
        // internet HP ini sedang putus: simpan, teruskan begitu tersambung (pesan sudah ditandai terlihat, tidak akan datang lagi)
        unawaited(_queueRelay(id, bytes, env));
      }
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
    final sender = _memberAny(env.from);
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
        // sudah ada / sudah dihapus: tidak dinotifikasi ulang
        if (await _applyAnn(p, env.from, fromName)) {
          _queueAckGroupItem(p['id'] as String?, 'd');
          Notifier.i.show(title: 'Pengumuman: ${p['title']}', body: '${p['body'] ?? ''}', route: 'info', important: true);
        }
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
        await _onControl(p, env.from, verified);
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

  Future<void> _onControl(Map<String, dynamic> p, String from, bool verified) async {
    final mid = '${p['mid']}';
    if (mid != from) return;
    final at = _clampAt((p['at'] as num?)?.toInt() ?? 0);
    if (p['op'] == 'reach') {
      // kalibrasi jangkauan dari koordinator; yang terbaru menang
      if (!verified || !(_memberAny(from)?.isKoord ?? false) || at <= _reachAt) return;
      final w = (p['weak'] as num?)?.toDouble(), r = (p['r'] as num?)?.toDouble();
      if (w == null || r == null) return;
      await _storeReach(w, r, at, '${p['by'] ?? ''}');
      return;
    }
    if (p['op'] == 'reachev') {
      if (verified) _onReachEvent(p, from);
      return;
    }
    if (p['op'] == 'disband') {
      // koordinator membubarkan / membatalkan bubar tim
      if (!verified || !(_memberAny(from)?.isKoord ?? false)) return;
      await _applyDisband('${p['day'] ?? ''}', '${p['by'] ?? ''}', at);
      return;
    }
    if (p['op'] == 'anndel') {
      // koordinator (tanda tangan terverifikasi), atau HP mana pun yang meneruskan penghapusan dari Console untuk pengumuman Console
      final id = '${p['id'] ?? ''}';
      final cur = await s.anns.record(id).get(s.db);
      final byKoord = verified && (_memberAny(from)?.isKoord ?? false);
      // penerus hapus-dari-Console harus anggota terverifikasi (tanda tangan sah), dan hanya untuk pengumuman Console
      final consoleRelay = verified && p['via'] == 'console' && (cur == null || cur['by'] == 'console');
      if (byKoord || consoleRelay) await _removeAnn(id);
      return;
    }
    if (p['op'] == 'bye') {
      // hanya dari anggota yang tanda tangannya terverifikasi
      if (!verified) return;
      await _markLeft(mid, at > 0 ? at : DateTime.now().millisecondsSinceEpoch);
      return;
    }
    if (p['op'] != 'hello') return;
    // kunci di hello harus milik member_id itu (mencegah kunci DM palsu dari pemegang kunci grup)
    if (p['pe'] is! String || await memberIdFor(slug, p['pe'] as String) != mid) return;
    if (at > (_helloAt[mid] ?? 0)) _helloAt[mid] = at;
    final leftAt = _left[mid];
    if (leftAt != null) {
      if (at <= leftAt) return; // hello lama (tersimpan di relay / riwayat) dari sebelum dia keluar
      await _unmarkLeft(mid);
    }
    if (concert!.member(mid) != null) {
      if (verified) await _applyProfile(mid, p);
      return;
    }
    _extraRoster[mid] = {'mid': mid, 'n': p['n'], 'r': p['r'], 'car': p['car'] ?? '', 'area': p['area'] ?? '', 'px': p['px'], 'pe': p['pe'], 'st': 'aktif', 'mesh': true};
    await s.put('extra_$slug', jsonEncode(_extraRoster));
    _chByHash[hex(await channelHash(slug, dmChannel(me.id, mid)))] = dmChannel(me.id, mid);
    await Mesh.i.setNames(_names());
  }

  void _onConsoleAnn(Map<String, dynamic> a) async {
    final id = '${a['id']}';
    if (a['del'] != null) {
      // dihapus dari Console: hapus lokal + teruskan ke HP offline lewat mesh
      final known = _annDel.contains(id);
      await _removeAnn(id);
      if (!known) {
        try {
          await _send(EType.control, 'g', {'op': 'anndel', 'mid': me.id, 'id': id, 'via': 'console', 'at': a['del']}, prio: Prio.high, meshOnly: true);
        } catch (_) {}
      }
      return;
    }
    if (_annDel.contains(id) || await s.anns.record(id).exists(s.db)) return;
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

  /// true = pengumuman baru tersimpan (false: sudah ada atau sudah dihapus).
  Future<bool> _applyAnn(Map<String, dynamic> p, String from, String fromName) async {
    final id = '${p['id']}';
    if (_annDel.contains(id)) return false;
    final cur = await s.anns.record(id).get(s.db);
    if (cur != null) return false;
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
    return true;
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

  /// Jam HP pengirim bisa terlalu maju: batasi supaya tidak memblokir hello berikutnya sampai jam itu lewat.
  int _clampAt(int at) => min(at, DateTime.now().millisecondsSinceEpoch + 5 * 60 * 1000);

  Future<void> _markLeft(String mid, int at) async {
    if (concert == null || mid == me.id || _left.containsKey(mid)) return;
    at = _clampAt(at);
    if ((_helloAt[mid] ?? 0) > at) return; // bye terlambat: dia sudah gabung lagi sesudahnya
    _left[mid] = at;
    await s.put('left_$slug', jsonEncode(_left));
    if (_extraRoster.remove(mid) != null) await s.put('extra_$slug', jsonEncode(_extraRoster));
    await s.locations.record('$slug|$mid').delete(s.db);
    notifyListeners();
  }

  Future<void> _unmarkLeft(String mid) async {
    if (_left.remove(mid) == null) return;
    await s.put('left_$slug', jsonEncode(_left));
    final ch = dmChannel(me.id, mid);
    _chByHash[hex(await channelHash(slug, ch))] = ch;
    unawaited(Mesh.i.setNames(_names()));
    notifyListeners();
  }

  /// Data server (join/refresh): 'gone' = anggota keluar/dikeluarkan, disembunyikan juga dari roster tambahan (mesh);
  /// anggota roster yang gabung lagi sesudah tanda keluar lokal ('ja' > waktu keluar) dimunculkan lagi.
  Future<void> _applyServerMembership() async {
    final c = concert;
    if (c == null) return;
    var leftChanged = false, extraChanged = false;
    final now = DateTime.now().millisecondsSinceEpoch;
    // 'gone' hanya dari bundle yang lebih baru dari yang terakhir diterapkan: bundle tersimpan (dibaca tiap app dibuka)
    // bisa berumur berjam-jam dan menyembunyikan lagi orang yang sudah gabung kembali lewat mesh
    final st = (c.b['server_time'] as num?)?.toInt() ?? 0;
    final applied = (await s.get<int>('gone_applied_${c.slug}')) ?? 0;
    final gone = st > applied ? ((c.b['gone'] as List?) ?? const []) : const [];
    if (st > applied) await s.put('gone_applied_${c.slug}', st);
    for (final g in gone) {
      if (g is! Map) continue;
      final mid = '${g['mid']}';
      if (mid == c.me.id || mid.isEmpty) continue;
      // waktu dari sheet cuma sampai menit (p != true): geser ke akhir menit supaya hello/sesi di menit keluarnya tidak membatalkan
      final raw = (g['at'] as num?)?.toInt() ?? 0;
      final at = raw > 0 && g['p'] != true ? raw + 60000 : raw;
      if (at > 0 && (_helloAt[mid] ?? 0) > at) continue;
      if (!_left.containsKey(mid)) {
        _left[mid] = at > 0 ? at : now;
        leftChanged = true;
        await s.locations.record('${c.slug}|$mid').delete(s.db);
      }
      if (_extraRoster.remove(mid) != null) extraChanged = true;
    }
    for (final m in c.roster) {
      final la = _left[m.id];
      final ja = (m.m['ja'] as num?)?.toInt() ?? 0;
      if (la != null && ja > la) {
        _left.remove(m.id);
        leftChanged = true;
      }
    }
    if (leftChanged) await s.put('left_${c.slug}', jsonEncode(_left));
    if (extraChanged) await s.put('extra_${c.slug}', jsonEncode(_extraRoster));
  }

  Future<void> _applyLoc(Map<String, dynamic> p, String from) async {
    if (p['lat'] == null || _left.containsKey(from)) return;
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
