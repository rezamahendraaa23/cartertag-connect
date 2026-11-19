import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/ids.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../services/api.dart';
import '../services/hub.dart';
import '../services/mesh.dart';
import 'root.dart';
import 'widgets.dart';

/// S01/S02 — Selamat datang.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = CT.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Spacer(),
            Center(child: Image.asset('assets/logo.png', width: 96, height: 96, semanticLabel: 'Logo CarterTag')),
            const SizedBox(height: 28),
            Text('CarterTag Connect', textAlign: TextAlign.center, style: t.displaySmall),
            const SizedBox(height: 10),
            Text('Chat tim driver & koordinator di hari konser.\nTetap nyambung walau sinyal hilang.',
                textAlign: TextAlign.center, style: t.bodyLarge?.copyWith(color: c.muted)),
            const SizedBox(height: 36),
            _point(context, LucideIcons.cloud, 'Ada sinyal', 'Pesan lewat internet seperti biasa.'),
            _point(context, LucideIcons.bluetooth, 'Sinyal hilang', 'Pesan lompat dari HP ke HP lewat Bluetooth.'),
            _point(context, LucideIcons.siren, 'Darurat', 'Tahan tombol SOS, semua HP tim berbunyi.'),
            const Spacer(flex: 2),
            FilledButton(onPressed: () => openPermissionsThen(context, const JoinScreen()), child: const Text('Mulai')),
          ]),
        ),
      ),
    );
  }

  Widget _point(BuildContext context, IconData icon, String title, String text) {
    final c = CT.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(color: c.accentBg, shape: BoxShape.circle),
          child: Icon(icon, size: 20, color: c.accent),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            Text(text, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: c.muted)),
          ]),
        ),
      ]),
    );
  }
}

class _PermStep {
  const _PermStep(this.icon, this.title, this.text, this.perms);
  final IconData icon;
  final String title;
  final String text;
  final List<Permission> perms;
}

/// Langkah izin yang belum diberikan. Kosong = semua sudah diizinkan, layar izin dilewati.
Future<List<_PermStep>> pendingPermSteps() async {
  final out = <_PermStep>[];
  for (final s in _PermissionsScreenState.all) {
    final perms = s.perms.isEmpty ? [Permission.ignoreBatteryOptimizations] : s.perms;
    var granted = true;
    for (final p in perms) {
      final st = await p.status;
      // izin yang tidak berlaku di versi Android ini dianggap sudah beres
      if (!(st.isGranted || st.isLimited || st == PermissionStatus.restricted)) granted = false;
    }
    if (!granted) out.add(s);
  }
  return out;
}

/// Buka layar izin hanya kalau masih ada izin yang belum diberikan; kalau sudah semua, langsung ke [next].
Future<void> openPermissionsThen(BuildContext context, Widget next) async {
  final pending = Mesh.i.supported ? await pendingPermSteps() : const <_PermStep>[];
  if (!context.mounted) return;
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => pending.isEmpty ? next : PermissionsScreen(next: next, only: pending)));
}

