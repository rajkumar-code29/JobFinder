import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'config.dart';
import 'models.dart';
import 'registration.dart';

SupabaseClient get supa => Supabase.instance.client;

/// Rows and storage folders are keyed by this.
String get uid => supa.auth.currentUser!.id;

class Api {
  static const jobsBucket = 'jobs';
  static const parentBucket = 'parent';

  // stats & activity
  static Future<Stats> stats() async =>
      Stats(await supa.from('dashboard_stats').select().single());

  static Stream<List<AgentRun>> agentRunsStream({int limit = 60}) => supa
      .from('agent_runs')
      .stream(primaryKey: ['id'])
      .order('started_at')
      .limit(limit)
      .map((rows) => rows.map(AgentRun.new).toList());

  static Future<List<Map<String, dynamic>>> pipelineRuns({int limit = 30}) =>
      supa.from('pipeline_runs').select().order('started_at', ascending: false).limit(limit);

  // jobs
  static Stream<List<Job>> jobsStream() => supa
      .from('jobs')
      .stream(primaryKey: ['id'])
      .order('created_at')
      .limit(300)
      .map((rows) => rows.map(Job.new).toList());

  static Stream<Job?> jobStream(String jobId) => supa
      .from('jobs')
      .stream(primaryKey: ['id'])
      .eq('job_id', jobId)
      .map((rows) => rows.isEmpty ? null : Job(rows.first));

  static Future<void> markApplied(String jobId, String appliedWith) => supa.from('jobs').update({
        'status': 'applied',
        'applied_at': DateTime.now().toUtc().toIso8601String(),
        'applied_with': appliedWith,
      }).eq('job_id', jobId);

  static Future<void> unmarkApplied(String jobId) => supa
      .from('jobs')
      .update({'status': 'ready', 'applied_at': null, 'applied_with': null}).eq('job_id', jobId);

  static Future<void> setApplied(Job job, bool applied) =>
      applied ? markApplied(job.jobId, 'marked in the app') : unmarkApplied(job.jobId);

  /// Files first, then the row (delete_job leaves a marker so the scout skips it).
  static Future<void> deleteJob(String jobId) async {
    final dir = '$uid/$jobId';
    final files = await supa.storage.from(jobsBucket).list(path: dir);
    final paths = files.where((f) => f.id != null).map((f) => '$dir/${f.name}').toList();
    if (paths.isNotEmpty) await supa.storage.from(jobsBucket).remove(paths);
    await supa.rpc('delete_job', params: {'p_job_id': jobId});
  }

  // batches
  static Stream<List<Batch>> batchesStream() => supa
      .from('batches')
      .stream(primaryKey: ['id'])
      .order('number')
      .limit(100)
      .map((rows) => rows.map(Batch.new).toList());

  // kill switch
  static Stream<AgentControl?> controlStream() => supa
      .from('agent_control')
      .stream(primaryKey: ['id'])
      .map((rows) => rows.isEmpty ? null : AgentControl(rows.first));

  // models (admin)
  static Future<Map<String, List<String>>> modelRouting() async {
    final rows = await supa.from('model_routing').select('agent,chain');
    return {for (final r in rows) r['agent'] as String: List<String>.from(r['chain'] as List)};
  }

  static Future<void> saveRouting(String agent, List<String> chain) => supa.from('model_routing').upsert({
        'agent': agent,
        'chain': chain,
        'updated_by': supa.auth.currentUser?.email,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });

  static Future<void> resetRouting(String agent) => supa.from('model_routing').delete().eq('agent', agent);

  static Future<List<Map<String, dynamic>>> scorecard({int days = 14}) async =>
      List<Map<String, dynamic>>.from(await supa.rpc('model_scorecard', params: {'p_days': days}) as List);

  static Stream<List<Map<String, dynamic>>> comparisonsStream() =>
      supa.from('model_comparisons').stream(primaryKey: ['id']).order('id').limit(30);

  static Future<int> requestComparison(String agent, List<String> models, int jobs) async =>
      (await supa.rpc('request_model_comparison', params: {'p_agent': agent, 'p_models': models, 'p_jobs': jobs}) as num)
          .toInt();

  static Stream<List<Map<String, dynamic>>> comparisonResultsStream(int id) =>
      supa.from('comparison_results').stream(primaryKey: ['id']).eq('comparison_id', id).order('id', ascending: true);

  static Future<Map<String, String>> myComparisonVotes(int id) async {
    final rows = await supa.from('comparison_votes').select('job_id,winner').eq('comparison_id', id).eq('user_id', uid);
    return {for (final r in rows) r['job_id'] as String: r['winner'] as String};
  }

