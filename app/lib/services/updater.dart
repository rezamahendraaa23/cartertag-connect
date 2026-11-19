import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
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

  /// Buka unduhan APK di browser; Android lalu menawarkan pemasangan (update di atas versi lama).
  Future<void> download() async {
    final r = available;
    if (r == null) return;
    await launchUrl(Uri.parse(r.apkUrl), mode: LaunchMode.externalApplication);
  }

  Future<void> dismiss() async {
    final r = available;
    if (r != null) await Store.i.put('update_skip', r.version);
  }

  Future<bool> dismissed() async => available != null && (await Store.i.get<String>('update_skip')) == available!.version;
}
