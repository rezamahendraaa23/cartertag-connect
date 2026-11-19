import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'core/theme.dart';
import 'data/store.dart';
import 'services/hub.dart';
import 'ui/root.dart';

/// Push FCM saat app tertutup: hanya metadata (isi pesan terenkripsi), tampilkan notifikasi ringkas.
@pragma('vm:entry-point')
Future<void> _fcmBackground(RemoteMessage m) async {
  final d = m.data;
  final p = FlutterLocalNotificationsPlugin();
  await p.initialize(settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')));
  final kind = d['kind'] ?? 'msg';
  final from = d['from_name'] ?? 'Tim';
  final (title, body) = switch (kind) {
    'sos' => ('SOS dari $from', 'Buka untuk melihat arah & jarak'),
    'ann' => ('Pengumuman: ${d['title'] ?? ''}', 'Dari $from'),
    'rollcall' => ('Absen dari $from', 'Tandai kondisimu'),
    _ => (from, 'Pesan baru'),
  };
  await p.show(
    id: DateTime.now().millisecondsSinceEpoch ~/ 1000 % 100000,
    title: title,
    body: body,
    payload: kind == 'sos' ? 'sos' : (kind == 'msg' ? 'chat:${d['ch'] ?? 'g'}' : 'info'),
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(kind == 'sos' ? 'ct_sos' : (kind == 'msg' ? 'ct_msg' : 'ct_important'), kind == 'sos' ? 'SOS darurat' : 'Pesan',
          importance: Importance.max, priority: Priority.high, fullScreenIntent: kind == 'sos'),
    ),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Store.init();
  if (!kIsWeb) {
    FirebaseMessaging.onBackgroundMessage(_fcmBackground);
    // Firebase dipasang lebih awal kalau opsinya sudah tersimpan dari join sebelumnya.
    final saved = await Store.i.get<String>('fb_options');
    final dbUrl = await Store.i.get<String>('fb_db_url');
    if (saved != null && Firebase.apps.isEmpty) {
      try {
        final o = (jsonDecode(saved) as Map)['android'] as Map?;
        if (o != null) {
          await Firebase.initializeApp(
              options: FirebaseOptions(
                  apiKey: '${o['apiKey']}', appId: '${o['appId']}', messagingSenderId: '${o['messagingSenderId'] ?? ''}', projectId: '${o['projectId'] ?? ''}', databaseURL: dbUrl));
        }
      } catch (_) {}
    }
  }
  await Hub.i.boot();
  runApp(const ConnectApp());
}

class ConnectApp extends StatefulWidget {
  const ConnectApp({super.key});
  @override
  State<ConnectApp> createState() => _ConnectAppState();
}

class _ConnectAppState extends State<ConnectApp> {
  ThemeMode mode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    Store.i.get<String>('theme').then((t) {
      if (!mounted) return;
      setState(() => mode = switch (t) { 'light' => ThemeMode.light, 'dark' => ThemeMode.dark, _ => ThemeMode.system });
    });
    themeMode.addListener(() => setState(() => mode = themeMode.value));
    textScale.addListener(() => setState(() {}));
    Store.i.get<double>('text_scale').then((v) => textScale.value = v ?? 1.0);
    const MethodChannel('ct/route').setMethodCallHandler((call) async {
      if (call.method == 'open') Hub.i.pendingRoute.value = '${call.arguments}';
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CarterTag Connect',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: mode,
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        return MediaQuery(data: mq.copyWith(textScaler: TextScaler.linear(mq.textScaler.scale(1) * textScale.value)), child: child!);
      },
      home: const RootGate(),
    );
  }
}

final themeMode = ValueNotifier<ThemeMode>(ThemeMode.system);
final textScale = ValueNotifier<double>(1.0);
