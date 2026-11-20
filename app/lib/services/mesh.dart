import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Peer mesh yang terlihat (dari MeshService.kt).
class Peer {
  Peer(this.m);
  final Map m;
  String get addr => '${m['addr']}';
  String get memberId => '${m['mid'] ?? ''}';
  int get rssi => (m['rssi'] as num?)?.toInt() ?? -100;
  String get via => '${m['via'] ?? 'ble'}';
  bool get connected => m['connected'] == true;
  int get lastSeen => (m['ls'] as num?)?.toInt() ?? 0;
  String get node => '${m['node'] ?? ''}';

  /// Waktu (ms) bacaan RSSI mentah terakhir berubah. Bacaan membeku = radio sudah putus walau link belum dilepas Android.
  int get rawChangedAt => (m['rc'] as num?)?.toInt() ?? 0;

  /// RSSI dihaluskan & segar dari service (dBm). Null = belum ada bacaan.
  double? get rssiSmooth {
    final v = (m['rs'] as num?)?.toDouble();
    return v == null || v == 0 ? null : v;
  }

  /// Perkiraan jarak kasar dari RSSI (model log-distance, n=2.5, Tx -59 dBm @1m).
  double get meters => pow(10, (-59 - rssi) / 25.0).clamp(0.5, 150).toDouble();
}

/// Jembatan ke MeshService.kt (BLE mesh + Wi-Fi Direct + server jembatan iPhone). No-op di web.
class Mesh {
  Mesh._();
  static final i = Mesh._();

  static const _m = MethodChannel('ct/mesh');
  static const _e = EventChannel('ct/mesh/events');

  bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  final _env = StreamController<(Uint8List, String)>.broadcast();
  final _peers = StreamController<List<Peer>>.broadcast();
  final _signal = StreamController<List<Peer>>.broadcast();
  final _reach = StreamController<Map>.broadcast();
  final _linkDown = StreamController<Map>.broadcast();

  /// Link ke anggota putus: {mid, rs (RSSI terakhir), at}. Dikirim service juga saat layar mati.
  Stream<Map> get linkDownStream => _linkDown.stream;

  /// Snapshot segar daftar HP sekitar langsung dari service (bukan [peers] yang bisa basi saat UI di latar).
  Future<List<Peer>> snapshot() async {
    if (!supported) return const [];
    try {
      return ((await _m.invokeMethod<List>('peers')) ?? const []).map((p) => Peer(p as Map)).toList();
    } catch (_) {
      // gagal membaca: anggap semua masih terlihat (jangan melaporkan "lepas" dari data basi)
      return [for (final p in peers) Peer({...p.m, 'connected': true})];
    }
  }
  final _bridge = StreamController<Map>.broadcast();
  String _peerSig = '';

  /// Kondisi jangkauan dari service: {st: ok|weak|lost|online|idle, best, mid, weak, enabled}.
  Map reach = const {'st': 'idle'};
  Stream<Map> get reachStream => _reach.stream;

  /// Daftar HP sekitar + sinyal, tiap ~3 dtk (untuk layar Jangkauan). [peerStream] hanya saat yang tersambung berubah.
  Stream<List<Peer>> get signalStream => _signal.stream;
  StreamSubscription? _sub;
  List<Peer> peers = const [];
  bool running = false;

  /// (bytes envelope, jalur masuk: ble | wifi | bridge)
  Stream<(Uint8List, String)> get envelopes => _env.stream;
  Stream<List<Peer>> get peerStream => _peers.stream;

  /// Event jembatan: {e: bridge_msg|bridge_client, client, data?, state?}
  Stream<Map> get bridgeEvents => _bridge.stream;

  void _listen() {
    _sub ??= _e.receiveBroadcastStream().listen((ev) {
      if (ev is! Map) return;
      switch (ev['e']) {
        case 'env':
          _env.add((ev['data'] as Uint8List, '${ev['via'] ?? 'ble'}'));
        case 'peers':
          peers = ((ev['list'] as List?) ?? const []).map((p) => Peer(p as Map)).toList();
          _signal.add(peers);
          // service mengirim tiap 3 dtk: kabari pendengar lama (kirim ulang antrean, gambar ulang UI) hanya kalau sambungan berubah
          final sig = (peers.where((p) => p.connected).map((p) => '${p.addr}/${p.memberId}').toList()..sort()).join(',');
          if (sig != _peerSig) {
            _peerSig = sig;
            _peers.add(peers);
          }
        case 'reach':
          reach = Map.from(ev);
          _reach.add(reach);
        case 'linkdown':
          _linkDown.add(Map.from(ev));
        case 'state':
          running = ev['running'] == true;
        case 'bridge_msg':
        case 'bridge_client':
          _bridge.add(ev);
      }
    }, onError: (_) {});
  }

  /// Mulai foreground service. cid = 8 byte konser (hex), names = mid -> nama (untuk teks notifikasi saat UI tertutup).
  Future<bool> start({required String cidHex, required String memberId, required String concertName, required Map<String, String> names}) async {
    if (!supported) return false;
    _listen();
    try {
      final ok = await _m.invokeMethod<bool>('start', {'cid': cidHex, 'mid': memberId, 'concert': concertName, 'names': names});
      running = ok == true;
      return running;
    } on PlatformException {
      return false;
    }
  }