/// S03 — Izin: diminta sekali, langkah yang sudah diizinkan dilewati.
class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key, required this.next, this.only});
  final Widget next;
  final List<_PermStep>? only;
  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen> {
  int step = 0;
  bool busy = false;
  final denied = <String>[];
  late final List<_PermStep> steps = widget.only ?? all;

  static final all = [
    _PermStep(LucideIcons.bluetooth, 'Bluetooth & perangkat sekitar',
        'Untuk kirim pesan ke HP tim terdekat saat tidak ada sinyal.',
        [Permission.bluetoothScan, Permission.bluetoothAdvertise, Permission.bluetoothConnect, Permission.nearbyWifiDevices]),
    _PermStep(LucideIcons.mapPin, 'Lokasi', 'Untuk radar ke anggota tim dan lokasi SOS. Hanya dibagikan ke tim konser ini.', [Permission.locationWhenInUse]),
    _PermStep(LucideIcons.bell, 'Notifikasi', 'Supaya pesan dan alarm SOS tetap masuk saat HP terkunci.', [Permission.notification]),
    _PermStep(LucideIcons.batteryMedium, 'Tetap aktif di latar', 'Supaya pesan tanpa sinyal tidak berhenti saat layar mati.', []),
  ];

  Future<void> _allow() async {
    setState(() => busy = true);
    final s = steps[step];
    if (s.perms.isEmpty) {
      final r = await Permission.ignoreBatteryOptimizations.request();
      if (!r.isGranted) denied.add(s.title);
    } else {
      final res = await s.perms.request();
      if (res.values.any((r) => r.isPermanentlyDenied || r.isDenied)) denied.add(s.title);
    }
    if (!mounted) return;
    setState(() => busy = false);
    _advance();
  }

  void _advance() {
    if (step < steps.length - 1) {
      setState(() => step++);
    } else {
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => widget.next));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = steps[step];
    final t = Theme.of(context).textTheme;
    final c = CT.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('Izin ${step + 1} dari ${steps.length}')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            LinearProgressIndicator(value: (step + 1) / steps.length, minHeight: 4, color: c.accent, backgroundColor: c.cardLow, borderRadius: BorderRadius.circular(4)),
            const Spacer(),
            Center(
              child: Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(color: c.accentBg, shape: BoxShape.circle),
                child: Icon(s.icon, size: 38, color: c.accent),
              ),
            ),
            const SizedBox(height: 24),
            Text(s.title, textAlign: TextAlign.center, style: t.headlineSmall),
            const SizedBox(height: 10),
            Text(s.text, textAlign: TextAlign.center, style: t.bodyLarge?.copyWith(color: c.muted)),
            if (denied.isNotEmpty) ...[
              const SizedBox(height: 16),
              InfoBanner(margin: EdgeInsets.zero, tone: Tone.warn, text: 'Ditolak: ${denied.join(', ')}. Bisa diizinkan nanti di Pengaturan HP.'),
            ],
            const Spacer(flex: 2),
            FilledButton(onPressed: busy ? null : _allow, child: Text(busy ? 'Menunggu…' : 'Izinkan')),
            const SizedBox(height: 6),
            TextButton(onPressed: busy ? null : _advance, child: const Text('Nanti saja')),
          ]),
        ),
      ),
    );
  }
}

