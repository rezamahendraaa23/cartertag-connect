import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/bridge_client.dart';
import '../services/hub.dart';
import 'bridge_join.dart';
import 'home.dart';
import 'onboarding.dart';

/// Layar akar: chat kalau sudah tergabung di konser, kalau belum layar sambutan.
/// Dipakai sebagai `home` aplikasi dan sebagai tujuan setelah gabung (supaya "Buka chat" selalu punya layar tujuan).
class RootGate extends StatelessWidget {
  const RootGate({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Hub.i,
      builder: (context, _) {
        if (Hub.i.concert != null) return const HomeShell();
        if (kIsWeb && Bridge.i.isLocalOrigin) return const BridgeJoinScreen();
        return const WelcomeScreen();
      },
    );
  }
}

/// Buka chat dan buang semua layar onboarding di belakangnya.
void openRoot(BuildContext context) =>
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const RootGate()), (_) => false);