  Future<void> stop() async {
    if (!supported) return;
    await _m.invokeMethod('stop');
    running = false;
  }

  /// Siarkan envelope ke semua peer (router Kotlin menangani dedup, relay, simpan-teruskan).
  /// Serahkan envelope ke service mesh. true = diterima service (disimpan & disiarkan; HP yang muncul belakangan
  /// tetap menerimanya lewat sinkron inventaris). false = service belum jalan -> outbox mencoba lagi nanti.
  Future<bool> send(Uint8List envelope) async {
    if (!supported || !running) return false;
    try {
      await _m.invokeMethod('send', {'data': envelope});
      return true;
    } on PlatformException {
      return false;
    }
  }

  Future<void> setNames(Map<String, String> names) async {
    if (!supported) return;
    await _m.invokeMethod('names', {'names': names});
  }

  /// Peringatan jangkauan (native, tetap jalan saat layar mati) + ambang RSSI "melemah".
  /// [active] = hari konser sedang berjalan & tim belum dibubarkan: HP yang kehilangan internet tanpa HP tim di sekitar
  /// langsung diperingatkan walau belum pernah tersambung ke tim.
  Future<void> setReach({required bool enabled, required double weakDbm, int muteUntil = 0, bool active = false}) async {
    if (!supported) return;
    try {
      await _m.invokeMethod('reach', {'enabled': enabled, 'weak': weakDbm, 'mute': muteUntil, 'active': active});
    } catch (_) {}
  }

  /// Hash channel yang boleh ditampilkan HP ini: service memberi notifikasi (UI tertutup) hanya untuk channel ini.
  Future<void> setVisibleChannels(List<String> hashes, {String cid = ''}) async {
    if (!supported) return;
    try {
      await _m.invokeMethod('channels', {'list': hashes, 'cid': cid});
    } catch (_) {}
  }

  /// Status internet nyata (Firebase) + app di layar. Service memakainya untuk mendiamkan peringatan hanya saat benar-benar online.
  /// [online] null = belum tahu (Firebase masih menyambung): service memakai status lamanya, layar tetap dilaporkan.
  Future<void> setNet({required bool? online, required bool foreground}) async {
    if (!supported) return;
    try {
      await _m.invokeMethod('net', {'online': online, 'fg': foreground});
    } catch (_) {}
  }

  Future<void> setPowerSave(bool on) async {
    if (!supported) return;
    await _m.invokeMethod('powerSave', {'on': on});
  }

  /// Envelope yang diterima service saat UI belum berjalan.
  Future<List<Uint8List>> drainInbox() async {
    if (!supported) return const [];
    final l = await _m.invokeMethod<List>('drain');
    return (l ?? const []).cast<Uint8List>();
  }

  Future<Map> status() async {
    if (!supported) return const {};
    return (await _m.invokeMethod<Map>('status')) ?? const {};
  }

  // ---------------- Mode Jembatan iPhone

  /// Hasil: {ssid, pass, ip, port, url}
  Future<Map> bridgeStart() async {
    _listen();
    return (await _m.invokeMethod<Map>('bridgeStart')) ?? const {};
  }

  Future<void> bridgeStop() => _m.invokeMethod('bridgeStop');

  Future<void> bridgeReply(String client, String json) => _m.invokeMethod('bridgeReply', {'client': client, 'data': json});

  Future<void> bridgeKick(String client) => _m.invokeMethod('bridgeKick', {'client': client});

  /// Link gabung sudah boleh membuka app langsung (Android 12+: domain terverifikasi / dipilih pengguna)?
  Future<bool> linkEnabled() async {
    if (!supported) return true;
    try {
      return (await _m.invokeMethod<bool>('linkStatus')) ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Bluetooth HP sedang nyala?
  Future<bool> bluetoothOn() async {
    if (!supported) return true;
    try {
      return (await _m.invokeMethod<bool>('btOn')) ?? true;
    } catch (_) {
      return true;
    }
  }

  Future<void> openBluetoothSettings() async {
    if (!supported) return;
    try {
      await _m.invokeMethod('btSettings');
    } catch (_) {}
  }

  /// Buka pengaturan "Buka secara default" app ini.
  Future<void> openLinkSettings() async {
    if (!supported) return;
    try {
      await _m.invokeMethod('linkSettings');
    } catch (_) {}
  }

  /// Merek HP (huruf kecil), mis. "xiaomi", "oppo".
  Future<String> brand() async {
    if (!supported) return '';
    try {
      return (await _m.invokeMethod<String>('brand')) ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Buka layar Autostart vendor. false = tidak ketemu, dibuka info aplikasi sebagai gantinya.
  Future<bool> openAutostart() async {
    if (!supported) return false;
    try {
      return (await _m.invokeMethod<bool>('autostart')) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> requestBatteryExemption() async {
    if (!supported) return;
    await _m.invokeMethod('batteryExempt');
  }
}
