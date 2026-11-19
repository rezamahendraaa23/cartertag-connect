import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../data/models.dart';
import '../data/store.dart';

/// Jalur online: Firebase Realtime Database (paket Spark, gratis).
/// Opsi Firebase (apiKey, appId, dst.) dikirim server lewat bundle join/refresh, jadi app tidak perlu
/// `flutterfire configure` saat build. Struktur data: lihat firebase/database.rules.json.
class Online {
  Online._();
  static final i = Online._();

  FirebaseDatabase? _db;
  String? _slug;
  bool connected = false;
  final _connCtl = StreamController<bool>.broadcast();
  final _envCtl = StreamController<Uint8List>.broadcast();
  final _annCtl = StreamController<Map<String, dynamic>>.broadcast();
  final _locCtl = StreamController<MapEntry<String, Map<String, dynamic>>>.broadcast();
  final _presCtl = StreamController<MapEntry<String, (bool, int)>>.broadcast();
  final _leftCtl = StreamController<MapEntry<String, (bool, bool, int, int)>>.broadcast();

  /// member_id -> (tanda 'left' di presence, online?, ls terakhir terlihat, ss awal sesi aktif; jam server ms).
  Stream<MapEntry<String, (bool, bool, int, int)>> get left => _leftCtl.stream;

  /// Diset Hub selama proses keluar: presence tidak ditulis ulang 'on:true' saat tersambung lagi.
  bool leaving = false;

  /// Status online anggota dari presence: member_id -> (online?, terakhir terlihat ms).
  Stream<MapEntry<String, (bool, int)>> get presence => _presCtl.stream;
  final _subs = <StreamSubscription>[];

  Stream<bool> get connection => _connCtl.stream;
  Stream<Uint8List> get envelopes => _envCtl.stream;
  Stream<Map<String, dynamic>> get consoleAnnouncements => _annCtl.stream;

  /// Lokasi anggota dari presence (member_id -> {lat, lng, acc, bat, at}).
  Stream<MapEntry<String, Map<String, dynamic>>> get locations => _locCtl.stream;
  bool get ready => _db != null;

  static FirebaseOptions? optionsFrom(Map<String, dynamic>? fb) {
    if (fb == null) return null;
    final all = (fb['options'] as Map?)?.cast<String, dynamic>();
    if (all == null) return null;
    final o = (all[kIsWeb ? 'web' : 'android'] as Map?)?.cast<String, dynamic>();
    if (o == null || o['apiKey'] == null || o['appId'] == null) return null;
    return FirebaseOptions(
      apiKey: '${o['apiKey']}',
      appId: '${o['appId']}',
      messagingSenderId: '${o['messagingSenderId'] ?? ''}',
      projectId: '${o['projectId'] ?? ''}',
      authDomain: o['authDomain'] as String?,
      databaseURL: '${fb['db_url'] ?? o['databaseURL'] ?? ''}',
      storageBucket: o['storageBucket'] as String?,
    );
  }