  static Future<void> voteComparison(int id, String jobId, String winner) => supa
      .from('comparison_votes')
      .upsert({'comparison_id': id, 'job_id': jobId, 'user_id': uid, 'winner': winner});

  // feedback
  static Future<Map<String, int>> myFeedback(String jobId) async {
    final rows = await supa.from('model_feedback').select('agent,rating').eq('job_id', jobId).eq('user_id', uid);
    return {for (final r in rows) r['agent'] as String: (r['rating'] as num).toInt()};
  }

  static Future<void> setFeedback(String jobId, String agent, String model, int? rating) => rating == null
      ? supa.from('model_feedback').delete().eq('user_id', uid).eq('job_id', jobId).eq('agent', agent)
      : supa.from('model_feedback').upsert(
          {'user_id': uid, 'job_id': jobId, 'agent': agent, 'model': model, 'rating': rating});

  // onboarding
  static Future<void> acceptPrivacy() => supa.rpc('accept_privacy');

  /// What's still missing for the agents to run.
  static Future<SetupStatus> setupStatus() async {
    final results = await Future.wait([
      parentFiles('resume'),
      apiKeys(),
      account(),
      settings(),
      profile(),
      supa.from('pipeline_runs').select('started_at,log').eq('user_id', uid).order('started_at', ascending: false).limit(1),
    ]);
    final resume = results[0] as List<String>;
    final keys = results[1] as List<Map<String, dynamic>>;
    final acct = results[2] as Map<String, dynamic>?;
    final prefs = results[3] as Map<String, dynamic>;
    final prof = results[4] as Map<String, dynamic>;
    final runs = results[5] as List;
    final log = runs.isEmpty ? '' : '${(runs.first as Map)['log'] ?? ''}';
    final waiting = log.split('\n').where((l) => l.contains('Skipping this user')).map((l) => l.replaceFirst(RegExp(r'^\S+ '), '')).firstOrNull;
    return SetupStatus(
      resumeDocx: resume.any((f) => f.toLowerCase().endsWith('.docx')),
      aiKey: keys.any((k) => const {'gemini', 'groq', 'openrouter'}.contains(k['provider'])) || acct?['use_shared_keys'] == true,
      geminiKey: keys.any((k) => k['provider'] == 'gemini') || acct?['use_shared_keys'] == true,
      locations: ((prefs['countries'] as List?) ?? []).isNotEmpty,
      roles: ((prefs['target_roles'] as List?) ?? []).isNotEmpty || ((prof['titles'] as List?) ?? []).isNotEmpty,
      jobBoards: ((prefs['job_boards'] as List?) ?? []).isNotEmpty,
      extraKeys: keys.any((k) => const {'adzuna', 'rapidapi', 'groq'}.contains(k['provider'])),
      privacyAccepted: acct?['privacy_accepted_at'] != null,
      hasRun: runs.isNotEmpty,
      waitingOn: waiting,
    );
  }

  // registration and approval
  static Future<AuthResponse> register(Registration r) => supa.auth.signUp(
        email: r.email,
        password: r.password,
        data: r.metadata,
        // null on iOS -> Supabase uses the site URL
        emailRedirectTo: kIsWeb ? Uri.base.origin : null,
      );

  /// Own account row (status is watched by the access gate).
  static Stream<List<Map<String, dynamic>>> myAccountStream() =>
      supa.from('accounts').stream(primaryKey: ['user_id']).eq('user_id', uid);

  /// Admins get every account, everyone else only their own.
  static Stream<List<Map<String, dynamic>>> accountsStream() => supa.from('accounts').stream(primaryKey: ['user_id']);

  static Future<void> adminSetStatus(String userId, String status) =>
      supa.rpc('admin_set_status', params: {'p_user': userId, 'p_status': status});

  // admin: users
  static Future<List<Map<String, dynamic>>> adminUsers() async =>
      List<Map<String, dynamic>>.from(await supa.rpc('admin_users') as List);

  static Future<void> adminUpdateAccount(String userId, {required bool enabled, required bool useSharedKeys, required int llmCalls}) =>
      supa.rpc('admin_update_account', params: {
        'p_user': userId,
        'p_enabled': enabled,
        'p_use_shared_keys': useSharedKeys,
        'p_llm_calls_per_run': llmCalls,
      });

  static Future<void> setAgentsPaused(bool paused) =>
      supa.rpc('set_agents_paused', params: {'p_paused': paused, 'p_reason': paused ? 'Paused from the app' : null});

  // files
  static Future<String> readText(String path, {String bucket = jobsBucket}) async =>
      utf8.decode(await supa.storage.from(bucket).download(path));

