import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/theme.dart';
import '../data/models.dart';
import '../services/hub.dart';

/// K01 — Pil koneksi: selalu ikon + teks, tidak hanya warna.
class ConnPill extends StatelessWidget {
  const ConnPill({super.key, this.onTap, this.compact = false});
  final VoidCallback? onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = CT.of(context);
    final h = Hub.i;
    final (IconData icon, String label, Color fg, Color bg) = switch (h.link) {
      Link.online => (LucideIcons.cloud, 'Online', c.ok, c.okBg),
      Link.bridge => (LucideIcons.link, 'Jembatan', c.accent, c.accentBg),
      Link.mesh => (LucideIcons.network, 'Mesh · ${h.meshPeers} HP', c.amber, c.amberBg),
      Link.isolated => (LucideIcons.cloudOff, h.queued > 0 ? 'Offline · ${h.queued} antre' : 'Offline', c.muted, c.cardLow),
    };
    return Semantics(
      button: onTap != null,
      label: 'Status koneksi: $label',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          constraints: const BoxConstraints(minHeight: 36),
          padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 12, vertical: 6),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 15, color: fg),
            const SizedBox(width: 6),
            Flexible(child: Text(label, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5, color: fg))),
          ]),
        ),
      ),
    );
  }
}

/// Tombol aksi Neobrutalism dengan efek "ditekan" (bergeser 4px, bayangan hilang).
class PressBox extends StatefulWidget {
  const PressBox({super.key, required this.child, this.onTap, this.onLongPress, this.color, this.radius = kRadius, this.padding = const EdgeInsets.all(14), this.semantics});
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Color? color;
  final double radius;
  final EdgeInsets padding;
  final String? semantics;

  @override
  State<PressBox> createState() => _PressBoxState();
}

class _PressBoxState extends State<PressBox> {
  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(widget.radius);
    return Semantics(
      button: widget.onTap != null,
      label: widget.semantics,
      child: Container(
        decoration: brutalBox(context, color: widget.color, radius: widget.radius),
        child: Material(
          color: Colors.transparent,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(onTap: widget.onTap, onLongPress: widget.onLongPress, child: Padding(padding: widget.padding, child: widget.child)),
        ),
      ),
    );
  }
}

/// K06 — Stat card.
class StatCard extends StatelessWidget {
  const StatCard({super.key, required this.value, required this.label, required this.icon, this.tone});
  final String value;
  final String label;
  final IconData icon;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final c = CT.of(context);
    return Container(
      width: 132,
      padding: const EdgeInsets.all(12),
      decoration: brutalBox(context),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 20, color: tone ?? c.ink),
        const SizedBox(height: 6),
        Text(value, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: tone ?? c.ink, fontFeatures: const [FontFeature.tabularFigures()])),
        Text(label, maxLines: 2, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: c.muted)),
      ]),
    );
  }
}

/// K08 — Chip status (ikon + teks + warna).
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.label, required this.icon, required this.fg, required this.bg, this.dense = false});
  final String label;
  final IconData icon;
  final Color fg, bg;
  final bool dense;

  factory StatusChip.fleet(BuildContext context, String? st, {bool stale = false, bool dense = false}) {
    final c = CT.of(context);
    if (stale) return StatusChip(label: 'Tidak ada kabar', icon: LucideIcons.clock, fg: c.amber, bg: c.amberBg, dense: dense);
    return switch (st) {
      'kendala' => StatusChip(label: 'Kendala', icon: LucideIcons.triangleAlert, fg: c.danger, bg: c.dangerBg, dense: dense),
      'tiba' || 'selesai' => StatusChip(label: fleetShort[st]!, icon: LucideIcons.check, fg: c.ok, bg: c.okBg, dense: dense),
      'berangkat' => StatusChip(label: 'Berangkat', icon: LucideIcons.navigation, fg: c.accent, bg: c.accentBg, dense: dense),
      null || '' => StatusChip(label: 'Belum lapor', icon: LucideIcons.hourglass, fg: c.muted, bg: c.cardLow, dense: dense),
      _ => StatusChip(label: fleetShort[st] ?? st, icon: LucideIcons.carFront, fg: c.ink, bg: c.card, dense: dense),
    };
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 8 : 10, vertical: dense ? 3 : 5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: dense ? 13 : 15, color: fg),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: dense ? 11.5 : 12.5, fontWeight: FontWeight.w600, color: fg)),
      ]),
    );
  }
}

