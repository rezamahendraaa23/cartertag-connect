/// Model ringan di atas Map hasil API/sembast. Field mengikuti respons GAS (Connect.gs).
library;

class Member {
  Member(this.m);
  final Map<String, dynamic> m;

  String get id => m['mid'] as String? ?? '';
  String get name => m['n'] as String? ?? '';
  String get role => m['r'] as String? ?? 'panitia';
  String get car => m['car'] as String? ?? '';
  List<String> get cars => ((m['cars'] as List?) ?? const []).map((e) => '$e').toList();
  String get area => m['area'] as String? ?? '';
  String get plat => m['plat'] as String? ?? '';
  String get hp => m['hp'] as String? ?? '';
  String get pubX => m['px'] as String? ?? '';
  String get pubEd => m['pe'] as String? ?? '';
  String get status => m['st'] as String? ?? '';
  bool get isDriver => role == 'driver';
  bool get isKoord => role == 'koordinator';
  bool get joined => pubEd.isNotEmpty;

  /// Label untuk tag di grup: driver = "Mobil 3", lainnya = nama.
  String get tagLabel => isDriver && car.isNotEmpty ? carLabel : name;

  /// Nomor mobil untuk ditampilkan: "3" -> "C3" (yang sudah berhuruf dibiarkan).
  String get carLabel => carName(car);

  /// Cocok dengan pencarian nama atau nomor mobil ("3", "mobil 3", "m3").
  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final carQ = q.replaceFirst(RegExp(r'^(mobil|m|c)\s*'), '');
    if (car.isNotEmpty && carQ.isNotEmpty && car.toLowerCase().startsWith(carQ)) return true;
    final pq = q.replaceAll(' ', '');
    return name.toLowerCase().contains(q) || (pq.length >= 3 && plat.toLowerCase().replaceAll(' ', '').contains(pq));
  }

  String get roleLabel => switch (role) {
        'driver' => car.isNotEmpty ? 'Driver ${carName(car)}' : 'Driver',
        'koordinator' => 'Koordinator',
        _ => 'Panitia',
      };

  String get initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts[0].substring(0, 1).toUpperCase();
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }
}

/// "3" -> "C3"; "C3"/"c3" -> "C3"; kosong tetap kosong.
String carName(String car) {
  final c = car.trim();
  if (c.isEmpty) return '';
  return RegExp(r'^[A-Za-z]').hasMatch(c) ? c.toUpperCase() : 'C$c';
}

/// Angka saja dari input nomor mobil ("C3" / "c 3" / "3" -> "3"), cocok dengan kolom No di Plotingan.
String carDigits(String input) => input.trim().replaceFirst(RegExp(r'^(mobil|m|c)\s*', caseSensitive: false), '').trim();

class ManifestRow {
  ManifestRow(this.m);
  final Map<String, dynamic> m;
  String get orderId => '${m['order_id'] ?? ''}';
  String get car => '${m['car'] ?? ''}';
  String get name => '${m['nama'] ?? ''}';
  int get pax => (m['pax'] as num?)?.toInt() ?? 1;
  String get wa => '${m['wa'] ?? ''}';
  String get area => '${m['area'] ?? ''}';
  String get titik => '${m['titik'] ?? ''}';
  String get jam => '${m['jam'] ?? ''}';
  String get trip => '${m['trip'] ?? ''}';
  String get hari => '${m['hari'] ?? ''}';
  String get catatan => '${m['catatan'] ?? ''}';

  /// PP = pergi & pulang, One Way Pergi/Pulang = salah satu (sama dengan plotLegs_ di Plotting.gs).
  bool hasLeg(String leg) {
    final t = trip.toLowerCase();
    if (t.contains('pulang') && !t.contains('pergi') && t.contains('one')) return leg == 'pulang';
    if (t.contains('pergi') && t.contains('one')) return leg == 'pergi';
    return true;
  }
}

class Concert {
  Concert(this.b);
  final Map<String, dynamic> b;

  Map<String, dynamic> get _k => (b['konser'] as Map?)?.cast<String, dynamic>() ?? const {};
  String get slug => _k['slug'] as String? ?? '';
  String get name => _k['nama'] as String? ?? '';
  String get venue => _k['venue'] as String? ?? '';
  List<String> get dates => ((_k['dates'] as List?) ?? const []).map((e) => '$e').toList();
  int get epoch => (b['epoch'] as num?)?.toInt() ?? 0;
  String get groupKey => b['group_key'] as String? ?? '';
  String get token => b['member_token'] as String? ?? '';
  Member get me => Member((b['member'] as Map).cast<String, dynamic>());
  List<Member> get roster =>
      ((b['roster'] as List?) ?? const []).map((e) => Member((e as Map).cast<String, dynamic>())).toList();
  Map<String, dynamic>? get firebase => (b['firebase'] as Map?)?.cast<String, dynamic>();
  Map<String, dynamic> get manifestRaw => (b['manifest'] as Map?)?.cast<String, dynamic>() ?? const {'enabled': false, 'rows': []};
  bool get manifestEnabled => manifestRaw['enabled'] == true;
  String get manifestSource => '${manifestRaw['source'] ?? ''}';
  String get manifestUpdated => '${manifestRaw['updatedAt'] ?? ''}';
  List<ManifestRow> get manifest =>
      ((manifestRaw['rows'] as List?) ?? const []).map((e) => ManifestRow((e as Map).cast<String, dynamic>())).toList();
  Map<String, dynamic> get app => (b['app'] as Map?)?.cast<String, dynamic>() ?? const {};
  bool get verified => b['unverified'] != true;

  Member? member(String id) {
    for (final m in roster) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// Daftar area dari driver/mobil (untuk channel area).
  List<String> get areas {
    final s = <String>{};
    for (final m in roster) {
      if (m.area.trim().isNotEmpty) s.add(m.area.trim());
    }
    return s.toList()..sort();
  }

  /// Daftar mobil: nomor -> driver.
  Map<String, Member> get carsMap {
    final out = <String, Member>{};
    for (final m in roster) {
      if (!m.isDriver) continue;
      for (final c in (m.cars.isEmpty ? [m.car] : m.cars)) {
        if (c.isNotEmpty) out[c] = m;
      }
    }
    return out;
  }
}

/// Channel chat. id: 'g' (grup konser), 'k' (koordinator), 'a:<area>', 'd:<mid>:<mid>'.
class Channel {
  Channel(this.id, this.title, {this.subtitle = '', this.peer});
  final String id;
  final String title;
  final String subtitle;
  final Member? peer;
  bool get isDm => id.startsWith('d:');
}

/// Status perjalanan armada (PRD Sistem §8.5).
const fleetSteps = ['siap', 'menuju', 'di_titik', 'berangkat', 'tiba', 'selesai'];
const fleetLabels = {
  'siap': 'Siap',
  'menuju': 'Menuju titik jemput',
  'di_titik': 'Di titik jemput',
  'berangkat': 'Berangkat',
  'tiba': 'Tiba',
  'selesai': 'Selesai',
  'kendala': 'Kendala',
};
const fleetShort = {
  'siap': 'Siap',
  'menuju': 'Menuju',
  'di_titik': 'Di titik',
  'berangkat': 'Berangkat',
  'tiba': 'Tiba',
  'selesai': 'Selesai',
  'kendala': 'Kendala',
};
