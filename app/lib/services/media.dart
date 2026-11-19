import 'dart:convert';
import 'dart:typed_data';

import '../core/crypto.dart';
import 'api.dart';
import 'hub.dart';
import 'online.dart';

/// Foto & voice note: dienkripsi dengan kunci channel, disimpan di Google Drive lewat GAS (gratis).
/// Butuh internet. Tanpa internet, hanya teks yang dikirim (PRD M2.6).
class Media {
  Media._();
  static final i = Media._();

  final _cache = <String, Uint8List>{};

  bool get canUpload => Online.i.connected || Hub.i.netUp;

  Future<void> send(String channel, Uint8List bytes, {required String kind, required String mime, int? durMs, bool ptt = false, String text = ''}) async {
    final c = Hub.i.concert!;
    final key = await Hub.i.keyFor(channel);
    if (key == null) throw StateError('Kunci lawan bicara belum ada.');
    final sealed = await sealBytes(bytes, key);
    final res = await Api.call('media_upload', {'member_token': c.token, 'b64': base64Encode(sealed), 'mime': mime},
        timeout: const Duration(seconds: 60));
    final id = '${res['file_id']}';
    _cache[id] = bytes;
    await Hub.i.sendMedia(channel, {'kind': kind, 'file': id, 'mime': mime, 'size': bytes.length, 'dur': durMs, 'ptt': ptt}, text: text);
  }

  Future<Uint8List?> get(String channel, String fileId) async {
    final hit = _cache[fileId];
    if (hit != null) return hit;
    final c = Hub.i.concert!;
    final key = await Hub.i.keyFor(channel);
    if (key == null) return null;
    final res = await Api.call('media_get', {'member_token': c.token, 'file_id': fileId}, timeout: const Duration(seconds: 60));
    final plain = await openBytes(base64Decode('${res['b64']}'), key);
    if (plain != null) {
      if (_cache.length > 40) _cache.remove(_cache.keys.first);
      _cache[fileId] = plain;
    }
    return plain;
  }
}
