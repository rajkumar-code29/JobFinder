import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../api.dart';
import '../models.dart';
import 'common.dart';

/// Keep in sync with ERRORS in agents/jobfinder/work.py.
const workErrors = {
  'E_AI_BUSY': 'The AI is busy or at its daily limit. Try again later.',
  'E_AI_FAILED': 'The AI couldn\'t produce a usable result. Try again.',
  'E_NO_RESUME': 'Upload your resume (.docx) in Settings first.',
  'E_RESUME_DOCX': 'Your resume needs to be a Word file (.docx) to be tailored.',
  'E_JOB_GONE': 'This job was deleted.',
  'E_PAUSED': 'The agents are paused by an admin. Try again later.',
  'E_INTERRUPTED': 'The run stopped before finishing. Try again.',
  'E_INTERNAL': 'Something went wrong on our side. Try again.',
};

String errorText(Object e) => e is PostgrestException ? e.message : '$e';

/// Live credits: the account row for the balance, requests for what's held.
class CreditsBuilder extends StatefulWidget {
  const CreditsBuilder({super.key, required this.builder});
  final Widget Function(BuildContext context, Credits? credits) builder;

  @override
  State<CreditsBuilder> createState() => _CreditsBuilderState();
}

class _CreditsBuilderState extends State<CreditsBuilder> {
  late final Stream<List<Map<String, dynamic>>> _account = _orEmpty(Api.myAccountStream);
  late final Stream<List<JobRequest>> _requests = _orEmpty(Api.requestsStream);

  /// No connection (signed out, or a widget test): show nothing rather than an error.
  static Stream<List<T>> _orEmpty<T>(Stream<List<T>> Function() open) {
    try {
      return open();
    } catch (_) {
      return Stream.value(<T>[]);
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<List<Map<String, dynamic>>>(
        stream: _account,
        builder: (context, acc) => StreamBuilder<List<JobRequest>>(
          stream: _requests,
          builder: (context, req) {
            final balance = (acc.data?.firstOrNull?['credits'] as num?)?.toInt();
            if (balance == null) return widget.builder(context, null);
            final held = (req.data ?? []).where((r) => r.active).fold<int>(0, (a, r) => a + r.cost);
            return widget.builder(context, Credits(balance, held));
          },
        ),
      );
}

/// "27 credits" in app bars; opens the Credits page.
class CreditsChip extends StatelessWidget {
  const CreditsChip({super.key});

  @override
  Widget build(BuildContext context) => CreditsBuilder(
        builder: (context, c) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: ActionChip(
            avatar: const Icon(Icons.toll_outlined, size: 18),
            label: Text(c == null ? 'Credits' : '${c.available} credit${c.available == 1 ? '' : 's'}'),
            onPressed: () => context.push('/credits'),
          ),
        ),
      );
}

/// On a job: get a tailored resume + cover letter (1 credit) and/or interview prep (1 credit). Credits are held while
/// the work runs and only taken when it succeeds.
class JobWorkPanel extends StatefulWidget {
  const JobWorkPanel({super.key, required this.job, this.requests});
  final Job job;

  /// Tests pass their own requests (and nothing touches the database).
  final List<JobRequest>? requests;

  @override
  State<JobWorkPanel> createState() => _JobWorkPanelState();
}

class _JobWorkPanelState extends State<JobWorkPanel> {
  late final Stream<List<JobRequest>> _stream =
      widget.requests != null ? Stream.value(widget.requests!) : Api.requestsStream();
  bool _busy = false;

