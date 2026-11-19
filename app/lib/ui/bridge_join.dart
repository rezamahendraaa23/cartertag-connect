import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/theme.dart';
import '../services/bridge_client.dart';
import '../services/hub.dart';
import 'widgets.dart';

/// S28 — Klien web (iPhone) yang dibuka dari server lokal HP Android lewat Mode Jembatan.
class BridgeJoinScreen extends StatefulWidget {
  const BridgeJoinScreen({super.key});
  @override
  State<BridgeJoinScreen> createState() => _BridgeJoinScreenState();
}

class _BridgeJoinScreenState extends State<BridgeJoinScreen> {
  final name = TextEditingController();
  final car = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool waiting = false;
  String? error;
  StreamSubscription? _ctl, _st;

  @override
  void initState() {
    super.initState();
    _ctl = Bridge.i.control.listen((m) async {
      if (m['t'] == 'welcome') {
        await Hub.i.joinFromBridge((m['bundle'] as Map).cast<String, dynamic>());
      } else if (m['t'] == 'denied') {
        setState(() {
          waiting = false;
          error = '${m['reason'] ?? 'Ditolak host.'}';
        });
      }
    });
    _st = Bridge.i.state.listen((_) => setState(() {}));
  }

  @override
  void dispose() {
    _ctl?.cancel();
    _st?.cancel();
    super.dispose();
  }

  void _join() {
    if (!_form.currentState!.validate()) return;
    if (!Bridge.i.connected) {
      setState(() => error = 'Belum tersambung ke HP host. Pastikan Wi-Fi iPhone tersambung ke jaringan DIRECT-CT-….');
      return;
    }
    setState(() {
      waiting = true;
      error = null;
    });
    Bridge.i.hello({'token': Bridge.i.urlToken, 'n': name.text.trim(), 'car': car.text.trim(), 'px': Hub.i.keys.pubXb64, 'pe': Hub.i.keys.pubEdB64});
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Gabung lewat jembatan')),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(20), children: [
          Image.asset('assets/logo.png', width: 64, height: 64, alignment: Alignment.centerLeft),
          const SizedBox(height: 16),
          Text('CarterTag Connect', style: t.displaySmall),
          const SizedBox(height: 8),
          Text('Kamu tersambung lewat Wi-Fi HP Android tim. Chat tetap jalan tanpa internet selama dekat HP itu.', style: t.bodyLarge),
          const SizedBox(height: 12),
          InfoBanner(
            margin: EdgeInsets.zero,
            tone: Bridge.i.connected ? Tone.ok : Tone.warn,
            icon: Bridge.i.connected ? LucideIcons.link : LucideIcons.wifiOff,
            text: Bridge.i.connected ? 'Tersambung ke HP host.' : 'Menyambung ke HP host…',
          ),
          const SizedBox(height: 20),
          TextFormField(
            controller: name,
            decoration: const InputDecoration(labelText: 'Nama'),
            validator: (v) => (v ?? '').trim().isEmpty ? 'Nama wajib diisi' : null,
          ),
          const SizedBox(height: 18),
          TextFormField(
            controller: car,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: 'Nomor mobil (khusus driver)'),
          ),
          if (error != null) ...[const SizedBox(height: 16), InfoBanner(margin: EdgeInsets.zero, tone: Tone.danger, text: error!)],
          const SizedBox(height: 24),
          FilledButton(onPressed: waiting ? null : _join, child: Text(waiting ? 'Menunggu persetujuan host…' : 'Gabung')),
          const SizedBox(height: 16),
          Text('Tips: tambahkan ke Layar Utama (Bagikan → Tambah ke Layar Utama) supaya mudah dibuka lagi.', style: mono(12, color: CT.of(context).muted)),
        ]),
      ),
    );
  }
}