/// S04 — Gabung: nama + kode (+ nomor mobil untuk driver).
class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key});
  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  final _form = GlobalKey<FormState>();
  final name = TextEditingController();
  final code = TextEditingController();
  final car = TextEditingController();
  final hp = TextEditingController();
  final server = TextEditingController();
  final carFocus = FocusNode();
  bool busy = false;
  String? error;
  bool offline = false;
  bool showServer = false;
  bool needCar = false;

  @override
  void initState() {
    super.initState();
    Api.baseUrl().then((u) {
      server.text = u;
      if (u.isEmpty) setState(() => showServer = true);
    });
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
      offline = false;
    });
    try {
      if (showServer) await Api.setBaseUrl(server.text);
      final c = await Hub.i.join(kode: code.text, nama: name.text.trim(), car: car.text, hp: hp.text);
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => ConfirmScreen(concert: c)), (_) => false);
    } on ApiError catch (e) {
      setState(() {
        error = e.message;
        offline = e.isNetwork;
        if (e.code == 'config') showServer = true;
        if (e.code == 'car') {
          needCar = true;
          WidgetsBinding.instance.addPostFrameCallback((_) => carFocus.requestFocus());
        }
      });
    } catch (e) {
      setState(() => error = 'Gagal gabung: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// Scan QR: QR kode dari admin mengisi kolom Kode; QR undangan langsung membuka alur gabung offline.
  Future<void> _scan() async {
    final r = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const InviteScanScreen()));
    if (r != null && mounted) {
      setState(() => code.text = r);
      toast(context, 'Kode $r terisi. Lengkapi nama lalu Gabung.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = CT.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Gabung tim')),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 24), children: [
            Text('Minta kode ke koordinator. Isi sekali saat masih ada internet.', style: t.bodyLarge?.copyWith(color: c.muted)),
            const SizedBox(height: 24),
            TextFormField(
              controller: name,
              enabled: !busy,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.name],
              decoration: const InputDecoration(labelText: 'Nama kamu', prefixIcon: Icon(LucideIcons.user)),
              validator: (v) => (v ?? '').trim().isEmpty ? 'Nama wajib diisi' : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: code,
              enabled: !busy,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.next,
              style: mono(18, w: FontWeight.w700),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9-]')), LengthLimitingTextInputFormatter(9)],
              decoration: InputDecoration(
                labelText: 'Kode',
                hintText: 'CT-XXXXXX',
                prefixIcon: const Icon(LucideIcons.keyRound),
                suffixIcon: kIsWeb
                    ? null
                    : IconButton(tooltip: 'Scan QR kode', icon: const Icon(LucideIcons.scanLine), onPressed: busy ? null : _scan),
              ),
              validator: (v) => (v ?? '').toUpperCase().replaceAll(RegExp(r'^CT-?'), '').replaceAll('-', '').length != 6 ? 'Kode terdiri dari 6 karakter' : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: car,
              focusNode: carFocus,
              enabled: !busy,
              keyboardType: TextInputType.text,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [LengthLimitingTextInputFormatter(10)],
              decoration: InputDecoration(
                labelText: needCar ? 'Nomor mobil (wajib untuk driver)' : 'Nomor mobil (khusus driver)',
                hintText: 'mis. 3',
                prefixIcon: const Icon(LucideIcons.carFront),
              ),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: hp,
              enabled: !busy,
              keyboardType: TextInputType.phone,
              autofillHints: const [AutofillHints.telephoneNumber],
              decoration: const InputDecoration(labelText: 'Nomor HP (opsional)', hintText: '0812 3456 7890', prefixIcon: Icon(LucideIcons.phone)),
              validator: (v) => (v ?? '').trim().isNotEmpty && normHp(v!).isEmpty ? 'Nomor HP tidak valid' : null,
              onFieldSubmitted: (_) => _submit(),
            ),
            if (showServer) ...[
              const SizedBox(height: 14),
              TextFormField(
                controller: server,
                enabled: !busy,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(labelText: 'Alamat server', prefixIcon: Icon(LucideIcons.link)),
                validator: (v) => !(v ?? '').startsWith('https://') ? 'Harus diawali https://' : null,
              ),
            ],
            if (error != null) ...[
              const SizedBox(height: 16),
              Semantics(liveRegion: true, child: InfoBanner(margin: EdgeInsets.zero, tone: offline ? Tone.warn : Tone.danger, text: error!)),
            ],
            const SizedBox(height: 24),
            FilledButton(onPressed: busy ? null : _submit, child: Text(busy ? 'Menghubungkan…' : 'Gabung')),
            const SizedBox(height: 8),
            if (!kIsWeb)
              TextButton.icon(
                onPressed: busy ? null : _scan,
                icon: const Icon(LucideIcons.scanLine, size: 20),
                label: const Text('Scan QR kode / undangan'),
              ),
          ]),
        ),
      ),
    );
  }
}

/// S05 — Konfirmasi.
class ConfirmScreen extends StatelessWidget {
  const ConfirmScreen({super.key, required this.concert});
  final Concert concert;

  @override
  Widget build(BuildContext context) {
    final me = concert.me;
    final t = Theme.of(context).textTheme;
    final c = CT.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Spacer(),
            Center(
              child: Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(color: c.okBg, shape: BoxShape.circle),
                child: Icon(LucideIcons.check, size: 40, color: c.ok),
              ),
            ),
            const SizedBox(height: 24),
            Text('Kamu sudah masuk', textAlign: TextAlign.center, style: t.displaySmall),
            const SizedBox(height: 6),
            Text(concert.name, textAlign: TextAlign.center, style: t.titleMedium?.copyWith(color: c.muted)),
            const SizedBox(height: 24),
            Center(
              child: Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
                StatusChip(label: me.roleLabel, icon: me.isDriver ? LucideIcons.carFront : LucideIcons.shieldCheck, fg: c.accent, bg: c.accentBg),
                if (me.plat.isNotEmpty) StatusChip(label: me.plat, icon: LucideIcons.bus, fg: c.ink, bg: c.cardLow),
                if (me.area.isNotEmpty) StatusChip(label: 'Area ${me.area}', icon: LucideIcons.mapPin, fg: c.ink, bg: c.cardLow),
              ]),
            ),
            const SizedBox(height: 18),
            Text('Data sudah tersimpan di HP ini, bisa dipakai tanpa sinyal.', textAlign: TextAlign.center, style: t.bodyMedium?.copyWith(color: c.muted)),
            const Spacer(flex: 2),
            FilledButton(onPressed: () => openRoot(context), child: const Text('Buka chat')),
          ]),
        ),
      ),
    );
  }
}

