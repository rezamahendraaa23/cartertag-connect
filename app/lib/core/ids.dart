import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

final _rnd = Random.secure();

/// UUIDv7 (16 byte): 48 bit waktu ms + acak. Urut waktu, jadi enak dipakai sebagai kunci pesan.
Uint8List newIdBytes() {
  final b = Uint8List(16);
  final ms = DateTime.now().millisecondsSinceEpoch;
  for (var i = 0; i < 6; i++) {
    b[i] = (ms >> (8 * (5 - i))) & 0xff;
  }
  for (var i = 6; i < 16; i++) {
    b[i] = _rnd.nextInt(256);
  }
  b[6] = (b[6] & 0x0f) | 0x70;
  b[8] = (b[8] & 0x3f) | 0x80;
  return b;
}

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List unhex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String newId() => hex(newIdBytes());

/// 08xx / +62 8xx / 8xx -> 628xx. Kosong kalau tidak valid. Sama dengan connectHp_ di GAS.
String normHp(String input) {
  var d = input.replaceAll(RegExp(r'\D'), '');
  if (d.startsWith('0')) {
    d = '62${d.substring(1)}';
  } else if (d.startsWith('8')) {
    d = '62$d';
  }
  return RegExp(r'^62\d{8,13}$').hasMatch(d) ? d : '';
}

Future<Uint8List> sha256(List<int> data) async =>
    Uint8List.fromList((await Sha256().hash(data)).bytes);

/// member_id = m_ + 10 karakter base32 dari SHA-256(slug|hp). Sama persis dengan connectMemberId_ di GAS.
Future<String> memberIdFor(String slug, String hp) async {
  final d = await sha256(utf8.encode('$slug|$hp'));
  const alpha = 'abcdefghijklmnopqrstuvwxyz234567';
  var bits = 0, val = 0;
  final out = StringBuffer();
  for (var i = 0; i < d.length && out.length < 10; i++) {
    val = ((val << 8) | d[i]) & 0xffffffff;
    bits += 8;
    while (bits >= 5 && out.length < 10) {
      out.write(alpha[(val >> (bits - 5)) & 31]);
      bits -= 5;
    }
  }
  return 'm_$out';
}

/// ID konser di header envelope (8 byte): HP dari konser lain mengabaikan envelope ini.
Future<Uint8List> concertCid(String slug) async =>
    Uint8List.sublistView(await sha256(utf8.encode('ct|$slug')), 0, 8);

/// Hash channel (8 byte) di header: relay tidak tahu nama channel, penerima mencocokkan.
Future<Uint8List> channelHash(String slug, String channelId) async =>
    Uint8List.sublistView(await sha256(utf8.encode('$slug|$channelId')), 0, 8);

/// Channel DM: d:<mid kecil>:<mid besar>.
String dmChannel(String a, String b) {
  final l = [a, b]..sort();
  return 'd:${l[0]}:${l[1]}';
}

String formatCode(String c) => c.isEmpty ? '' : 'CT-${c.toUpperCase()}';
