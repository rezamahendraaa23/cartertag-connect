import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

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
            if (Hub.i.kickNotice != null) ...[
              InfoBanner(tone: Tone.danger, text: Hub.i.kickNotice!, margin: EdgeInsets.zero),
              const SizedBox(height: 12),
            ],
            FilledButton(
              onPressed: () {
                Hub.i.dismissKick();
                openPermissionsThen(context, const JoinScreen());
              },
              child: Text(Hub.i.kickNotice != null ? 'Gabung lagi' : 'Mulai'),
            ),
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
  const _PermStep(this.icon, this.title, this.text, this.perms, {this.kind = ''});
  final IconData icon;
  final String title;
  final String text;
  final List<Permission> perms;

  /// '' = izin biasa / baterai, 'autostart' = pengaturan Autostart vendor (tidak bisa dicek, ditampilkan sekali)
  final String kind;
}

/// Merek yang punya pengaturan Autostart sendiri dan mematikan app di latar kalau belum diaktifkan.
const _autostartBrands = ['xiaomi', 'redmi', 'poco', 'oppo', 'realme', 'oneplus', 'vivo', 'iqoo', 'huawei', 'honor', 'infinix', 'tecno', 'itel', 'asus', 'letv'];

const _autostartStep = _PermStep(LucideIcons.rocket, 'Izinkan Autostart',
    'HP merek ini mematikan app di latar kecuali "Autostart / Mulai otomatis" diaktifkan. Di layar berikutnya, cari CarterTag Connect lalu aktifkan.',
    [], kind: 'autostart');

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
  final brand = await Mesh.i.brand();
  if (_autostartBrands.any(brand.contains) && await Hub.i.s.get<bool>('autostart_done') != true) out.add(_autostartStep);
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
    if (s.kind == 'autostart') {
      await Mesh.i.openAutostart();
      await Hub.i.s.put('autostart_done', true);
    } else if (s.perms.isEmpty) {
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
            FilledButton(onPressed: busy ? null : _allow, child: Text(busy ? 'Menunggu…' : (s.kind == 'autostart' ? 'Buka pengaturan Autostart' : 'Izinkan'))),
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
  const JoinScreen({super.key, this.initialCode, this.auto = false, this.roleHint = ''});

  /// Kode dari link gabung / QR (boleh dengan atau tanpa "CT-").
  final String? initialCode;

  /// true = langsung gabung lewat satu popup, tanpa menampilkan form (link / scan).
  final bool auto;

  /// Peran dari link: 'd' driver (popup langsung tanya nomor mobil), 'k' koordinator, '' tidak diketahui (link lama).
  final String roleHint;
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

  /// Mode cepat (link/scan): form disembunyikan, cukup popup. Kembali ke form kalau popup dibatalkan atau gabung gagal.
  late bool quick = widget.auto;

  @override
  void initState() {
    super.initState();
    Api.baseUrl().then((u) {
      server.text = u;
      if (u.isEmpty) setState(() => showServer = true);
    });
    // nama & nomor HP tersimpan dari gabung sebelumnya
    final init = (widget.initialCode ?? '').toUpperCase().replaceFirst(RegExp(r'^CT-?'), '').replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (init.length == 6) code.text = init;
    Future.wait([Hub.i.s.get<String>('profile_name'), Hub.i.s.get<String>('profile_hp')]).then((v) async {
      if (name.text.isEmpty) name.text = v[0] ?? '';
      if (hp.text.isEmpty) hp.text = v[1] ?? '';
      if (!widget.auto || !mounted) return;
      if (code.text.length != 6) {
        setState(() => quick = false);
        return;
      }
      await WidgetsBinding.instance.endOfFrame;
      await _quickJoin(widget.roleHint);
    });
  }

  /// Gabung lewat link/scan: driver -> satu popup (nomor mobil + nama + HP); koordinator dengan nama tersimpan -> langsung masuk.
  Future<void> _quickJoin(String role) async {
    final driver = role == 'd';
    if (driver || name.text.trim().isEmpty) {
      if (!await _askJoin(driver: driver)) {
        if (mounted) setState(() => quick = false);
        return;
      }
    }
    if (mounted) await _submit(fromScan: true);
  }

  /// Gabung. Kode driver tanpa nomor mobil -> server menolak dengan kode 'car' -> popup nomor mobil -> coba lagi.
  Future<void> _submit({bool fromScan = false}) async {
    if (!fromScan && !_form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
      offline = false;
    });
    try {
      if (showServer) await Api.setBaseUrl(server.text);
      final c = await Hub.i.join(kode: code.text, nama: name.text.trim(), car: carDigits(car.text), hp: hp.text);
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => ConfirmScreen(concert: c)), (_) => false);
    } on ApiError catch (e) {
      if (e.code == 'cancel') {
        if (mounted) setState(() => busy = false);
        return;
      }
      if (e.code == 'car') {
        setState(() => busy = false);
        final n = await _askCar();
        if (n != null && mounted) {
          car.text = n;
          return _submit(fromScan: true);
        }
        setState(() {
          needCar = true;
          quick = false;
          error = 'Kode ini untuk driver: isi nomor mobil.';
        });
        return;
      }
      setState(() {
        error = e.message;
        offline = e.isNetwork;
        quick = false;
        if (e.code == 'config') showServer = true;
      });
    } catch (e) {
      setState(() {
        error = 'Gagal gabung: $e';
        quick = false;
      });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// Popup "Nomor mobil berapa?" dengan awalan C (tinggal ketik angka).
  Future<String?> _askCar() {
    final ctl = TextEditingController(text: carDigits(car.text));
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nomor mobil berapa?'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
          style: mono(22, w: FontWeight.w700),
          decoration: const InputDecoration(prefixText: 'C ', hintText: '3'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim().isEmpty ? null : v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim().isEmpty ? null : ctl.text.trim()), child: const Text('Masuk')),
        ],
      ),
    );
  }

  /// Popup gabung (link/scan): driver -> nomor mobil paling atas; lalu nama (terisi kalau pernah gabung) + HP opsional.
  Future<bool> _askJoin({required bool driver}) async {
    final n = TextEditingController(text: name.text), h = TextEditingController(text: hp.text);
    final cr = TextEditingController(text: carDigits(car.text));
    final key = GlobalKey<FormState>();
    void done(BuildContext ctx) {
      if (key.currentState!.validate()) Navigator.pop(ctx, true);
    }

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(driver ? 'Gabung sebagai driver' : 'Gabung tim'),
        content: Form(
          key: key,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (driver) ...[
              TextFormField(
                controller: cr,
                autofocus: true,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.next,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
                style: mono(22, w: FontWeight.w700),
                decoration: const InputDecoration(labelText: 'Nomor mobil', prefixText: 'C ', hintText: '3', prefixIcon: Icon(LucideIcons.carFront)),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Isi nomor mobil' : null,
              ),
              const SizedBox(height: 12),
            ],
            TextFormField(
              controller: n,
              autofocus: !driver,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Nama', prefixIcon: Icon(LucideIcons.user)),
              validator: (v) => (v ?? '').trim().isEmpty ? 'Nama wajib diisi' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: h,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Nomor HP (opsional)', prefixIcon: Icon(LucideIcons.phone)),
              validator: (v) => (v ?? '').trim().isNotEmpty && normHp(v!).isEmpty ? 'Nomor HP tidak valid' : null,
              onFieldSubmitted: (_) => done(ctx),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          FilledButton(onPressed: () => done(ctx), child: const Text('Gabung')),
        ],
      ),
    );
    if (ok != true) return false;
    name.text = n.text.trim();
    hp.text = h.text.trim();
    if (driver) {
      car.text = cr.text.trim();
      needCar = true;
    }
    return true;
  }

  /// Scan QR: QR kode dari admin -> satu popup lalu langsung gabung; QR undangan -> alur gabung offline.
  Future<void> _scan() async {
    final r = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const InviteScanScreen()));
    if (r == null || !mounted) return;
    final parts = r.split('|'); // "CT-XXXXXX|d" dari QR link baru
    setState(() => code.text = parts.first.toUpperCase().replaceFirst(RegExp(r'^CT-?'), ''));
    await _quickJoin(parts.length > 1 ? parts[1] : '');
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = CT.of(context);
    // dari link/scan: cukup latar sederhana di belakang popup, tanpa form
    if (quick) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Image.asset('assets/logo.png', width: 72, height: 72, semanticLabel: 'Logo CarterTag'),
              const SizedBox(height: 20),
              if (busy) ...[
                const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)),
                const SizedBox(height: 14),
                Text('Menggabungkan ke tim…', style: t.bodyLarge?.copyWith(color: c.muted)),
              ] else
                Text('Gabung tim CarterTag Connect', style: t.titleMedium),
            ]),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Gabung tim')),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 24), children: [
            if (!kIsWeb) ...[
              FilledButton.icon(
                onPressed: busy ? null : _scan,
                icon: const Icon(LucideIcons.scanLine),
                label: const Text('Scan QR kode dari koordinator'),
              ),
              const SizedBox(height: 18),
              Row(children: [
                const Expanded(child: Divider()),
                Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text('atau isi manual', style: t.bodySmall)),
                const Expanded(child: Divider()),
              ]),
              const SizedBox(height: 18),
            ] else ...[
              // Link gabung terbuka di browser Android padahal app sudah terpasang: paksa buka app (intent://)
              if (defaultTargetPlatform == TargetPlatform.android && code.text.length == 6) ...[
                FilledButton.icon(
                  onPressed: () => launchUrl(Uri.parse('intent://cartertag-connect.web.app/join?kode=CT-${code.text}'
                      '#Intent;scheme=https;package=id.cartertag.connect;'
                      'S.browser_fallback_url=${Uri.encodeComponent('https://github.com/rezamahendraaa23/cartertag-connect/releases/latest')};end')),
                  icon: const Icon(LucideIcons.externalLink),
                  label: const Text('Buka di aplikasi'),
                ),
                const SizedBox(height: 12),
              ],
              InfoBanner(
                margin: EdgeInsets.zero,
                tone: Tone.info,
                icon: LucideIcons.smartphone,
                text: 'Pakai HP Android? Pasang app-nya supaya tetap bisa chat tanpa sinyal.',
                action: 'Unduh',
                onAction: () => launchUrl(Uri.parse('https://github.com/rezamahendraaa23/cartertag-connect/releases/latest'), mode: LaunchMode.externalApplication),
              ),
              const SizedBox(height: 16),
              Text('Minta kode ke koordinator. Isi sekali saat masih ada internet.', style: t.bodyLarge?.copyWith(color: c.muted)),
              const SizedBox(height: 20),
            ],
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
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                LengthLimitingTextInputFormatter(6),
                TextInputFormatter.withFunction((o, n) => n.copyWith(text: n.text.toUpperCase())),
              ],
              decoration: InputDecoration(labelText: 'Kode', prefixText: 'CT-', hintText: 'XXXXXX', prefixIcon: const Icon(LucideIcons.keyRound)),
              validator: (v) => (v ?? '').length != 6 ? 'Kode terdiri dari 6 karakter' : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: car,
              focusNode: carFocus,
              enabled: !busy,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
              decoration: InputDecoration(
                labelText: needCar ? 'Nomor mobil (wajib untuk driver)' : 'Nomor mobil (khusus driver)',
                prefixText: 'C ',
                hintText: '3',
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
  void initState() {
    super.initState();
    Hub.i.s.get<String>('profile_name').then((v) => name.text = name.text.isEmpty ? (v ?? '') : name.text);
  }

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
      // QR kode dari admin: "CT-XXXXXX" atau link ".../join?kode=CT-XXXXXX" -> kembali ke form Gabung dengan kode terisi
      final link = Uri.tryParse(raw);
      final fromLink = link != null && link.path.startsWith('/join') ? (link.queryParameters['kode'] ?? link.queryParameters['k'] ?? '') : raw;
      final m = RegExp(r'^(?:CT-?)?([2-9A-HJ-NP-Z]{6})$', caseSensitive: false).firstMatch(fromLink.trim());
      if (m != null) {
        _done = true;
        HapticFeedback.mediumImpact();
        final r = link != null && link.path.startsWith('/join') ? (link.queryParameters['r'] ?? '') : '';
        Navigator.of(context).pop('CT-${m.group(1)!.toUpperCase()}${r.isNotEmpty ? '|$r' : ''}');
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
    try {
      final c = await Hub.i.joinFromInvite(qr!, nama: name.text.trim(), car: carDigits(car.text));
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => ConfirmScreen(concert: c)), (_) => false);
    } catch (e) {
      // jangan macet di "Menyiapkan…": tampilkan kesalahan & aktifkan lagi tombolnya
      final cancelled = e is ApiError && e.code == 'cancel';
      if (mounted) setState(() { busy = false; error = cancelled ? null : 'Gagal gabung dari QR: $e'; });
    }
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
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
                      decoration: const InputDecoration(labelText: 'Nomor mobil', prefixText: 'C ', prefixIcon: Icon(LucideIcons.carFront)),
                      validator: (v) => (v ?? '').trim().isEmpty ? 'Nomor mobil wajib diisi' : null,
                    ),
                  ],
                  const SizedBox(height: 24),
                  if (error != null) ...[
                    InfoBanner(tone: Tone.danger, text: error!, margin: EdgeInsets.zero),
                    const SizedBox(height: 12),
                  ],
                  FilledButton(onPressed: busy ? null : _join, child: Text(busy ? 'Menyiapkan…' : 'Gabung tanpa internet')),
                ]),
              ),
      ),
    );
  }
}
