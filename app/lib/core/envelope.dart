import 'dart:convert';
import 'dart:typed_data';

import 'ids.dart';

/// Jenis envelope (byte ke-3 header). Mesh service (Kotlin) membaca nilai ini untuk notifikasi & prioritas.
class EType {
  static const chat = 1; // teks, pesan cepat, media
  static const ack = 2; // tanda sampai / dibaca (DM, pengumuman, SOS)
  static const loc = 3; // lokasi berkala
  static const fleet = 4; // status armada
  static const ann = 5; // pengumuman
  static const rollcall = 6; // absen (mulai, jawab, tutup)
  static const sos = 7; // SOS (kirim, batal, menuju)
  static const checkin = 8; // check-in penumpang
  static const control = 9; // undangan, profil
}

class Prio {
  static const normal = 0;
  static const high = 1;
  static const sos = 2;
}

/// Format biner envelope (big-endian), identik dengan Envelope.kt:
///
/// ```
///  0  'C' 'T'        magic
///  2  version (1)
///  3  type           EType
///  4  prio           0 normal, 1 penting, 2 SOS
///  5  ttl            sisa lompatan maksimum
///  6  hop            sudah berapa lompatan (relay menaikkan)
///  7  flags          bit0 = DM
///  8  id   16 byte   UUIDv7
/// 24  cid   8 byte   SHA-256("ct|slug")[0..8]
/// 32  ch    8 byte   SHA-256("slug|channel")[0..8]
/// 40  from 12 byte   member_id ASCII (m_xxxxxxxxxx), dipad spasi
/// 52  ts    8 byte   ms epoch (waktu kirim di HP pengirim)
/// 60  len   2 byte   panjang body
/// 62  body           nonce(12) + ciphertext + tag(16)  (AES-256-GCM)
///     sig  64 byte   Ed25519 atas header (ttl & hop = 0) + body
/// ```
class Envelope {
  static const headerLen = 62;
  static const sigLen = 64;
  static const maxBody = 4096;

  final int type;
  final int prio;
  int ttl;
  int hop;
  final int flags;
  final Uint8List id;
  final Uint8List cid;
  final Uint8List ch;
  final String from;
  final int ts;
  final Uint8List body;
  Uint8List sig;

  Envelope({
    required this.type,
    required this.prio,
    required this.ttl,
    this.hop = 0,
    this.flags = 0,
    required this.id,
    required this.cid,
    required this.ch,
    required this.from,
    required this.ts,
    required this.body,
    Uint8List? sig,
  }) : sig = sig ?? Uint8List(sigLen);

  String get idHex => hex(id);
  bool get isDm => flags & 1 == 1;

  Uint8List _header({bool forSigning = false}) {
    final b = ByteData(headerLen);
    b.setUint8(0, 0x43);
    b.setUint8(1, 0x54);
    b.setUint8(2, 1);
    b.setUint8(3, type);
    b.setUint8(4, prio);
    b.setUint8(5, forSigning ? 0 : ttl);
    b.setUint8(6, forSigning ? 0 : hop);
    b.setUint8(7, flags);
    final out = b.buffer.asUint8List();
    out.setRange(8, 24, id);
    out.setRange(24, 32, cid);
    out.setRange(32, 40, ch);
    final f = ascii.encode(from.padRight(12).substring(0, 12));
    out.setRange(40, 52, f);
    b.setInt64(52, ts);
    b.setUint16(60, body.length);
    return out;
  }

  /// AAD untuk AES-GCM: header tanpa ttl/hop (relay boleh mengubah keduanya).
  Uint8List get aad => _header(forSigning: true);

  /// Data yang ditandatangani.
  Uint8List get signedBytes => Uint8List.fromList([..._header(forSigning: true), ...body]);

  Uint8List encode() => Uint8List.fromList([..._header(), ...body, ...sig]);

  static Envelope? decode(Uint8List data) {
    if (data.length < headerLen + sigLen) return null;
    if (data[0] != 0x43 || data[1] != 0x54 || data[2] != 1) return null;
    final b = ByteData.sublistView(data);
    final len = b.getUint16(60);
    if (len > maxBody || data.length != headerLen + len + sigLen) return null;
    return Envelope(
      type: data[3],
      prio: data[4],
      ttl: data[5],
      hop: data[6],
      flags: data[7],
      id: Uint8List.fromList(data.sublist(8, 24)),
      cid: Uint8List.fromList(data.sublist(24, 32)),
      ch: Uint8List.fromList(data.sublist(32, 40)),
      from: ascii.decode(data.sublist(40, 52), allowInvalid: true).trim(),
      ts: b.getInt64(52),
      body: Uint8List.fromList(data.sublist(headerLen, headerLen + len)),
      sig: Uint8List.fromList(data.sublist(headerLen + len)),
    );
  }

  /// Envelope dengan header yang aman diubah relay; body & tanda tangan tetap.
  Envelope copyForRelay() => Envelope(
        type: type,
        prio: prio,
        ttl: ttl,
        hop: hop + 1,
        flags: flags,
        id: id,
        cid: cid,
        ch: ch,
        from: from,
        ts: ts,
        body: body,
        sig: sig,
      );
}

/// TTL default per jenis (PRD Sistem §8.3).
int defaultTtl(int type, int prio) {
  if (prio >= Prio.sos) return 8;
  if (type == EType.loc) return 2;
  return 5;
}
