import 'package:sembast/sembast.dart';

import 'db_factory_io.dart' if (dart.library.js_interop) 'db_factory_web.dart';

/// Semua data lokal (sumber kebenaran UI + offline). Satu database sembast; store per jenis data.
class Store {
  Store._(this.db);
  final Database db;

  static late Store i;

  static Future<void> init() async => i = Store._(await openAppDb());

  /// slug -> bundle hasil join/refresh (member, token, konser, epoch, roster, manifest, firebase)
  final concerts = stringMapStoreFactory.store('concerts');

  /// id hex -> pesan chat/sistem
  final messages = stringMapStoreFactory.store('messages');

  /// id hex -> envelope yang belum terkirim di salah satu jalur
  final outbox = stringMapStoreFactory.store('outbox');

  /// id -> pengumuman
  final anns = stringMapStoreFactory.store('anns');

  /// id -> absen {slug, by, at, closed, answers{mid:{ans,at}}}
  final rollcalls = stringMapStoreFactory.store('rollcalls');

  /// "slug|car|leg" -> status armada terbaru
  final fleet = stringMapStoreFactory.store('fleet');

  /// "slug|order|hari|leg" -> check-in penumpang terbaru
  final checkins = stringMapStoreFactory.store('checkins');

  /// sosId -> SOS
  final sos = stringMapStoreFactory.store('sos');

  /// "slug|mid" -> lokasi terakhir
  final locations = stringMapStoreFactory.store('locations');

  /// event_id -> laporan (armada/check-in) yang belum tersinkron ke GAS
  final reports = stringMapStoreFactory.store('reports');

  /// id envelope -> waktu terlihat (dedup)
  final seen = stringMapStoreFactory.store('seen');

  /// pengaturan & penanda (active slug, tema, ukuran teks, lastOnlineTs, draf)
  final kv = StoreRef<String, Object?>('kv');

  Future<T?> get<T>(String key) async => (await kv.record(key).get(db)) as T?;
  /// Simpan pengaturan. sembast tidak menerima nilai null, jadi null = hapus kunci
  /// (dulu menyimpan null melempar error dan menggagalkan "Keluar & hapus", "Gabung konser lain", dan batal SOS).
  Future<void> put(String key, Object? value) async {
    if (value == null) {
      await kv.record(key).delete(db);
    } else {
      await kv.record(key).put(db, value);
    }
  }
}