  static Future<Map<String, dynamic>> readJson(String path) async =>
      jsonDecode(await readText(path)) as Map<String, dynamic>;

  /// Opens a signed URL (new tab on web, system viewer on iOS).
  static Future<void> openFile(String path, {String bucket = jobsBucket, bool download = true}) async {
    final url = await supa.storage.from(bucket).createSignedUrl(
          path,
          60 * 60,
          download: download ? DownloadBehavior.withOriginalName : null,
        );
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  /// `parent/<uid>/<folder>/`
  static Future<List<String>> parentFiles(String folder) async {
    final dir = '$uid/$folder';
    final items = await supa.storage.from(parentBucket).list(path: dir);
    return items.where((f) => f.id != null).map((f) => '$dir/${f.name}').toList();
  }

  static Future<void> replaceParent(String folder, List<(String, Uint8List)> files) async {
    final old = await parentFiles(folder);
    if (old.isNotEmpty) await supa.storage.from(parentBucket).remove(old);
    for (final (name, bytes) in files) {
      await supa.storage.from(parentBucket).uploadBinary(
            '$uid/$folder/$name',
            bytes,
            fileOptions: FileOptions(upsert: true, contentType: _mime(name)),
          );
    }
  }

  static String _mime(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.pdf')) return 'application/pdf';
    if (n.endsWith('.docx')) return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    return 'text/plain';
  }

  // settings & profile
  static Future<Map<String, dynamic>> settings() => supa.from('settings').select().eq('user_id', uid).single();

  static Future<void> saveSettings(Map<String, dynamic> values) =>
      supa.from('settings').update(values).eq('user_id', uid);

  static Future<Map<String, dynamic>> profile() => supa
      .from('profile')
      .select('resume_filename,summary,skills,titles,updated_at,structured')
      .eq('user_id', uid)
      .single();

  /// Limits set by the admin.
  static Future<Map<String, dynamic>?> account() =>
      supa.from('accounts').select().eq('user_id', uid).maybeSingle();

  // API keys
  // key_value is write-only, the DB only returns the hint
  static const _keyColumns = 'id,provider,label,app_id,hint,priority,exhausted_until,last_error,last_used_at,created_at';

  static Future<List<Map<String, dynamic>>> apiKeys() =>
      supa.from('api_keys').select(_keyColumns).order('provider').order('priority').order('created_at');

  static Future<void> addApiKey({
    required String provider,
    required String key,
    String label = '',
    String? appId,
    int priority = 0,
  }) =>
      supa.from('api_keys').insert({
        'provider': provider,
        'key_value': key.trim(),
        'label': label.trim(),
        'app_id': appId?.trim(),
        'priority': priority,
      });

  static Future<void> deleteApiKey(String id) => supa.from('api_keys').delete().eq('id', id);

  // admin
  static String? get currentEmail => supa.auth.currentUser?.email;

  static bool get isAdmin =>
      (supa.auth.currentUser?.email ?? '').toLowerCase().endsWith('@${AppConfig.adminEmailDomain}');

  static const _sharedColumns =
      'id,provider,label,source,app_id,hint,priority,enabled,in_use,exhausted_until,last_error,last_used_at,created_at';

  static Future<List<Map<String, dynamic>>> sharedKeys() =>
      supa.from('shared_api_keys').select(_sharedColumns).order('provider').order('priority').order('created_at');

  static Future<void> addSharedKey({
    required String provider,
    required String key,
    String label = '',
    String? appId,
    int priority = 0,
  }) =>
      supa.from('shared_api_keys').insert({
        'provider': provider,
        'key_value': key.trim(),
        'label': label.trim(),
        'app_id': appId?.trim(),
        'priority': priority,
      });

  static Future<void> updateSharedKey(String id, Map<String, dynamic> values) =>
      supa.from('shared_api_keys').update(values).eq('id', id);

  static Future<void> deleteSharedKey(String id) => supa.from('shared_api_keys').delete().eq('id', id);

  /// Dispatches the workflow through the DB (it holds the GitHub token).
  static Future<int> requestAgentsRun({bool allSources = true}) async =>
      (await supa.rpc('request_agents_run', params: {'all_sources': allSources}) as num).toInt();

  /// (status, message) from GitHub, 204 = started. Null until it answers.
  static Future<(int?, String?)> agentsRunRequestStatus(int id) async {
    final rows = await supa.rpc('agents_run_request_status', params: {'p_id': id}) as List;
    if (rows.isEmpty) return (null, null);
    final r = rows.first as Map<String, dynamic>;
    return ((r['status_code'] as num?)?.toInt(), r['message'] as String?);
  }
}
