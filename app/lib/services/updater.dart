import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/store.dart';
import 'hub.dart';

/// Info rilis terbaru di GitHub.
class Release {
  Release(this.version, this.apkUrl, this.notes, this.pageUrl);
  final String version;
  final String apkUrl;
  final String notes;
  final String pageUrl;
}

/// Cek pembaruan dari GitHub Releases (rezamahendraaa23/cartertag-connect).
/// Otomatis paling sering sekali per 6 jam saat ada internet; manual lewat menu Saya.
class Updater extends ChangeNotifier {
  Updater._();
  static final i = Updater._();

  static const repo = 'rezamahendraaa23/cartertag-connect';
  Release? available;
  bool checking = false;

  /// Unduhan dalam app: null = tidak sedang mengunduh; 0..1 = progres.
  double? progress;
  String? error;
  String? _apkPath;
  static const _ch = MethodChannel('ct/update');

  /// "1.2.10" > "1.2.9"
  static int compare(String a, String b) {
    List<int> p(String v) => v.replaceAll(RegExp(r'^[vV]'), '').split(RegExp(r'[.+-]')).map((x) => int.tryParse(x) ?? 0).toList();
    final x = p(a), y = p(b);
    for (var k = 0; k < 3; k++) {
      final d = (k < x.length ? x[k] : 0) - (k < y.length ? y[k] : 0);
      if (d != 0) return d;
    }
    return 0;
  }

  /// [force] = abaikan jeda 6 jam (tombol "Cek pembaruan"). Mengembalikan rilis baru atau null.
  Future<Release?> check({bool force = false}) async {
    if (kIsWeb || checking) return available;
    final last = (await Store.i.get<int>('update_checked')) ?? 0;
    if (!force && DateTime.now().millisecondsSinceEpoch - last < 6 * 3600000) return available;
    checking = true;
    notifyListeners();
    try {
      final res = await http
          .get(Uri.parse('https://api.github.com/repos/$repo/releases/latest'), headers: {'Accept': 'application/vnd.github+json'})
          .timeout(const Duration(seconds: 15));
      await Store.i.put('update_checked', DateTime.now().millisecondsSinceEpoch);
      if (res.statusCode != 200) return available;
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final tag = '${j['tag_name'] ?? ''}';
      final assets = ((j['assets'] as List?) ?? const []).cast<Map>();
      // utamakan APK arm64 (hampir semua HP), lalu armeabi-v7a, lalu APK apa pun
      String url = '';
      for (final pref in ['arm64-v8a', 'armeabi-v7a', '.apk']) {
        final hit = assets.where((a) => '${a['name']}'.contains(pref) && '${a['name']}'.endsWith('.apk')).toList();
        if (hit.isNotEmpty) {
          url = '${hit.first['browser_download_url']}';
          break;
        }
      }
      final current = Hub.i.appVersion;
      if (tag.isNotEmpty && url.isNotEmpty && current.isNotEmpty && compare(tag, current) > 0) {
        available = Release(tag.replaceAll(RegExp(r'^[vV]'), ''), url, '${j['body'] ?? ''}', '${j['html_url'] ?? ''}');
      } else {
        available = null;
      }
      return available;
    } catch (_) {
      return available;
    } finally {
      checking = false;
      notifyListeners();
    }
  }

  /// Unduh APK di dalam app (dengan progres), lalu buka layar pemasangan Android. Tanpa browser.
  Future<void> download() async {
    final r = available;
    if (r == null || progress != null) return;
    if (downloaded && _apkPath!.contains(r.version)) return install();
    if (kIsWeb) {
      await launchUrl(Uri.parse(r.apkUrl), mode: LaunchMode.externalApplication);
      return;
    }
    error = null;
    progress = 0;
    notifyListeners();
    final client = http.Client();
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
      await dir.create(recursive: true);
      final file = File('${dir.path}/CarterTag-Connect-${r.version}.apk');
      final res = await client.send(http.Request('GET', Uri.parse(r.apkUrl))).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      final total = res.contentLength ?? 0;
      final sink = file.openWrite();
      var got = 0, lastNotify = 0;
      await for (final chunk in res.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0 && got - lastNotify > 256 * 1024) {
          lastNotify = got;
          progress = got / total;
          notifyListeners();
        }
      }
      await sink.close();
      if (total > 0 && got < total) throw const HttpException('Unduhan terputus');
      _apkPath = file.path;
      progress = 1;
      notifyListeners();
      await install();
    } catch (e) {
      error = 'Gagal mengunduh: $e';
    } finally {
      client.close();
      progress = null;
      notifyListeners();
    }
  }

  /// Serahkan APK ke installer. Izin "pasang dari sumber ini" belum ada -> buka pengaturannya,
  /// lalu pasang otomatis begitu pengguna kembali ke app.
  Future<void> install() async {
    final path = _apkPath;
    if (path == null) return;
    final can = await _ch.invokeMethod<bool>('canInstall') ?? true;
    if (!can) {
      await _ch.invokeMethod('allowInstall');
      _waitResume();
      return;
    }
    await _ch.invokeMethod('install', {'path': path});
  }

  void _waitResume() {
    late final AppLifecycleListener l;
    l = AppLifecycleListener(onResume: () async {
      l.dispose();
      if (await _ch.invokeMethod<bool>('canInstall') == true) {
        await _ch.invokeMethod('install', {'path': _apkPath});
      } else {
        error = 'Izinkan "Pasang aplikasi tidak dikenal" untuk CarterTag Connect, lalu ketuk Update lagi.';
        notifyListeners();
      }
    });
  }

  /// APK sudah terunduh (mis. pemasangan dibatalkan): bisa langsung dipasang ulang tanpa unduh lagi.
  bool get downloaded => _apkPath != null && File(_apkPath!).existsSync();

  Future<void> dismiss() async {
    final r = available;
    if (r != null) await Store.i.put('update_skip', r.version);
  }

  Future<bool> dismissed() async => available != null && (await Store.i.get<String>('update_skip')) == available!.version;
}
