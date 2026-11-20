import 'dart:convert';

import 'package:http/http.dart' as http;

import '../data/store.dart';

/// Klien API GAS (Connect.gs). URL exec diisi saat build (--dart-define=CONNECT_API=...) atau di layar Gabung.
class Api {
  static const _builtIn = String.fromEnvironment('CONNECT_API');

  static Future<String> baseUrl() async {
    final saved = await Store.i.get<String>('api_url');
    if (saved != null && saved.isNotEmpty) return saved;
    return _builtIn;
  }

  static Future<void> setBaseUrl(String url) => Store.i.put('api_url', url.trim());

  /// POST {action, ...}. Content-Type text/plain supaya browser tidak mengirim preflight CORS ke Apps Script.
  static Future<Map<String, dynamic>> call(String action, Map<String, dynamic> body,
      {Duration timeout = const Duration(seconds: 25)}) async {
    final base = await baseUrl();
    if (base.isEmpty) throw ApiError('config', 'Alamat server belum diatur.');
    final uri = Uri.parse(base.contains('?') ? '$base&api=connect' : '$base?api=connect');
    http.Response res;
    try {
      res = await http
          .post(uri, headers: {'Content-Type': 'text/plain;charset=utf-8'}, body: jsonEncode({...body, 'action': action}))
          .timeout(timeout);
      // Apps Script membalas 302 ke googleusercontent; http di Android mengikuti otomatis untuk GET saja.
      if (res.statusCode == 302 || res.statusCode == 303) {
        final loc = res.headers['location'];
        if (loc != null) res = await http.get(Uri.parse(loc)).timeout(timeout);
      }
    } catch (e) {
      throw ApiError('network', 'Tidak bisa terhubung ke server. Cek sinyal.');
    }
    Map<String, dynamic> j;
    try {
      j = (jsonDecode(res.body) as Map).cast<String, dynamic>();
    } catch (_) {
      throw ApiError('server', 'Balasan server tidak dikenali (${res.statusCode}).');
    }
    if (j['ok'] == true) return (j['data'] as Map? ?? {}).cast<String, dynamic>();
    final err = (j['error'] as Map? ?? {}).cast<String, dynamic>();
    throw ApiError('${err['code'] ?? 'server'}', '${err['message'] ?? 'Terjadi kesalahan.'}');
  }
}

class ApiError implements Exception {
  ApiError(this.code, this.message);
  final String code;
  final String message;
  bool get isNetwork => code == 'network';
  bool get isAuth => code == 'auth' || isKick;

  /// Sesi sudah tidak sah untuk selamanya: kode diperbarui, tim ditutup, dikeluarkan, atau sudah keluar.
  bool get isKick => code == 'reset' || code == 'closed' || code == 'removed' || code == 'left';
  @override
  String toString() => message;
}
