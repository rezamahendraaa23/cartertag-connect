import 'dart:convert';
import 'dart:typed_data';

import 'package:cartertag_connect/core/crypto.dart';
import 'package:cartertag_connect/core/envelope.dart';
import 'package:cartertag_connect/core/ids.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('member_id sama dengan GAS (connectMemberId_)', () async {
    // nilai acuan dihitung dari algoritma Connect.gs di Node
    expect(await memberIdFor('bts-jakarta-2026', '6281234567890'), 'm_75lz5yvu4k');
  });

  test('normHp menormalkan format nomor', () {
    expect(normHp('0812-3456-7890'), '6281234567890');
    expect(normHp('+62 812 3456 7890'), '6281234567890');
    expect(normHp('812 3456 7890'), '6281234567890');
    expect(normHp('12345'), '');
  });

  test('envelope encode/decode bolak-balik + relay tidak merusak tanda tangan', () async {
    final groupKey = SecretKey(List.generate(32, (i) => i));
    final ed = await Ed25519().newKeyPairFromSeed(List.generate(32, (i) => 255 - i));
    final pubEd = Uint8List.fromList((await ed.extractPublicKey()).bytes);
    final id = newIdBytes();
    final cid = await concertCid('bts-jakarta-2026');
    final ch = await channelHash('bts-jakarta-2026', 'g');
    final payload = {'k': 'text', 'text': 'Halo tim, titik jemput pindah ke Gate 5', 'ch': 'g'};

    final env = Envelope(type: EType.chat, prio: 0, ttl: 5, id: id, cid: cid, ch: ch, from: 'm_75lz5yvu4k', ts: 1763520000000, body: Uint8List(sealedLength(payload)));
    final sealed = Envelope(type: EType.chat, prio: 0, ttl: 5, id: id, cid: cid, ch: ch, from: 'm_75lz5yvu4k', ts: env.ts, body: await sealBody(payload, groupKey, env.aad));
    sealed.sig = Uint8List.fromList((await Ed25519().sign(sealed.signedBytes, keyPair: ed)).bytes);

    final bytes = sealed.encode();
    expect(bytes.length, Envelope.headerLen + sealed.body.length + Envelope.sigLen);

    // relay menaikkan hop: tanda tangan & dekripsi harus tetap sah
    final relayed = Envelope.decode(bytes)!.copyForRelay();
    final back = Envelope.decode(relayed.encode())!;
    expect(back.hop, 1);
    expect(back.ttl, 5);
    expect(back.from, 'm_75lz5yvu4k');
    expect(back.idHex, hex(id));
    expect(await DeviceKeys.verify(back.signedBytes, back.sig, pubEd), isTrue);
    final open = await openBody(back.body, groupKey, back.aad);
    expect(open?['text'], payload['text']);

    // kunci salah / body diubah -> ditolak
    expect(await openBody(back.body, SecretKey(List.filled(32, 7)), back.aad), isNull);
    final tampered = Uint8List.fromList(bytes)..[Envelope.headerLen + 20] ^= 1;
    final t = Envelope.decode(tampered)!;
    expect(await DeviceKeys.verify(t.signedBytes, t.sig, pubEd), isFalse);
  });

  test('kunci DM X25519 sama di kedua sisi', () async {
    final a = await X25519().newKeyPairFromSeed(List.filled(32, 1));
    final b = await X25519().newKeyPairFromSeed(List.filled(32, 2));
    final pa = await a.extractPublicKey(), pb = await b.extractPublicKey();
    final sa = await X25519().sharedSecretKey(keyPair: a, remotePublicKey: pb);
    final sb = await X25519().sharedSecretKey(keyPair: b, remotePublicKey: pa);
    expect(await sa.extractBytes(), await sb.extractBytes());
  });

  test('media terenkripsi bolak-balik', () async {
    final k = SecretKey(List.generate(32, (i) => i * 3 % 256));
    final data = utf8.encode('foto penumpang' * 100);
    final sealed = await sealBytes(data, k);
    expect(await openBytes(sealed, k), data);
    expect(await openBytes(sealed, SecretKey(List.filled(32, 0))), isNull);
  });

  test('dmChannel urutan stabil', () {
    expect(dmChannel('m_b', 'm_a'), 'd:m_a:m_b');
    expect(dmChannel('m_a', 'm_b'), 'd:m_a:m_b');
  });
}