/// K16 — Avatar inisial. Warna dari hash nama (palet yang kontras dengan teks hitam).
class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.name, this.size = 44, this.initials});
  final String name;
  final String? initials;
  final double size;

  static const _palette = [Color(0xFF1D5DAA), Color(0xFF047857), Color(0xFF7C3AED), Color(0xFFB45309), Color(0xFFBE185D), Color(0xFF0E7490)];

  @override
  Widget build(BuildContext context) {
    final idx = name.codeUnits.fold<int>(0, (a, b) => a + b) % _palette.length;
    final ini = initials ?? Member({'n': name}).initials;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: _palette[idx], shape: BoxShape.circle),
      child: Text(ini, style: TextStyle(fontWeight: FontWeight.w600, fontSize: size * 0.38, color: Colors.white)),
    );
  }
}

/// K17 — Empty / error state.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.text, this.action, this.onAction});
  final IconData icon;
  final String title;
  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 44, color: CT.of(context).muted),
          const SizedBox(height: 12),
          Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(text, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
          if (action != null) ...[
            const SizedBox(height: 16),
            FilledButton(onPressed: onAction, child: Text(action!)),
          ],
        ]),
      ),
    );
  }
}

/// K14 — Banner (info / peringatan / bahaya).
enum Tone { info, warn, danger, ok }

class InfoBanner extends StatelessWidget {
  const InfoBanner({super.key, required this.text, this.tone = Tone.info, this.icon, this.action, this.onAction, this.margin = const EdgeInsets.fromLTRB(16, 12, 16, 0)});
  final String text;
  final Tone tone;
  final IconData? icon;
  final String? action;
  final VoidCallback? onAction;
  final EdgeInsets margin;

  @override
  Widget build(BuildContext context) {
    final c = CT.of(context);
    final (Color bg, Color fg, IconData ic) = switch (tone) {
      Tone.info => (c.accentBg, c.ink, LucideIcons.info),
      Tone.warn => (c.amberBg, c.ink, LucideIcons.triangleAlert),
      Tone.danger => (c.dangerBg, c.ink, LucideIcons.circleAlert),
      Tone.ok => (c.okBg, c.ink, LucideIcons.check),
    };
    return Container(
      margin: margin,
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Icon(icon ?? ic, size: 20, color: fg),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: TextStyle(fontWeight: FontWeight.w500, color: fg, fontSize: 14))),
        if (action != null) TextButton(onPressed: onAction, child: Text(action!)),
      ]),
    );
  }
}

/// Judul seksi daftar.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
        child: Row(children: [
          Expanded(child: Text(text, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: CT.of(context).accent))),
          ?trailing,
        ]),
      );
}

String timeAgo(int ms) {
  if (ms <= 0) return 'belum ada';
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (d.inSeconds < 60) return 'baru saja';
  if (d.inMinutes < 60) return '${d.inMinutes} mnt lalu';
  if (d.inHours < 24) return '${d.inHours} jam lalu';
  return '${d.inDays} hari lalu';
}

String hhmm(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${t.hour.toString().padLeft(2, '0')}.${t.minute.toString().padLeft(2, '0')}';
}

void toast(BuildContext context, String text, {String? action, VoidCallback? onAction, Duration duration = const Duration(seconds: 4)}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(text),
      duration: duration,
      action: action == null ? null : SnackBarAction(label: action, onPressed: onAction ?? () {}),
    ));
}

/// K13 — Dialog konfirmasi dengan aksi berlabel jelas.
Future<bool> confirm(BuildContext context, {required String title, required String text, required String action, bool danger = false}) async {
  final c = CT.of(context);
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(text),
      actions: [
        OutlinedButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
        FilledButton(
          style: danger ? FilledButton.styleFrom(backgroundColor: c.danger, foregroundColor: Colors.white) : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return r == true;
}
