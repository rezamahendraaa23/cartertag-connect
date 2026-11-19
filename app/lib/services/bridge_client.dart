import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Klien Mode Jembatan (PWA di iPhone/laptop): tersambung ke server WebSocket di HP Android host
/// lewat Wi-Fi Direct (http://192.168.49.1:8787). Dipakai hanya di web.
class Bridge {
  Bridge._();
  static final i = Bridge._();

  WebSocketChannel? _ws;
  bool connected = false;
  bool approved = false;
  String? hostName;
  final _env = StreamController<Uint8List>.broadcast();
  final _state = StreamController<String>.broadcast();
  final _ctl = StreamController<Map<String, dynamic>>.broadcast();

  Stream<Uint8List> get envelopes => _env.stream;
  Stream<String> get state => _state.stream;

  /// Pesan kontrol dari host: welcome {bundle, host}, denied {reason}.
  Stream<Map<String, dynamic>> get control => _ctl.stream;

  /// Halaman dibuka dari server lokal HP Android (bukan hosting online)?
  bool get isLocalOrigin {
    if (!kIsWeb) return false;
    final h = Uri.base.host;
    return Uri.base.port == 8787 || RegExp(r'^(192\.168|10\.|172\.(1[6-9]|2\d|3[01]))').hasMatch(h);
  }

  /// Token sekali pakai dari QR-2 (#t=...).
  String get urlToken {
    final f = Uri.base.fragment;
    final m = RegExp(r't=([A-Za-z0-9_-]+)').firstMatch(f);
    return m?.group(1) ?? '';
  }

  void autoConnect() {
    if (isLocalOrigin) connect();
  }

  void connect() {
    if (_ws != null) return;
    final url = Uri(scheme: 'ws', host: Uri.base.host, port: Uri.base.port, path: '/ws');
    try {
      _ws = WebSocketChannel.connect(url);
      _ws!.stream.listen((data) {
        if (data is String) {
          final j = jsonDecode(data);
          if (j is Map<String, dynamic>) {
            if (j['t'] == 'welcome') {
              approved = true;
              hostName = '${j['host'] ?? ''}';
            }
            _ctl.add(j);
          }
        } else if (data is List<int>) {
          _env.add(Uint8List.fromList(data));
        }
      }, onDone: _closed, onError: (_) => _closed());
      connected = true;
      _state.add('open');
    } catch (_) {
      _closed();
    }
  }

  void _closed() {
    _ws = null;
    connected = false;
    approved = false;
    _state.add('closed');
    // coba lagi tiap 5 detik selama halaman berasal dari host lokal
    if (isLocalOrigin) Future.delayed(const Duration(seconds: 5), connect);
  }

  void hello(Map<String, dynamic> data) => _ws?.sink.add(jsonEncode({'t': 'hello', ...data}));

  void send(Uint8List envelope) {
    if (!connected || !approved) return;
    _ws?.sink.add(envelope);
  }
}
