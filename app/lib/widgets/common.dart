import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Centers content and caps its width so pages read well on desktop web.
class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.child, this.maxWidth = 1100});
  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        heightFactor: 1, // only as tall as the content – otherwise it fills e.g. a whole bottom bar
        child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: child),
      );
}

String ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 7) return '${d.inDays}d ago';
  return DateFormat.MMMd().format(t);
}

Color scoreColor(BuildContext context, int? score) {
  if (score == null) return Theme.of(context).colorScheme.outline;
  if (score >= 85) return Colors.green.shade600;
  if (score >= 65) return Colors.orange.shade700;
  return Colors.red.shade600;
}

class ScoreBadge extends StatelessWidget {
  const ScoreBadge({super.key, required this.label, required this.score, this.big = false});
  final String label;
  final int? score;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final c = scoreColor(context, score);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: big ? 14 : 8, vertical: big ? 10 : 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(big ? 12 : 8),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(score == null ? '—' : '$score%',
            style: TextStyle(color: c, fontWeight: FontWeight.w700, fontSize: big ? 22 : 13)),
        Text(label, style: TextStyle(color: c, fontSize: big ? 12 : 10)),
      ]),
    );
  }
}

const statusColors = {
  'new': Colors.blueGrey,
  'scored': Colors.indigo,
  'tailored': Colors.deepPurple,
  'ready': Colors.teal,
  'applied': Colors.green,
  'error': Colors.red,
  'skipped': Colors.grey,
};

const statusLabels = {
  'new': 'Queued',
  'scored': 'Scored',
  'tailored': 'Tailored',
  'ready': 'Ready',
  'applied': 'Applied',
  'error': 'Error',
  'skipped': 'Skipped',
};

class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key});
  final String status;

  @override
  Widget build(BuildContext context) {
    final c = statusColors[status] ?? Colors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
      child: Text(statusLabels[status] ?? status,
          style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w600)),
    );
  }
}

class ErrorView extends StatelessWidget {
  const ErrorView(this.error, {super.key, this.onRetry});
  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline, size: 40),
            const SizedBox(height: 8),
            Text('$error', textAlign: TextAlign.center),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
            ],
          ]),
        ),
      );
}

void toast(BuildContext context, String msg) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
