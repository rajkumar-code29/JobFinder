import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../models.dart';
import '../widgets/common.dart';
import '../widgets/credits.dart';

/// Filters on the Jobs board, in the order of the chips.
class BoardFilters {
  const BoardFilters({
    this.query = '',
    this.location = '',
    this.days = 0,
    this.remote = '',
    this.type = '',
    this.salaryMin,
    this.sort = 'newest',
  });
  final String query, location, remote, type, sort;
  final int days;
  final int? salaryMin;

  BoardFilters copyWith({String? query, String? location, int? days, String? remote, String? type, int? salaryMin,
          bool clearSalary = false, String? sort}) =>
      BoardFilters(
        query: query ?? this.query,
        location: location ?? this.location,
        days: days ?? this.days,
        remote: remote ?? this.remote,
        type: type ?? this.type,
        salaryMin: clearSalary ? null : (salaryMin ?? this.salaryMin),
        sort: sort ?? this.sort,
      );

  bool get any => days != 0 || remote.isNotEmpty || type.isNotEmpty || salaryMin != null;
}

typedef BoardSearch = Future<List<Map<String, dynamic>>> Function(BoardFilters filters, int offset);

Future<List<Map<String, dynamic>>> _search(BoardFilters f, int offset) => Api.boardSearch(
      query: f.query,
      location: f.location,
      days: f.days,
      remote: f.remote,
      type: f.type,
      salaryMin: f.salaryMin,
      sort: f.sort,
      offset: offset,
    );

const _dayOptions = {0: 'Any time', 1: 'Past 24 hours', 3: 'Past 3 days', 7: 'Past week', 30: 'Past month'};
const _remoteOptions = {'': 'Any workplace', 'remote': 'Remote', 'hybrid': 'Hybrid'};
const _typeOptions = {
  '': 'Any type',
  'full': 'Full-time',
  'part': 'Part-time',
  'contract': 'Contract',
  'intern': 'Internship',
  'temp': 'Temporary',
};
const _salaryOptions = {0: 'Any salary', 20000: '20,000+', 30000: '30,000+', 40000: '40,000+', 60000: '60,000+', 80000: '80,000+', 100000: '100,000+'};
const _sortOptions = {'newest': 'Newest', 'match': 'Best match for me', 'relevance': 'Most relevant'};

/// The shared Jobs board: every posting the agents have found, searchable like a job site.
class BoardScreen extends StatefulWidget {
  const BoardScreen({super.key, this.search});

  /// Tests pass their own search.
  final BoardSearch? search;

  @override
  State<BoardScreen> createState() => _BoardScreenState();
}

class _BoardScreenState extends State<BoardScreen> {
  final _query = TextEditingController();
  final _location = TextEditingController();
  final _scroll = ScrollController();
  BoardFilters _f = const BoardFilters();
  final List<Map<String, dynamic>> _items = [];
  int _total = 0;
  bool _loading = false;
  bool _done = false;
  Object? _error;
  int _generation = 0;

