import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'envelope.dart';

/// Identitas perangkat (X25519 untuk DM, Ed25519 untuk tanda tangan) + operasi enkripsi envelope.
class DeviceKeys {
  DeviceKeys._(this._x, this._ed, this.pubX, this.pubEd);

  final SimpleKeyPair _x;
  final SimpleKeyPair _ed;
  final Uint8List pubX;
  final Uint8List pubEd;

  String get pubXb64 => base64Encode(pubX);
  String get pubEdB64 => base64Encode(pubEd);

  static const _storage = FlutterSecureStorage();
  static DeviceKeys? _instance;

  /// Kunci dibuat sekali per perangkat, disimpan di Android Keystore (web: storage terenkripsi).
  static Future<DeviceKeys> load() async {
    if (_instance != null) return _instance!;
    var sx = await _storage.read(key: 'seed_x');
    var se = await _storage.read(key: 'seed_ed');
    if (sx == null || se == null) {
      final r = Random.secure();
      sx = base64Encode(List.generate(32, (_) => r.nextInt(256)));
      se = base64Encode(List.generate(32, (_) => r.nextInt(256)));
      await _storage.write(key: 'seed_x', value: sx);
      await _storage.write(key: 'seed_ed', value: se);
    }
    final x = await X25519().newKeyPairFromSeed(base64Decode(sx));
    final ed = await Ed25519().newKeyPairFromSeed(base64Decode(se));
    final px = Uint8List.fromList((await x.extractPublicKey()).bytes);
    final pe = Uint8List.fromList((await ed.extractPublicKey()).bytes);
    return _instance = DeviceKeys._(x, ed, px, pe);
  }

  Future<Uint8List> sign(Uint8List data) async =>
      Uint8List.fromList((await Ed25519().sign(data, keyPair: _ed)).bytes);

  static Future<bool> verify(Uint8List data, Uint8List sig, Uint8List pubEd) async {
    try {
      return await Ed25519().verify(data,
          signature: Signature(sig, publicKey: SimplePublicKey(pubEd, type: KeyPairType.ed25519)));
    } catch (_) {
      return false;
    }
  }

  final Map<String, SecretKey> _dmCache = {};

  /// Kunci DM = HKDF-SHA256(X25519(priv saya, pub dia), info "ct-dm").
  Future<SecretKey> dmKey(Uint8List peerPubX) async {
    final k = base64Encode(peerPubX);
    final hit = _dmCache[k];
    if (hit != null) return hit;
    final shared = await X25519().sharedSecretKey(
        keyPair: _x, remotePublicKey: SimplePublicKey(peerPubX, type: KeyPairType.x25519));
    final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
        .deriveKey(secretKey: shared, nonce: utf8.encode('cartertag-connect'), info: utf8.encode('ct-dm'));
    return _dmCache[k] = key;
  }
}

final _aes = AesGcm.with256bits();

/// Enkripsi payload ke body envelope: nonce(12) + ciphertext + tag(16).
Future<Uint8List> sealBody(Map<String, dynamic> payload, SecretKey key, Uint8List aad) async {
  final box = await _aes.encrypt(utf8.encode(jsonEncode(payload)), secretKey: key, aad: aad);
  return Uint8List.fromList([...box.nonce, ...box.cipherText, ...box.mac.bytes]);
}

Future<Map<String, dynamic>?> openBody(Uint8List body, SecretKey key, Uint8List aad) async {
  if (body.length < 28) return null;
  try {
    final box = SecretBox(body.sublist(12, body.length - 16),
        nonce: body.sublist(0, 12), mac: Mac(body.sublist(body.length - 16)));
    final plain = await _aes.decrypt(box, secretKey: key, aad: aad);
    final v = jsonDecode(utf8.decode(plain));
    return v is Map<String, dynamic> ? v : null;
  } catch (_) {
    return null;
  }
}

/// Enkripsi file media (foto/suara) sebelum diunggah: nonce(12) + ciphertext + tag(16).
Future<Uint8List> sealBytes(List<int> data, SecretKey key) async {
  final box = await _aes.encrypt(data, secretKey: key);
  return Uint8List.fromList([...box.nonce, ...box.cipherText, ...box.mac.bytes]);
}

Future<Uint8List?> openBytes(Uint8List data, SecretKey key) async {
  if (data.length < 28) return null;
  try {
    final box = SecretBox(data.sublist(12, data.length - 16), nonce: data.sublist(0, 12), mac: Mac(data.sublist(data.length - 16)));
    return Uint8List.fromList(await _aes.decrypt(box, secretKey: key));
  } catch (_) {
    return null;
  }
}

/// Panjang body hasil enkripsi untuk payload ini (AAD butuh panjang body sebelum enkripsi).
int sealedLength(Map<String, dynamic> payload) => 12 + utf8.encode(jsonEncode(payload)).length + 16;

/// Bangun envelope lengkap: header -> enkripsi (AAD = header) -> tanda tangan.
Future<Envelope> buildEnvelope({
  required DeviceKeys keys,
  required int type,
  required int prio,
  required Uint8List id,
  required Uint8List cid,
  required Uint8List ch,
  required String from,
  required Map<String, dynamic> payload,
  required SecretKey key,
  bool dm = false,
  int? ttl,
}) async {
  final env = Envelope(
    type: type,
    prio: prio,
    ttl: ttl ?? defaultTtl(type, prio),
    flags: dm ? 1 : 0,
    id: id,
    cid: cid,
    ch: ch,
    from: from,
    ts: DateTime.now().millisecondsSinceEpoch,
    body: Uint8List(sealedLength(payload)),
  );
  final body = await sealBody(payload, key, env.aad);
  final sealed = Envelope(
      type: env.type,
      prio: env.prio,
      ttl: env.ttl,
      flags: env.flags,
      id: id,
      cid: cid,
      ch: ch,
      from: from,
      ts: env.ts,
      body: body);
  sealed.sig = await keys.sign(sealed.signedBytes);
  return sealed;
}
