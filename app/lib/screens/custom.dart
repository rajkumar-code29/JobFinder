import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../api.dart';
import '../models.dart';
import '../widgets/common.dart';
import '../widgets/credits.dart';
import 'jobs.dart';

/// Jobs the user found themselves: paste the title and JD, then process them on demand.
/// They stay on this page and never join the hourly batches.
class CustomJobsScreen extends StatefulWidget {
  const CustomJobsScreen({super.key, this.jobs});

  /// Tests pass their own list.
  final Stream<List<Job>>? jobs;

  @override
  State<CustomJobsScreen> createState() => _CustomJobsScreenState();
}

class _CustomJobsScreenState extends State<CustomJobsScreen> {
  late final Stream<List<Job>> _jobs = widget.jobs ?? Api.customJobsStream();
  final _collapsed = <int>{};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Custom Jobs')),
      body: StreamBuilder<List<Job>>(
        stream: _jobs,
        builder: (context, snap) {
          if (snap.hasError) return ErrorView(snap.error!);
          final jobs = snap.data;
          final byBatch = <int, List<Job>>{};
          for (final j in jobs ?? <Job>[]) {
            byBatch.putIfAbsent(j.customBatch ?? 0, () => []).add(j);
          }
          final batches = byBatch.keys.toList()..sort((a, b) => b.compareTo(a));
          final lastBatch = batches.isEmpty ? 0 : batches.first;

          return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
            PageBody(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(
                  'Found a job yourself? Paste it here and Pounce scores it against your resume, then makes a tailored '
                  'resume, a cover letter and interview prep, the same as for the hourly jobs. These stay on this '
                  'page and don\'t mix with your regular batches.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                _AddJobCard(ready: jobs != null, nextBatch: lastBatch + 1),
                const SizedBox(height: 12),
                if (jobs != null) _HowItWorks(jobs: jobs),
                if (jobs == null)
                  const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
                for (final b in batches) ...[
                  InkWell(
                    onTap: () => setState(() => _collapsed.contains(b) ? _collapsed.remove(b) : _collapsed.add(b)),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(0, 20, 0, 4),
                      child: Row(children: [
                        Expanded(child: _BatchHeader(number: b, jobs: byBatch[b]!)),
                        Icon(_collapsed.contains(b) ? Icons.expand_more : Icons.expand_less),
                      ]),
                    ),
                  ),
                  if (!_collapsed.contains(b))
                    LayoutBuilder(builder: (context, c) {
                      final cols = (c.maxWidth / 360).floor().clamp(1, 3);
                      final items = [...byBatch[b]!]..sort((x, y) => x.createdAt.compareTo(y.createdAt));
                      return GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        padding: const EdgeInsets.only(top: 8),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: cols,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          mainAxisExtent: 226,
                        ),
                        itemCount: items.length,
                        itemBuilder: (_, i) => JobCard(job: items[i]),
                      );
                    }),
                ],
              ]),
            ),
          ]);
        },
      ),
    );
  }
}

String _errorText(Object e) => e is PostgrestException ? e.message : '$e';

class _AddJobCard extends StatefulWidget {
  const _AddJobCard({required this.ready, required this.nextBatch});
  final bool ready;
  final int nextBatch;

  @override
  State<_AddJobCard> createState() => _AddJobCardState();
}

