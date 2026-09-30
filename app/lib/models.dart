const na = 'NA';

bool isNa(String? v) => v == null || v.trim().isEmpty || v == na;

class Job {
  Job(this.raw);
  final Map<String, dynamic> raw;

  String get id => raw['id'] as String;
  String get jobId => raw['job_id'] as String;
  String get title => raw['title'] as String? ?? na;
  String get company => raw['company'] as String? ?? na;
  String get location => raw['location'] as String? ?? na;
  String get country => raw['country'] as String? ?? na;
  String get remote => raw['remote'] as String? ?? na;
  String get employmentType => raw['employment_type'] as String? ?? na;
  String get url => raw['url'] as String? ?? na;
  String get applyUrl => isNa(raw['apply_url'] as String?) ? url : raw['apply_url'] as String;
  String get description => raw['description'] as String? ?? na;
  String get salaryText => raw['salary_text'] as String? ?? na;
  String get salarySource => raw['salary_source'] as String? ?? na;
  String get postedAt => raw['posted_at'] as String? ?? na;
  String get source => raw['source'] as String? ?? na;
  String get status => raw['status'] as String? ?? 'new';
  String? get error => raw['error'] as String?;
  int? get relevance => raw['relevance'] as int?;
  String get relevanceReason => raw['relevance_reason'] as String? ?? na;
  int? get atsScore => raw['ats_score'] as int?;
  int? get shortlist => raw['shortlist_probability'] as int?;
  int? get tailoredAts => raw['tailored_ats_score'] as int?;
  DateTime get createdAt => DateTime.parse(raw['created_at'] as String).toLocal();
  DateTime? get appliedAt => raw['applied_at'] == null ? null : DateTime.parse(raw['applied_at'] as String).toLocal();
  String? get appliedWith => raw['applied_with'] as String?;

  Map<String, String> get files =>
      (raw['files'] as Map<String, dynamic>? ?? {}).map((k, v) => MapEntry(k, v.toString()));

  List<AddedSkill> get addedSkills => ((raw['added_skills'] as List?) ?? [])
      .whereType<Map>()
      .map((m) => AddedSkill(m['skill']?.toString() ?? '', m['why']?.toString() ?? ''))
      .where((s) => s.skill.isNotEmpty)
      .toList();

  bool get isReady => status == 'ready' || status == 'applied';
  bool get isApplied => status == 'applied';
  String? get batchId => raw['batch_id'] as String?;

  /// Which model produced each agent's output, e.g. {'tailor': 'gemini:gemini-3.8-flash'}.
  Map<String, String> get models => ((raw['meta'] as Map?)?['models'] as Map? ?? {})
      .map((k, v) => MapEntry(k.toString(), v.toString()));
  int? get batchRank => raw['batch_rank'] as int?;
}

class Batch {
  Batch(this.raw);
  final Map<String, dynamic> raw;
  String get id => raw['id'] as String;
  int get number => raw['number'] as int;
  String get status => raw['status'] as String;
  String get stage => raw['stage'] as String? ?? 'salary';
  int get jobCount => raw['job_count'] as int? ?? 0;
  DateTime get createdAt => DateTime.parse(raw['created_at'] as String).toLocal();
  bool get done => status == 'done';

  String get stageLabel => switch (stage) {
        'salary' => 'Checking salaries',
        'scoring' => 'Scoring & ranking',
        'tailoring' => 'Tailoring resumes',
        _ => 'Finished',
      };
}

class SetupStatus {
  const SetupStatus({
    required this.resumeDocx,
    required this.aiKey,
    required this.geminiKey,
    required this.locations,
    required this.roles,
    required this.jobBoards,
    required this.extraKeys,
    required this.privacyAccepted,
    required this.hasRun,
    this.waitingOn,
  });
  final bool resumeDocx, aiKey, geminiKey, locations, roles, jobBoards, extraKeys, privacyAccepted, hasRun;

  /// e.g. "No parent resume uploaded yet … Skipping this user." from the latest run
  final String? waitingOn;

  bool get ready => resumeDocx && aiKey && locations && roles;
}

class AgentControl {
  AgentControl(this.raw);
  final Map<String, dynamic> raw;
  bool get paused => raw['paused'] == true;
  String? get changedBy => raw['changed_by'] as String?;
  DateTime? get changedAt => raw['changed_at'] == null ? null : DateTime.parse(raw['changed_at'] as String).toLocal();
}

class AddedSkill {
  AddedSkill(this.skill, this.why);
  final String skill;
  final String why;
}

class Stats {
  Stats(this.raw);
  final Map<String, dynamic> raw;
  int _i(String k) => (raw[k] as num?)?.toInt() ?? 0;

  int get totalScanned => _i('total_scanned');
  int get totalMatched => _i('total_matched');
  int get ready => _i('ready');
  int get applied => _i('applied');
  int get totalErrors => _i('total_errors');
  int get errors24h => _i('errors_24h');
  int get agentsRunning => _i('agents_running');
  DateTime? get lastRunAt => raw['last_run_at'] == null ? null : DateTime.parse(raw['last_run_at'] as String).toLocal();
}

class AgentRun {
  AgentRun(this.raw);
  final Map<String, dynamic> raw;
  String get agent => raw['agent'] as String;
  String? get jobId => raw['job_id'] as String?;
  String get status => raw['status'] as String;
  String? get message => raw['message'] as String?;
  DateTime get startedAt => DateTime.parse(raw['started_at'] as String).toLocal();
  DateTime? get finishedAt => raw['finished_at'] == null ? null : DateTime.parse(raw['finished_at'] as String).toLocal();
  Duration? get duration => finishedAt?.difference(startedAt);
}
