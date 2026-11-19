import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Notifikasi lokal: pesan, pengumuman, absen, dan alarm SOS layar penuh (PRD Sistem §9).
class Notifier {
  Notifier._();
  static final i = Notifier._();

  final _p = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  int _seq = 100;
  static const sosId = 7;

  static const _msg = AndroidNotificationChannel('ct_msg', 'Pesan', description: 'Chat grup & pribadi', importance: Importance.high);
  static const _imp = AndroidNotificationChannel('ct_important', 'Pengumuman & absen', description: 'Pengumuman koordinator dan absen', importance: Importance.max);
  static final _sos = AndroidNotificationChannel('ct_sos', 'SOS darurat',
      description: 'Alarm SOS, berbunyi walau mode senyap',
      importance: Importance.max,
      audioAttributesUsage: AudioAttributesUsage.alarm,
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 800, 400, 800, 400, 800]));

  Future<void> init({required void Function(String? route) onTap}) async {
    if (_ready) return;
    try {
      await _p.initialize(
        settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
        onDidReceiveNotificationResponse: (r) => onTap(r.payload),
      );
      final android = _p.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(_msg);
      await android?.createNotificationChannel(_imp);
      await android?.createNotificationChannel(_sos);
      // izin notifikasi diminta sekali di onboarding, bukan setiap app dibuka
      final launch = await _p.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp == true) onTap(launch!.notificationResponse?.payload);
      _ready = true;
    } catch (e) {
      debugPrint('Notifier.init: $e');
    }
  }

  Future<void> show({required String title, required String body, String? route, bool important = false}) async {
    if (!_ready) return;
    final ch = important ? _imp : _msg;
    await _p.show(
      id: _seq++,
      title: title,
      body: body,
      payload: route,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(ch.id, ch.name,
            channelDescription: ch.description, importance: ch.importance, priority: important ? Priority.max : Priority.high, category: AndroidNotificationCategory.message),
      ),
    );
  }

  /// Alarm SOS layar penuh: kategori alarm, bunyi walau senyap, getar berulang.
  Future<void> sos({required String title, required String body, String? route}) async {
    if (!_ready) return;
    await _p.show(
      id: sosId,
      title: title,
      body: body,
      payload: route,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(_sos.id, _sos.name,
            channelDescription: _sos.description,
            importance: Importance.max,
            priority: Priority.max,
            category: AndroidNotificationCategory.alarm,
            fullScreenIntent: true,
            audioAttributesUsage: AudioAttributesUsage.alarm,
            ongoing: true,
            autoCancel: false,
            additionalFlags: Int32List.fromList([4]), // FLAG_INSISTENT: bunyi berulang sampai dibuka
            vibrationPattern: _sos.vibrationPattern),
      ),
    );
  }

  Future<void> cancelSos() async {
    if (!_ready) return;
    await _p.cancel(id: sosId);
  }
}