class _AddJobCardState extends State<_AddJobCard> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _company = TextEditingController();
  final _jd = TextEditingController();
  final _link = TextEditingController();
  final _batch = TextEditingController();
  bool _batchSet = false;
  bool _saving = false;
  bool _tailor = true;
  bool _interview = false;

  @override
  void didUpdateWidget(_AddJobCard old) {
    super.didUpdateWidget(old);
    _prefillBatch();
  }

  @override
  void initState() {
    super.initState();
    _prefillBatch();
  }

  /// Next batch number once the list has loaded. After that it stays put, so several jobs added in one
  /// go land in the same batch.
  void _prefillBatch() {
    if (_batchSet || !widget.ready) return;
    _batch.text = '${widget.nextBatch}';
    _batchSet = true;
  }

  @override
  void dispose() {
    for (final c in [_title, _company, _jd, _link, _batch]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final id = await Api.addCustomJob(
        title: _title.text.trim(),
        description: _jd.text.trim(),
        company: _company.text.trim().isEmpty ? null : _company.text.trim(),
        url: _link.text.trim().isEmpty ? null : _link.text.trim(),
        batch: int.tryParse(_batch.text.trim()),
      );
      if (!mounted) return;
      final kinds = [if (_tailor) 'tailor', if (_interview) 'interview'];
      String note;
      try {
        await Api.requestWork(id, kinds); // scoring is always included and free
        note = kinds.isEmpty
            ? 'Added $id. It gets scored against your resume in a few minutes.'
            : 'Added $id. Scoring it now, then ${kinds.length == 2 ? 'the tailored resume, cover letter and interview prep' : kinds.first == 'tailor' ? 'the tailored resume and cover letter' : 'interview prep'}. It takes a few minutes.';
      } catch (e) {
        note = 'Added $id, but: ${errorText(e)} Open the job to try again.';
      }
      for (final c in [_title, _company, _jd, _link]) {
        c.clear();
      }
      if (mounted) toast(context, note);
    } catch (e) {
      if (mounted) toast(context, 'Could not add the job: ${_errorText(e)}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _form,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Add a job', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            TextFormField(
              controller: _title,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Job title', border: OutlineInputBorder()),
              validator: (v) => (v ?? '').trim().length < 2 ? 'Add the job title' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _company,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Company (optional)',
                helperText: 'Helps the cover letter and the salary estimate',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _jd,
              minLines: 6,
              maxLines: 16,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(
                labelText: 'Job description',
                hintText: 'Paste the full description: responsibilities, requirements, nice-to-haves',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
              validator: (v) => (v ?? '').trim().length < 50 ? 'Paste the full job description' : null,
            ),
            const SizedBox(height: 12),
            LayoutBuilder(builder: (context, c) {
              final link = TextFormField(
                controller: _link,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Career page or application link (optional)',
                  border: OutlineInputBorder(),
                ),
              );
              final batch = TextFormField(
                controller: _batch,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'Batch number', border: OutlineInputBorder()),
                validator: (v) => (int.tryParse(v ?? '') ?? 0) < 1 ? '1 or more' : null,
              );
              if (c.maxWidth < 520) {
                return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  link,
                  const SizedBox(height: 12),
                  batch,
                ]);
              }
              return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: link),
                const SizedBox(width: 12),
                SizedBox(width: 150, child: batch),
              ]);
            }),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _tailor,
              onChanged: (v) => setState(() => _tailor = v ?? false),
              title: const Text('Tailored resume and cover letter'),
              subtitle: const Text('1 credit, only used if it works'),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _interview,
              onChanged: (v) => setState(() => _interview = v ?? false),
              title: const Text('Interview prep'),
              subtitle: const Text('1 credit, only used if it works'),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _saving || !widget.ready ? null : _save,
                icon: _saving
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.add),
                label: const Text('Add job'),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _HowItWorks extends StatelessWidget {
  const _HowItWorks({required this.jobs});
  final List<Job> jobs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = jobs.where((j) => j.hasTailored).length;
    final failed = jobs.where((j) => j.status == 'error').length;
    return Card(
      child: ListTile(
        leading: Icon(Icons.info_outline, color: theme.colorScheme.primary),
        title: Text(jobs.isEmpty ? 'How it works' : '${jobs.length} custom job${jobs.length == 1 ? '' : 's'} · $ready ready'
            '${failed > 0 ? ' · $failed need attention' : ''}'),
        subtitle: const Text('Each job you add is scored against your resume for free. Tick what else you want when you '
            'add it, or open the job later: a tailored resume and cover letter, or interview prep, 1 credit each.'),
      ),
    );
  }
}

class _BatchHeader extends StatelessWidget {
  const _BatchHeader({required this.number, required this.jobs});
  final int number;
  final List<Job> jobs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = jobs.where((j) => j.isReady).length;
    final newest = jobs.map((j) => j.createdAt).reduce((a, b) => a.isAfter(b) ? a : b);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Batch $number', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: 2),
      Text('Last added ${DateFormat.MMMd().add_jm().format(newest)} · $ready of ${jobs.length} ready',
          style: theme.textTheme.bodySmall),
      const SizedBox(height: 6),
      LinearProgressIndicator(
          value: jobs.isEmpty ? 0 : ready / jobs.length, minHeight: 4, borderRadius: BorderRadius.circular(4)),
    ]);
  }
}
