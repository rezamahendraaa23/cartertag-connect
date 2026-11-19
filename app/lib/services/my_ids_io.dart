import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// File kecil berisi member_id saya (semua konser), dibaca handler push latar tanpa membuka database.
Future<File> _file() async => File('${(await getApplicationSupportDirectory()).path}/my_ids.json');

Future<void> writeMyIdsFile(List<String> ids) async => (await _file()).writeAsString(jsonEncode(ids));

Future<Set<String>> readMyIdsFile() async {
  try {
    final f = await _file();
    if (!await f.exists()) return {};
    return ((jsonDecode(await f.readAsString()) as List?) ?? const []).map((e) => '$e').toSet();
  } catch (_) {
    return {};
  }
}
