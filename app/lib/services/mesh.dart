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
  final _bridge = StreamController<Map>.broadcast();
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
          _peers.add(peers);
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
  Future<void> send(Uint8List envelope) async {
    if (!supported || !running) return;
    try {
      await _m.invokeMethod('send', {'data': envelope});
    } on PlatformException {
      // service mati: outbox akan mencoba lagi
    }
  }

  Future<void> setNames(Map<String, String> names) async {
    if (!supported) return;
    await _m.invokeMethod('names', {'names': names});
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