  /// Inisialisasi Firebase + login custom token untuk konser ini. Aman dipanggil berulang.
  Future<bool> attach(Concert c) async {
    final fb = c.firebase;
    final opts = optionsFrom(fb);
    if (opts == null) return false;
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(options: opts);
      }
      await Store.i.put('fb_options', jsonEncode((fb!['options'] as Map)));
      await Store.i.put('fb_db_url', '${fb['db_url']}');
      final auth = FirebaseAuth.instance;
      final uid = '${c.slug}__${c.me.id}';
      if (auth.currentUser?.uid != uid && fb['custom_token'] != null) {
        await auth.signInWithCustomToken('${fb['custom_token']}');
      }
      if (!kIsWeb) unawaited(syncTopics(((fb['topics'] as List?) ?? const []).map((e) => '$e').toList()));
      if (_slug == c.slug && _db != null) return true;
      await detach();
      _slug = c.slug;
      _db = FirebaseDatabase.instanceFor(app: Firebase.app(), databaseURL: '${fb['db_url']}');
      if (!kIsWeb) _db!.setPersistenceEnabled(false);
      _subs.add(_db!.ref('.info/connected').onValue.listen((e) {
        connected = e.snapshot.value == true;
        _connCtl.add(connected);
        if (connected) _presence(c);
      }));
      final since = (await Store.i.get<int>('online_since_${c.slug}')) ?? 0;
      final base = _db!.ref('c/${c.slug}/env').orderByChild('t');
      final q = since > 0 ? base.startAt(since - 120000) : base.limitToLast(500);
      _subs.add(q.onChildAdded.listen((e) {
        final v = e.snapshot.value;
        if (v is Map && v['e'] is String) {
          try {
            _envCtl.add(base64Decode(v['e'] as String));
          } catch (_) {}
          final t = v['t'];
          if (t is int) Store.i.put('online_since_${c.slug}', t);
        }
      }, onError: (_) {}));
      void loc(DatabaseEvent e) {
        final v = e.snapshot.value;
        if (v is Map) {
          final ls = (v['ls'] as num?)?.toInt() ?? 0;
          _presCtl.add(MapEntry('${e.snapshot.key}', (v['on'] == true, ls)));
          _leftCtl.add(MapEntry('${e.snapshot.key}', (v['left'] == true, v['on'] == true, ls, (v['ss'] as num?)?.toInt() ?? 0)));
        }
        if (v is Map && v['lat'] is num && v['lng'] is num) {
          _locCtl.add(MapEntry('${e.snapshot.key}', {'lat': v['lat'], 'lng': v['lng'], 'acc': v['acc'], 'bat': v['bat'], 'at': v['at']}));
        }
      }

      _subs.add(_db!.ref('c/${c.slug}/presence').onChildAdded.listen(loc, onError: (_) {}));
      _subs.add(_db!.ref('c/${c.slug}/presence').onChildChanged.listen(loc, onError: (_) {}));
      void ann(DatabaseEvent e) {
        final v = e.snapshot.value;
        if (v is Map) _annCtl.add(v.cast<String, dynamic>());
      }

