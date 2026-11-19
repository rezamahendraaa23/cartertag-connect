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
import 'services/my_ids_io.dart' if (dart.library.js_interop) 'services/my_ids_web.dart';
import 'services/notifier.dart';
import 'ui/onboarding.dart';
import 'ui/root.dart';

/// Push FCM saat app tertutup: hanya metadata (isi pesan terenkripsi), tampilkan notifikasi ringkas.
@pragma('vm:entry-point')
Future<void> _fcmBackground(RemoteMessage m) async {
  final d = m.data;
  // pengirim ikut berlangganan topik: abaikan push dari diri sendiri
  if ((await readMyIdsFile()).contains('${d['from'] ?? ''}')) return;
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
    // ID sama dengan notifikasi dari app (Notifier.notifId) supaya pesan yang juga masuk lewat jalur realtime tidak dobel
    id: kind == 'sos' ? Notifier.sosId : Notifier.notifId(kind == 'msg' ? 'chat:${d['ch'] ?? 'g'}' : 'info'),
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
    const route = MethodChannel('ct/route');
    route.setMethodCallHandler((call) async {
      if (call.method == 'open') Hub.i.pendingRoute.value = '${call.arguments}';
    });
    Hub.i.pendingRoute.addListener(_onRoute);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (kIsWeb) {
        // halaman web dibuka dari link gabung: https://cartertag-connect.web.app/join?kode=CT-XXXXXX
        final u = Uri.base;
        if (u.path.startsWith('/join')) Hub.i.pendingRoute.value = 'join:${u.queryParameters['kode'] ?? u.queryParameters['k'] ?? ''}';
      } else {
        try {
          final r = await route.invokeMethod<String>('initial');
          if (r != null) Hub.i.pendingRoute.value = r;
        } catch (_) {}
      }
    });
  }

  /// Link gabung "join:CT-XXXXXX": buka form Gabung dengan kode terisi dan langsung jalan (seperti scan QR).
  void _onRoute() {
    final r = Hub.i.pendingRoute.value;
    if (r == null || !r.startsWith('join:')) return;
    Hub.i.pendingRoute.value = null;
    final code = r.substring(5);
    final ctx = navKey.currentContext;
    if (ctx == null) return;
    openPermissionsThen(ctx, JoinScreen(initialCode: code, auto: code.isNotEmpty));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navKey,
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
final navKey = GlobalKey<NavigatorState>();
final textScale = ValueNotifier<double>(1.0);
