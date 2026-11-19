import 'dart:async';
import 'dart:math';

import 'package:geolocator/geolocator.dart';

class Fix {
  Fix(this.lat, this.lng, this.acc, this.at);
  final double lat, lng, acc;
  final DateTime at;
}

/// GPS jalan tanpa internet. Interval kirim: 60 dtk (aktif), 5 mnt (latar/hemat), 10 dtk (SOS). PRD §8.8.
class LocationSvc {
  LocationSvc._();
  static final i = LocationSvc._();

  Fix? last;
  Timer? _t;
  void Function(Fix)? _onFix;
  bool _fg = true, _sos = false;
  bool denied = false;

  Duration get _interval => _sos ? const Duration(seconds: 10) : (_fg ? const Duration(seconds: 60) : const Duration(minutes: 5));

  void start({required void Function(Fix) onFix}) {
    _onFix = onFix;
    _schedule(first: true);
  }

  void stop() {
    _t?.cancel();
    _t = null;
  }

  void setForeground(bool fg) {
    if (_fg == fg) return;
    _fg = fg;
    _schedule();
  }

  void setSosMode(bool on) {
    _sos = on;
    _schedule(first: on);
  }

  void _schedule({bool first = false}) {
    if (_onFix == null) return;
    _t?.cancel();
    if (first) Future.delayed(const Duration(seconds: 2), _tick);
    _t = Timer.periodic(_interval, (_) => _tick());
  }

  Future<void> _tick() async {
    final f = await current();
    if (f != null) _onFix?.call(f);
  }

  Future<Fix?> current() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      // Hanya mengecek. Izin diminta sekali saja di layar onboarding, tidak pernah diminta ulang di sini.
      final p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied || p == LocationPermission.deniedForever) {
        denied = true;
        return null;
      }
      denied = false;
      final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 20)));
      return last = Fix(pos.latitude, pos.longitude, pos.accuracy, DateTime.now());
    } catch (_) {
      return last;
    }
  }
}

double _rad(double d) => d * pi / 180;

/// Jarak Haversine (meter).
double haversine(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  final dLat = _rad(lat2 - lat1), dLng = _rad(lng2 - lng1);
  final a = sin(dLat / 2) * sin(dLat / 2) + cos(_rad(lat1)) * cos(_rad(lat2)) * sin(dLng / 2) * sin(dLng / 2);
  return 2 * r * atan2(sqrt(a), sqrt(1 - a));
}

/// Arah dari titik 1 ke titik 2 (derajat dari utara, 0..360).
double bearing(double lat1, double lng1, double lat2, double lng2) {
  final y = sin(_rad(lng2 - lng1)) * cos(_rad(lat2));
  final x = cos(_rad(lat1)) * sin(_rad(lat2)) - sin(_rad(lat1)) * cos(_rad(lat2)) * cos(_rad(lng2 - lng1));
  return (atan2(y, x) * 180 / pi + 360) % 360;
}

String compassName(double deg) {
  const names = ['Utara', 'Timur Laut', 'Timur', 'Tenggara', 'Selatan', 'Barat Daya', 'Barat', 'Barat Laut'];
  return names[((deg + 22.5) % 360 ~/ 45)];
}

String fmtDistance(double m) => m < 1000 ? '${m.round()} m' : '${(m / 1000).toStringAsFixed(1)} km';