  Future<void> _ask(List<String> kinds, int available) async {
    final cost = kinds.length;
    final what = kinds.length == 2
        ? 'a tailored resume, a cover letter and interview prep'
        : kinds.first == 'tailor'
            ? 'a tailored resume and cover letter'
            : 'interview prep';
    if (available < cost) {
      _notEnough(cost, available);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Use $cost credit${cost == 1 ? '' : 's'}?'),
        content: Text('For $what for ${widget.job.title}. You have $available to spend. The credit${cost == 1 ? ' is' : 's are'} '
            'only taken if it works; if something fails you keep ${cost == 1 ? 'it' : 'them'}.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Use $cost credit${cost == 1 ? '' : 's'}')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await Api.requestWork(widget.job.jobId, kinds);
      if (mounted) toast(context, 'On its way. This usually takes 2 to 5 minutes; you can leave this page.');
    } catch (e) {
      if (mounted) toast(context, errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _notEnough(int cost, int available) => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Not enough credits'),
          content: Text('This needs $cost and you have $available to spend.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                context.push('/credits');
              },
              child: const Text('Get credits'),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final job = widget.job;
    return StreamBuilder<List<JobRequest>>(
      stream: _stream,
      builder: (context, snap) {
        final mine = (snap.data ?? []).where((r) => r.jobId == job.jobId).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        JobRequest? latest(String kind) => mine.where((r) => r.kind == kind).firstOrNull;
        final tailor = latest('tailor'), interview = latest('interview'), score = latest('score');
        final tailorFree = !job.hasTailored && !(tailor?.active ?? false);
        final interviewFree = !job.hasInterview && !(interview?.active ?? false);
        Widget panel(Credits? credits) {
          final available = credits?.available ?? 0;
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Icon(Icons.auto_awesome_outlined, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(child: Text('Get ready to apply', style: theme.textTheme.titleMedium)),
                  if (credits != null) Text('${credits.available} credits to spend', style: theme.textTheme.bodySmall),
                ]),
                const SizedBox(height: 4),
                Text('Matching and scoring are free. Pick what you want; credits are only used when it works.',
                    style: theme.textTheme.bodySmall),
                if (score != null && score.active)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('Scoring this job against your resume first (free)…', style: theme.textTheme.bodySmall),
                  ),
                const SizedBox(height: 8),
                _Option(
                  icon: Icons.description_outlined,
                  title: 'Tailored resume + cover letter',
                  cost: 1,
                  done: job.hasTailored,
                  request: tailor,
                  busy: _busy,
                  onAsk: () => _ask(['tailor'], available),
                ),
                _Option(
                  icon: Icons.school_outlined,
                  title: 'Interview prep',
                  cost: 1,
                  done: job.hasInterview,
                  request: interview,
                  busy: _busy,
                  onAsk: () => _ask(['interview'], available),
                  doneAction: ('Practise', () => context.go('${job.basePath}/${job.jobId}/interview')),
                ),
                if (tailorFree && interviewFree)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: FilledButton.icon(
                      onPressed: _busy ? null : () => _ask(['tailor', 'interview'], available),
                      icon: const Icon(Icons.bolt),
                      label: const Text('Both · 2 credits'),
                    ),
                  ),
              ]),
            ),
          );
        }

        return widget.requests != null
            ? panel(const Credits(30, 0))
            : CreditsBuilder(builder: (context, credits) => panel(credits));
      },
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({
    required this.icon,
    required this.title,
    required this.cost,
    required this.done,
    required this.request,
    required this.busy,
    required this.onAsk,
    this.doneAction,
  });
  final IconData icon;
  final String title;
  final int cost;
  final bool done;
  final JobRequest? request;
  final bool busy;
  final VoidCallback onAsk;
  final (String, VoidCallback)? doneAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = request;
    Widget trailing;
    Widget? subtitle;
    if (done) {
      trailing = doneAction == null
          ? const Icon(Icons.check_circle, color: Colors.green)
          : FilledButton.tonal(onPressed: doneAction!.$2, child: Text(doneAction!.$1));
      subtitle = const Text('Ready');
    } else if (r != null && r.active) {
      trailing = const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5));
      subtitle = Text(r.status == 'queued' ? 'Waiting to start · $cost credit held' : 'Working on it · $cost credit held');
    } else {
      trailing = OutlinedButton(onPressed: busy ? null : onAsk, child: Text('$cost credit'));
      if (r != null && r.status == 'failed') {
        subtitle = Text(
          '${r.errorCode ?? 'Error'}: ${workErrors[r.errorCode] ?? 'Something went wrong.'} No credits were used.',
          style: TextStyle(color: theme.colorScheme.error),
        );
      }
    }
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle,
      trailing: trailing,
    );
  }
}
