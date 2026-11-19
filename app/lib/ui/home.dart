import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:sembast/sembast.dart';

import '../core/theme.dart';
import '../services/hub.dart';
import '../services/mesh.dart';
import 'package:geolocator/geolocator.dart';
import '../services/updater.dart';
import 'chat.dart';
import 'fleet.dart';
import 'info.dart';
import 'me.dart';
import 'radar.dart';
import 'sos.dart';
import 'widgets.dart';

/// Kerangka utama: top bar (konser, pil koneksi, SOS), banner koneksi, bottom nav 5 tab (PRD UI/UX §4).
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int tab = 0;
  StreamSubscription? _sosSub;
  final _shownSos = <String>{};
  bool bannerCollapsed = false;
  bool linkOff = false; // link gabung belum boleh membuka app (pengaturan "Buka secara default")
  late final AppLifecycleListener _life = AppLifecycleListener(onResume: _checkLink);

  bool btOff = false, locOff = false; // tanpa keduanya HP tim tidak bisa saling menemukan lewat Bluetooth

  Future<void> _checkLink() async {
    final ok = await Mesh.i.linkEnabled();
    final bt = await Mesh.i.bluetoothOn();
    final loc = !Mesh.i.supported || await Geolocator.isLocationServiceEnabled();
    if (!mounted) return;
    setState(() {
      linkOff = !ok;
      btOff = !bt;
      locOff = !loc;
    });
  }
  String? updateHidden;

  @override
  void initState() {
    super.initState();
    Hub.i.pendingRoute.addListener(_route);
    WidgetsBinding.instance.addPostFrameCallback((_) => _route());
    _sosSub = Hub.i.watch(Hub.i.s.sos).listen(_onSos);
    _life; // aktifkan pendengar: cek ulang saat kembali dari pengaturan
    _checkLink();
  }

  @override
  void dispose() {
    Hub.i.pendingRoute.removeListener(_route);
    _sosSub?.cancel();
    _life.dispose();
    super.dispose();
  }

  /// SOS baru dari orang lain -> layar penuh S22 (sekali per SOS).
  void _onSos(List<RecordSnapshot<String, Map<String, Object?>>> list) {
    for (final r in list) {
      final v = r.value;
      if (v['active'] != true || v['from'] == Hub.i.me.id || _shownSos.contains(r.key)) continue;
      final at = (v['at'] as num?)?.toInt() ?? 0;
      if (DateTime.now().millisecondsSinceEpoch - at > 2 * 3600000) continue;
      _shownSos.add(r.key);
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => IncomingSosScreen(sosId: r.key)));
    }
  }

  void _route() {
    final r = Hub.i.pendingRoute.value;
    if (r == null || r.startsWith('join:') || !mounted) return; // link gabung ditangani ConnectApp
    Hub.i.pendingRoute.value = null;
    if (r.startsWith('chat:')) {
      setState(() => tab = 0);
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatRoomScreen(channel: r.substring(5))));
    } else if (r == 'chat') {
      setState(() => tab = 0);
    } else if (r == 'fleet') {
      setState(() => tab = 1);
    } else if (r == 'info') {
      setState(() => tab = 3);
    } else if (r == 'reach') {
      setState(() => tab = 2); // notifikasi jangkauan -> tab Lokasi (Jangkauan Tim)
    } else if (r.startsWith('sos')) {
      final id = r.contains(':') ? r.split(':')[1] : null;
      Navigator.of(context).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => id == null ? const SosListScreen() : IncomingSosScreen(sosId: id)));
    }
  }

  static Color _linkColor(CT c, Link l) => switch (l) {
        Link.online => c.ok,
        Link.mesh || Link.bridge => c.accent,
        Link.isolated => c.amber,
      };

  static String _linkText(Hub h, Link l) => switch (l) {
        Link.online => 'Online',
        Link.mesh => 'Tanpa internet · ${h.meshPeers} HP tim terdekat',
        Link.bridge => 'Tanpa internet · lewat jembatan',
        Link.isolated => h.queued > 0 ? 'Menunggu jaringan · ${h.queued} antre' : 'Menunggu jaringan…',
      };

  @override
  Widget build(BuildContext context) {
    final c = CT.of(context);
    return ListenableBuilder(
      listenable: Hub.i,
      builder: (context, _) {
        final h = Hub.i;
        final concert = h.concert!;
        final link = h.link;
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 16,
            title: InkWell(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ConnectionScreen())),
              child: Row(children: [
                Image.asset('assets/logo.png', width: 34, height: 34, semanticLabel: 'CarterTag'),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(concert.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                    Row(children: [
                      Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: _linkColor(c, link))),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(_linkText(h, link), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: c.muted)),
                      ),
                    ]),
                  ]),
                ),
              ]),
            ),
            actions: [
              // keluar langsung dari layar utama (tidak perlu masuk ke Saya); tetap minta konfirmasi
              IconButton(tooltip: 'Keluar dari konser', icon: const Icon(LucideIcons.logOut), onPressed: () => leaveConcertFlow(context)),
              const SosButton(),
              const SizedBox(width: 12),
            ],
          ),
          body: Column(children: [
            if (h.mySosId != null) const ActiveSosBanner(),
            if (!concert.verified)
              const InfoBanner(tone: Tone.warn, text: 'Bergabung lewat QR. Akun diverifikasi otomatis saat ada internet.'),
            if (h.lastError != null) InfoBanner(tone: Tone.danger, text: h.lastError!, action: 'Tutup', onAction: () => setState(() => h.lastError = null)),
            if (btOff || locOff)
              InfoBanner(
                tone: Tone.warn,
                icon: LucideIcons.bluetooth,
                text: btOff && locOff
                    ? 'Nyalakan Bluetooth & Lokasi supaya pesan tetap jalan tanpa sinyal.'
                    : (btOff ? 'Nyalakan Bluetooth supaya pesan tetap jalan tanpa sinyal.' : 'Nyalakan Lokasi (GPS) supaya HP tim bisa saling menemukan lewat Bluetooth.'),
                action: 'Nyalakan',
                onAction: () => btOff ? Mesh.i.openBluetoothSettings() : Geolocator.openLocationSettings(),
              ),
            if (linkOff)
              InfoBanner(
                tone: Tone.info,
                icon: LucideIcons.link,
                text: 'Supaya link gabung dari WhatsApp langsung membuka app, aktifkan "Buka link yang didukung" lalu centang cartertag-connect.web.app.',
                action: 'Aktifkan',
                onAction: () => Mesh.i.openLinkSettings(),
              ),
            ListenableBuilder(
              listenable: Updater.i,
              builder: (context, _) {
                final u = Updater.i, up = u.available;
                if (up == null || updateHidden == up.version) return const SizedBox.shrink();
                if (u.progress != null) {
                  return Container(
                    margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    decoration: BoxDecoration(color: c.accentBg, borderRadius: BorderRadius.circular(12)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(u.progress! >= 1 ? 'Membuka pemasangan…' : 'Mengunduh versi ${up.version}… ${(u.progress! * 100).round()}%',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(value: u.progress, minHeight: 6, color: c.accent, backgroundColor: c.card),
                      ),
                    ]),
                  );
                }
                return InfoBanner(
                  tone: u.error != null ? Tone.warn : Tone.info,
                  icon: LucideIcons.download,
                  text: u.error ?? 'Versi baru ${up.version} tersedia.',
                  action: u.downloaded ? 'Pasang' : 'Update',
                  onAction: () => Updater.i.download(),
                );
              },
            ),
            if (link == Link.isolated && h.queued > 0 && !bannerCollapsed)
              InfoBanner(
                tone: Tone.warn,
                icon: LucideIcons.cloudOff,
                text: '${h.queued} pesan menunggu jaringan. Terkirim otomatis begitu ada sinyal atau HP tim di dekatmu.',
                action: 'Tutup',
                onAction: () => setState(() => bannerCollapsed = true),
              ),
            Expanded(
              child: IndexedStack(index: tab, children: const [ChatListScreen(), FleetScreen(), RadarScreen(), InfoScreen(), MeScreen()]),
            ),
          ]),
          bottomNavigationBar: Container(
            decoration: BoxDecoration(border: Border(top: BorderSide(color: c.line))),
            child: NavigationBar(
              selectedIndex: tab,
              onDestinationSelected: (i) => setState(() => tab = i),
              destinations: const [
                NavigationDestination(icon: Icon(LucideIcons.messageCircle), label: 'Chat'),
                NavigationDestination(icon: Icon(LucideIcons.carFront), label: 'Armada'),
                NavigationDestination(icon: Icon(LucideIcons.radar), label: 'Lokasi'),
                NavigationDestination(icon: Icon(LucideIcons.megaphone), label: 'Info'),
                NavigationDestination(icon: Icon(LucideIcons.circleUser), label: 'Saya'),
              ],
            ),
          ),
        );
      },
    );
  }
}