/// S06 — Gabung lewat QR undangan (offline).
class InviteScanScreen extends StatefulWidget {
  const InviteScanScreen({super.key});
  @override
  State<InviteScanScreen> createState() => _InviteScanScreenState();
}

class _InviteScanScreenState extends State<InviteScanScreen> {
  Map<String, dynamic>? qr;
  String? error;
  final name = TextEditingController();
  final car = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool busy = false;

  final _ctl = MobileScannerController(formats: const [BarcodeFormat.qrCode], detectionSpeed: DetectionSpeed.normal);
  bool _done = false;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _detect(BarcodeCapture cap) {
    if (qr != null || _done) return;
    for (final b in cap.barcodes) {
      final raw = (b.rawValue ?? '').trim();
      if (raw.isEmpty) continue;
      // QR kode dari admin: "CT-XXXXXX" -> kembali ke form Gabung dengan kode terisi
      final m = RegExp(r'^(?:CT-?)?([2-9A-HJ-NP-Z]{6})$', caseSensitive: false).firstMatch(raw);
      if (m != null) {
        _done = true;
        HapticFeedback.mediumImpact();
        Navigator.of(context).pop('CT-${m.group(1)!.toUpperCase()}');
        return;
      }
      try {
        final j = (jsonDecode(raw) as Map).cast<String, dynamic>();
        if (j['t'] != 'ct-invite') continue;
        if ((j['x'] as num) < DateTime.now().millisecondsSinceEpoch) {
          setState(() => error = 'QR sudah kedaluwarsa. Minta dibuat ulang.');
          return;
        }
        HapticFeedback.mediumImpact();
        setState(() {
          qr = j;
          error = null;
        });
        return;
      } catch (_) {}
      if (error == null) setState(() => error = 'QR ini bukan kode atau undangan CarterTag Connect.');
    }
  }

  Future<void> _join() async {
    if (!_form.currentState!.validate()) return;
    setState(() => busy = true);
    final c = await Hub.i.joinFromInvite(qr!, nama: name.text.trim(), car: car.text);
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => ConfirmScreen(concert: c)), (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = CT.of(context);
    final asDriver = qr?['r'] == 'driver' || qr?['r'] == null;
    return Scaffold(
      appBar: AppBar(title: const Text('Scan QR undangan')),
      body: SafeArea(
        child: qr == null
            ? Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                  child: Text('Scan QR Kode Driver / Kode Koordinator dari admin, atau QR undangan dari HP teman tim.', style: t.bodyLarge?.copyWith(color: c.muted)),
                ),
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(20)),
                    child: MobileScanner(controller: _ctl, onDetect: _detect),
                  ),
                ),
                if (error != null) InfoBanner(tone: Tone.danger, text: error!, margin: const EdgeInsets.fromLTRB(20, 0, 20, 20)),
              ])
            : Form(
                key: _form,
                child: ListView(padding: const EdgeInsets.all(20), children: [
                  InfoBanner(margin: EdgeInsets.zero, tone: Tone.ok, text: 'Undangan ${asDriver ? 'driver' : 'koordinator'} · ${qr!['n']}'),
                  const SizedBox(height: 20),
                  TextFormField(
                    controller: name,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(labelText: 'Nama kamu', prefixIcon: Icon(LucideIcons.user)),
                    validator: (v) => (v ?? '').trim().isEmpty ? 'Nama wajib diisi' : null,
                  ),
                  if (asDriver) ...[
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: car,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(labelText: 'Nomor mobil', prefixIcon: Icon(LucideIcons.carFront)),
                      validator: (v) => (v ?? '').trim().isEmpty ? 'Nomor mobil wajib diisi' : null,
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(onPressed: busy ? null : _join, child: Text(busy ? 'Menyiapkan…' : 'Gabung tanpa internet')),
                ]),
              ),
      ),
    );
  }
}
