/// How the agents will read a job-board link. Mirrors agents/jobfinder/sources/boards.py (detect) and
/// google_search.py (site_target).
class BoardKind {
  const BoardKind(this.label, {this.direct = false, this.warning});

  /// e.g. "Workday feed" or "Google search"
  final String label;

  /// true = read straight from the company's public job feed (full descriptions)
  final bool direct;

  /// shown under the link when results will be limited
  final String? warning;
}

const _aggregators = [
  'linkedin.', 'indeed.', 'glassdoor.', 'naukri.com', 'monster.', 'ziprecruiter.', 'seek.com', 'reed.co.uk',
  'totaljobs.', 'stepstone.', 'dice.com', 'foundit.', 'bayt.com', 'wellfound.com', 'simplyhired.', 'careerbuilder.',
];

BoardKind boardKind(String url) {
  final uri = Uri.tryParse(url.contains('://') ? url : 'https://$url');
  final host = (uri?.host ?? '').toLowerCase();
  final parts = (uri?.pathSegments ?? const []).where((p) => p.isNotEmpty).toList();

  if (host.contains('greenhouse.io')) return const BoardKind('Greenhouse feed', direct: true);
  if (host.endsWith('lever.co')) return const BoardKind('Lever feed', direct: true);
  if (host.endsWith('ashbyhq.com')) return const BoardKind('Ashby feed', direct: true);
  if (host.endsWith('workable.com')) return const BoardKind('Workable feed', direct: true);
  if (host == 'jobs.smartrecruiters.com' || host == 'careers.smartrecruiters.com') {
    return parts.isEmpty
        ? const BoardKind('Google search', warning: 'Add the company part too, e.g. jobs.smartrecruiters.com/BoschGroup')
        : const BoardKind('SmartRecruiters feed', direct: true);
  }
  if (host.endsWith('.myworkdayjobs.com') || host.endsWith('.myworkdaysite.com')) {
    final site = parts.where((p) => !RegExp(r'^[a-z]{2}(-[A-Za-z]{2})?$').hasMatch(p));
    return site.isEmpty
        ? const BoardKind('Google search',
            warning: 'Use the full careers-site link, e.g. company.wd5.myworkdayjobs.com/en-US/CareerSiteName')
        : const BoardKind('Workday feed', direct: true);
  }
  if (_aggregators.any((a) => host == a.replaceAll(RegExp(r'\.$'), '') || host.contains(a))) {
    return const BoardKind('Google search',
        warning: 'Google only shows part of this site and descriptions are short. JSearch (add a RapidAPI key '
            'under API keys) already covers LinkedIn, Indeed and Glassdoor with full descriptions.');
  }
  return const BoardKind('Google search',
      warning: 'Tip: if this careers page\'s "Apply" buttons lead to Greenhouse, Lever, Ashby, Workable, Workday or '
          'SmartRecruiters, paste that link instead for full job descriptions.');
}