  BoardSearch get _searchFn => widget.search ?? _search;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 600) _more();
    });
    _reload();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _query.dispose();
    _location.dispose();
    super.dispose();
  }

  void _apply(BoardFilters f) {
    setState(() => _f = f);
    _reload();
  }

  void _submit() => _apply(_f.copyWith(
        query: _query.text.trim(),
        location: _location.text.trim(),
        sort: _query.text.trim().isNotEmpty && _f.sort == 'newest' ? 'relevance' : null,
      ));

  Future<void> _reload() async {
    final gen = ++_generation;
    setState(() {
      _items.clear();
      _total = 0;
      _done = false;
      _error = null;
    });
    await _fetch(gen);
  }

  Future<void> _more() async {
    if (_loading || _done || _error != null) return;
    await _fetch(_generation);
  }

  Future<void> _fetch(int gen) async {
    setState(() => _loading = true);
    try {
      final rows = await _searchFn(_f, _items.length);
      if (gen != _generation || !mounted) return;
      setState(() {
        _items.addAll(rows);
        if (rows.isNotEmpty) _total = (rows.first['total'] as num?)?.toInt() ?? _items.length;
        _done = rows.length < 30;
      });
    } catch (e) {
      if (gen == _generation && mounted) setState(() => _error = e);
    } finally {
      if (gen == _generation && mounted) setState(() => _loading = false);
    }
  }

  Future<T?> _pick<T>(String title, Map<T, String> options, T current) => showModalBottomSheet<T>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: RadioGroup<T>(
            groupValue: current,
            onChanged: (v) => Navigator.pop(ctx, v),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(title, style: Theme.of(ctx).textTheme.titleMedium),
              ),
              for (final e in options.entries) RadioListTile<T>(value: e.key, title: Text(e.value)),
              const SizedBox(height: 8),
            ]),
          ),
        ),
      );

  Widget _chip<T>(String title, Map<T, String> options, T value, T none, void Function(T) onPicked) {
    final active = value != none;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        selected: active,
        showCheckmark: false,
        label: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(active ? options[value]! : title),
          const SizedBox(width: 2),
          const Icon(Icons.arrow_drop_down, size: 18),
        ]),
        onSelected: (_) async {
          final picked = await _pick<T>(title, options, value);
          if (picked != null) onPicked(picked);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final searchBox = TextField(
      controller: _query,
      textInputAction: TextInputAction.search,
      onSubmitted: (_) => _submit(),
      decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Title, skill or company'),
    );
    final locationBox = TextField(
      controller: _location,
      textInputAction: TextInputAction.search,
      onSubmitted: (_) => _submit(),
      decoration: const InputDecoration(prefixIcon: Icon(Icons.place_outlined), hintText: 'City, country or Remote'),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Jobs'), actions: const [CreditsChip()]),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: ListView(controller: _scroll, padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
          PageBody(
            maxWidth: 980,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              LayoutBuilder(builder: (context, c) {
                final button = FilledButton(onPressed: _submit, child: const Text('Search'));
                if (c.maxWidth < 640) {
                  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    searchBox,
                    const SizedBox(height: 8),
                    Row(children: [Expanded(child: locationBox), const SizedBox(width: 8), button]),
                  ]);
                }
                return Row(children: [
                  Expanded(flex: 3, child: searchBox),
                  const SizedBox(width: 8),
                  Expanded(flex: 2, child: locationBox),
                  const SizedBox(width: 8),
                  button,
                ]);
              }),
              const SizedBox(height: 10),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  _chip<int>('Date posted', _dayOptions, _f.days, 0, (v) => _apply(_f.copyWith(days: v))),
                  _chip<String>('Workplace', _remoteOptions, _f.remote, '', (v) => _apply(_f.copyWith(remote: v))),
                  _chip<String>('Job type', _typeOptions, _f.type, '', (v) => _apply(_f.copyWith(type: v))),
                  _chip<int>('Salary', _salaryOptions, _f.salaryMin ?? 0, 0,
                      (v) => _apply(v == 0 ? _f.copyWith(clearSalary: true) : _f.copyWith(salaryMin: v))),
                  _chip<String>('Sort', _sortOptions, _f.sort, 'newest', (v) => _apply(_f.copyWith(sort: v))),
                  if (_f.any)
                    TextButton(
                      onPressed: () => _apply(BoardFilters(query: _f.query, location: _f.location, sort: _f.sort)),
                      child: const Text('Clear filters'),
                    ),
                ]),
              ),
              const SizedBox(height: 10),
              if (_error != null)
                ErrorView(errorText(_error!), onRetry: _reload)
              else ...[
                if (_items.isNotEmpty || !_loading)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      _items.isEmpty
                          ? 'No jobs match that. Try fewer words or clear some filters.'
                          : '$_total job${_total == 1 ? '' : 's'} · from job sites and company career pages, kept for 30 days',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                for (final item in _items) PostingCard(item: item),
                if (_loading)
                  const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

String _salary(Map<String, dynamic> p) {
  final text = '${p['salary_text'] ?? ''}';
  if (!isNa(text)) return text;
  final lo = p['salary_min'] as num?, hi = p['salary_max'] as num?;
  if (lo == null && hi == null) return '';
  final f = NumberFormat.compact();
  final cur = isNa(p['salary_currency'] as String?) ? '' : '${p['salary_currency']} ';
  return lo != null && hi != null && lo != hi ? '$cur${f.format(lo)} – ${f.format(hi)}' : '$cur${f.format(hi ?? lo)}';
}

String _type(String? raw) {
  final t = (raw ?? '').toLowerCase();
  if (isNa(raw)) return '';
  if (t.contains('full')) return 'Full-time';
  if (t.contains('part')) return 'Part-time';
  if (t.contains('contract')) return 'Contract';
  if (t.contains('intern')) return 'Internship';
  if (t.contains('temp')) return 'Temporary';
  return raw!;
}

class PostingCard extends StatelessWidget {
  const PostingCard({super.key, required this.item});
  final Map<String, dynamic> item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = item;
    final match = (p['my_match'] as num?)?.toInt();
    final saved = p['my_job_id'] != null;
    final seen = DateTime.tryParse('${p['first_seen']}')?.toLocal();
    final tags = [
      if (!isNa(p['remote'] as String?)) '${p['remote']}',
      if (_type(p['employment_type'] as String?).isNotEmpty) _type(p['employment_type'] as String?),
      if (_salary(p).isNotEmpty) _salary(p),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.go('/jobs/p/${p['id']}'),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: theme.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(12)),
                child: Text(
                  isNa(p['company'] as String?) ? '?' : '${p['company']}'.characters.first.toUpperCase(),
                  style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSecondaryContainer),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${p['title']}', style: theme.textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(
                    [p['company'], p['location']].where((x) => !isNa(x as String?)).join(' · '),
                    style: theme.textTheme.bodyMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (tags.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(spacing: 6, runSpacing: 4, children: [
                      for (final t in tags)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
                          child: Text(t, style: theme.textTheme.labelSmall),
                        ),
                    ]),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    [if (seen != null) 'Found ${ago(seen)}', if (saved) 'In your matches'].join(' · '),
                    style: theme.textTheme.labelSmall?.copyWith(color: saved ? theme.colorScheme.primary : null),
                  ),
                ]),
              ),
              if (match != null) ...[
                const SizedBox(width: 8),
                ScoreBadge(label: 'Match', score: match),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

/// One posting from the board.
class PostingScreen extends StatefulWidget {
  const PostingScreen({super.key, required this.id});
  final int id;

  @override
  State<PostingScreen> createState() => _PostingScreenState();
}

class _PostingScreenState extends State<PostingScreen> {
  late Future<Map<String, dynamic>?> _future = Api.boardPosting(widget.id);
  bool _busy = false;

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final jobId = await Api.savePosting(widget.id);
      if (!mounted) return;
      toast(context, 'Saved. Pick a tailored resume, cover letter or interview prep below.');
      context.go('/matches/$jobId');
    } catch (e) {
      if (mounted) toast(context, errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.canPop() ? context.pop() : context.go('/jobs')),
        title: const Text('Job'),
        actions: const [CreditsChip()],
      ),
      body: FutureBuilder<Map<String, dynamic>?>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) {
            return ErrorView(errorText(snap.error!), onRetry: () => setState(() => _future = Api.boardPosting(widget.id)));
          }
          if (!snap.hasData) {
            return snap.connectionState == ConnectionState.done
                ? const Center(child: Text('This job is no longer on the board'))
                : const Center(child: CircularProgressIndicator());
          }
          final row = snap.data!;
          final p = Map<String, dynamic>.from(row['posting'] as Map);
          final match = (row['my_match'] as num?)?.toInt();
          final jobId = row['my_job_id'] as String?;
          final link = isNa(p['apply_url'] as String?) ? p['url'] as String? : p['apply_url'] as String?;
          final seen = DateTime.tryParse('${p['first_seen']}')?.toLocal();
          return ListView(padding: const EdgeInsets.all(16), children: [
            PageBody(
              maxWidth: 860,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('${p['title']}', style: theme.textTheme.headlineSmall),
                const SizedBox(height: 4),
                Text([p['company'], p['location']].where((x) => !isNa(x as String?)).join(' · '),
                    style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.primary)),
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  if (match != null) ScoreBadge(label: 'Your match', score: match, big: true),
                  for (final (icon, text) in [
                    (Icons.home_work_outlined, isNa(p['remote'] as String?) ? '' : '${p['remote']}'),
                    (Icons.badge_outlined, _type(p['employment_type'] as String?)),
                    (Icons.payments_outlined, _salary(p)),
                    (Icons.schedule, seen == null ? '' : 'Found ${ago(seen)}'),
                    (Icons.hub_outlined, '${p['source']}'),
                  ])
                    if (text.isNotEmpty) Chip(avatar: Icon(icon, size: 16), label: Text(text)),
                ]),
                const SizedBox(height: 14),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      if (jobId != null) ...[
                        Text('This job is in your matches', style: theme.textTheme.titleMedium),
                        const SizedBox(height: 4),
                        const Text('Open it there to get a tailored resume, cover letter or interview prep.'),
                        const SizedBox(height: 10),
                        FilledButton.icon(
                          onPressed: () => context.go('/matches/$jobId'),
                          icon: const Icon(Icons.arrow_forward),
                          label: const Text('Open in Matches'),
                        ),
                      ] else ...[
                        Text('Interested?', style: theme.textTheme.titleMedium),
                        const SizedBox(height: 4),
                        Text(
                          match == null
                              ? 'Save it to your matches (free) and it gets scored against your resume. Then pick a '
                                  'tailored resume and cover letter or interview prep, 1 credit each.'
                              : 'Save it to your matches (free), then pick a tailored resume and cover letter or interview '
                                  'prep, 1 credit each.',
                        ),
                        const SizedBox(height: 10),
                        FilledButton.icon(
                          onPressed: _busy ? null : _save,
                          icon: const Icon(Icons.bookmark_add_outlined),
                          label: const Text('Save to my matches'),
                        ),
                      ],
                      if (!isNa(link)) ...[
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: () => launchUrl(Uri.parse(link!), mode: LaunchMode.externalApplication),
                          icon: const Icon(Icons.open_in_new),
                          label: const Text('Open the original posting'),
                        ),
                      ],
                    ]),
                  ),
                ),
                const SizedBox(height: 14),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Job description', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 8),
                      SelectableText(isNa(p['description'] as String?)
                          ? 'The source only gave a short summary. Open the original posting for the full description.'
                          : '${p['description']}'),
                    ]),
                  ),
                ),
              ]),
            ),
          ]);
        },
      ),
    );
  }
}