      // onChildChanged: pengumuman dihapus dari Console ditandai 'del'
      _subs.add(_db!.ref('c/${c.slug}/ann').onChildAdded.listen(ann, onError: (_) {}));
      _subs.add(_db!.ref('c/${c.slug}/ann').onChildChanged.listen(ann, onError: (_) {}));
      return true;
    } catch (e) {
      debugPrint('Online.attach gagal: $e');
      return false;
    }
  }

  Future<void> detach() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _db = null;
    _slug = null;
    connected = false;
    _connCtl.add(false);
  }

  void _presence(Concert c) {
    final ref = _db?.ref('c/${c.slug}/presence/${c.me.id}');
    if (ref == null || leaving) return;
    ref.onDisconnect().update({'on': false, 'ls': ServerValue.timestamp});
    // ss = awal sesi aktif; hanya ditulis sesi yang benar-benar tersambung (bukan onDisconnect), dipakai HP lain untuk tahu dia gabung lagi
    ref.update({'on': true, 'ls': ServerValue.timestamp, 'ss': ServerValue.timestamp, 'pf': kIsWeb ? 'web' : 'android', 'left': null});
  }

  /// Keluar dari konser: presence diganti tanda 'left' (lokasi terakhir ikut terhapus) supaya HP lain berhenti menampilkan saya.
  Future<void> markLeft() async {
    final db = _db, slug = _slug;
    final mid = FirebaseAuth.instance.currentUser?.uid.split('__').last;
    if (db == null || slug == null || mid == null || !connected) return;
    final ref = db.ref('c/$slug/presence/$mid');
    try {
      // koneksi setengah mati di venue: jangan sampai tombol Keluar menggantung
      await Future.wait([
        ref.onDisconnect().cancel(),
        ref.set({'on': false, 'left': true, 'ls': ServerValue.timestamp}),
      ]).timeout(const Duration(seconds: 4));
    } catch (_) {}
  }

  Future<void> presenceExtra(Map<String, Object?> data) async {
    final c = _slug;
    if (c == null || !connected || leaving) return;
    final mid = FirebaseAuth.instance.currentUser?.uid.split('__').last;
    if (mid == null) return;
    await _db?.ref('c/$c/presence/$mid').update(data);
  }

  /// Tulis envelope (idempoten: rule menolak id yang sudah ada = dianggap sukses).
  Future<bool> push(String idHex, Uint8List env, String from) async {
    final db = _db, slug = _slug;
    if (db == null || slug == null || !connected) return false;
    try {
      await db.ref('c/$slug/env/$idHex').set({'e': base64Encode(env), 't': ServerValue.timestamp, 'f': from}).timeout(const Duration(seconds: 12));
      return true;
    } on FirebaseException catch (e) {
      return e.code == 'permission-denied'; // sudah ada (ditulis gateway lain)
    } catch (_) {
      return false;
    }
  }

  /// Cermin plaintext untuk monitor Console (status armada & SOS bukan rahasia).
  Future<void> mirror(String path, Map<String, Object?> data) async {
    final db = _db, slug = _slug;
    if (db == null || slug == null || !connected) return;
    try {
      await db.ref('c/$slug/$path').set(data);
    } catch (_) {}
  }

  /// Tanda sampai/dibaca untuk pesan grup (lewat online saja, supaya mesh tidak banjir).
  Future<void> ackGroup(String idHex, String mid, String kind) async {
    final db = _db, slug = _slug;
    if (db == null || slug == null || !connected) return;
    try {
      await db.ref('c/$slug/acks/$idHex/$mid').update({kind: ServerValue.timestamp});
    } catch (_) {}
  }

  /// Pantau tanda terima pesan saya: mid -> {d, r}.
  Stream<Map<String, Map>> watchAcks(String idHex) {
    final db = _db, slug = _slug;
    if (db == null || slug == null) return const Stream.empty();
    return db.ref('c/$slug/acks/$idHex').onValue.map((e) {
      final v = e.snapshot.value;
      if (v is! Map) return <String, Map>{};
      return v.map((k, val) => MapEntry('$k', val is Map ? val : const {}));
    });
  }

  /// Langganan topik push dari server (konser, koordinator, area). Topik lama yang tidak dipakai lagi dilepas.
  /// Dijalankan berurutan: lepas-langganan konser lama tidak boleh tumpang tindih dengan langganan saat gabung ulang.
  Future<void> _topicsChain = Future.value();
  Future<void> syncTopics(List<String> topics) {
    final next = _topicsChain.then((_) => _syncTopics(topics), onError: (_) => _syncTopics(topics));
    _topicsChain = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<void> _syncTopics(List<String> topics) async {
    if (kIsWeb || Firebase.apps.isEmpty) {
      await Store.i.put('pending_unsub', null);
      return;
    }
    final old = ((jsonDecode((await Store.i.get<String>('fcm_topics')) ?? '[]') as List?) ?? const []).map((e) => '$e').toSet();
    final now = topics.toSet();
    final m = FirebaseMessaging.instance;
    try {
      for (final t in old.difference(now)) {
        await m.unsubscribeFromTopic(t);
      }
      for (final t in now) {
        await m.subscribeToTopic(t);
      }
      await Store.i.put('fcm_topics', jsonEncode(now.toList()));
      await Store.i.put('pending_unsub', null); // topik konser yang ditinggalkan sudah dilepas
    } catch (e) {
      debugPrint('syncTopics: $e');
    }
  }

  /// Token FCM (Android) / Web Push. Null kalau Firebase belum siap atau izin ditolak.
  Future<String?> fcmToken() async {
    if (Firebase.apps.isEmpty) return null;
    try {
      final m = FirebaseMessaging.instance;
      if (kIsWeb) {
        // Browser: minta izin notifikasi sekali saja. Kalau sudah pernah dijawab (izinkan/tolak), tidak ditanya lagi.
        final st = (await m.getNotificationSettings()).authorizationStatus;
        if (st == AuthorizationStatus.notDetermined && await Store.i.get<bool>('web_notif_asked') != true) {
          await Store.i.put('web_notif_asked', true);
          await m.requestPermission();
        }
        if ((await m.getNotificationSettings()).authorizationStatus != AuthorizationStatus.authorized) return null;
        final opts = jsonDecode((await Store.i.get<String>('fb_options')) ?? '{}');
        final vapid = opts is Map ? opts['vapidKey'] as String? : null;
        if (vapid == null) return null;
        return await m.getToken(vapidKey: vapid);
      }
      return await m.getToken();
    } catch (_) {
      return null;
    }
  }
}
