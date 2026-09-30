import 'dart:convert';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'config.dart';
import 'models.dart';

SupabaseClient get supa => Supabase.instance.client;

/// Every user's data lives under their own id (database rows and storage folders).
String get uid => supa.auth.currentUser!.id;

class Api {
  static const jobsBucket = 'jobs';
  static const parentBucket = 'parent';

  // ---------------------------------------------------------------- stats & activity
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

  // ---------------------------------------------------------------- jobs
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

  /// Deletes the job's files, then the job itself. A tiny "deleted" marker stays so the Scout never brings it back.
  static Future<void> deleteJob(String jobId) async {
    final dir = '$uid/$jobId';
    final files = await supa.storage.from(jobsBucket).list(path: dir);
    final paths = files.where((f) => f.id != null).map((f) => '$dir/${f.name}').toList();
    if (paths.isNotEmpty) await supa.storage.from(jobsBucket).remove(paths);
    await supa.rpc('delete_job', params: {'p_job_id': jobId});
  }

  // ---------------------------------------------------------------- batches
  static Stream<List<Batch>> batchesStream() => supa
      .from('batches')
      .stream(primaryKey: ['id'])
      .order('number')
      .limit(100)
      .map((rows) => rows.map(Batch.new).toList());

  // ---------------------------------------------------------------- kill switch
  static Stream<AgentControl?> controlStream() => supa
      .from('agent_control')
      .stream(primaryKey: ['id'])
      .map((rows) => rows.isEmpty ? null : AgentControl(rows.first));

  // ---------------------------------------------------------------- models (admin): routing, scorecard, comparisons
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

  // ---------------------------------------------------------------- 👍/👎 on a job's AI output (any user)
  static Future<Map<String, int>> myFeedback(String jobId) async {
    final rows = await supa.from('model_feedback').select('agent,rating').eq('job_id', jobId).eq('user_id', uid);
    return {for (final r in rows) r['agent'] as String: (r['rating'] as num).toInt()};
  }

  static Future<void> setFeedback(String jobId, String agent, String model, int? rating) => rating == null
      ? supa.from('model_feedback').delete().eq('user_id', uid).eq('job_id', jobId).eq('agent', agent)
      : supa.from('model_feedback').upsert(
          {'user_id': uid, 'job_id': jobId, 'agent': agent, 'model': model, 'rating': rating});

  static Future<void> setAgentsPaused(bool paused) =>
      supa.rpc('set_agents_paused', params: {'p_paused': paused, 'p_reason': paused ? 'Paused from the app' : null});

  // ---------------------------------------------------------------- files
  static Future<String> readText(String path, {String bucket = jobsBucket}) async =>
      utf8.decode(await supa.storage.from(bucket).download(path));

  static Future<Map<String, dynamic>> readJson(String path) async =>
      jsonDecode(await readText(path)) as Map<String, dynamic>;

  /// Opens a file in a new tab (web) or the system viewer (iOS). Signed URLs keep the bucket private.
  static Future<void> openFile(String path, {String bucket = jobsBucket, bool download = true}) async {
    final url = await supa.storage.from(bucket).createSignedUrl(
          path,
          60 * 60,
          download: download ? DownloadBehavior.withOriginalName : null,
        );
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  /// Parent documents live in `parent/<uid>/resume/` and `parent/<uid>/cover_letter/`.
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

  // ---------------------------------------------------------------- settings & profile
  static Future<Map<String, dynamic>> settings() => supa.from('settings').select().eq('user_id', uid).single();

  static Future<void> saveSettings(Map<String, dynamic> values) =>
      supa.from('settings').update(values).eq('user_id', uid);

  static Future<Map<String, dynamic>> profile() => supa
      .from('profile')
      .select('resume_filename,summary,skills,titles,updated_at,structured')
      .eq('user_id', uid)
      .single();

  /// Per-user limits set by the owner (read-only for the user).
  static Future<Map<String, dynamic>?> account() =>
      supa.from('accounts').select().eq('user_id', uid).maybeSingle();

  // ---------------------------------------------------------------- API keys
  // Key values are write-only: the database never returns them to the app, only the last 4 characters.
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

  // ---------------------------------------------------------------- admin (@rajkumar.codes) tools
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

  /// Starts the agents workflow on GitHub (via the database, which holds the GitHub token). Returns a request id.
  static Future<int> requestAgentsRun({bool allSources = true}) async =>
      (await supa.rpc('request_agents_run', params: {'all_sources': allSources}) as num).toInt();

  /// GitHub's answer for a request: 204 = started. Null while the request is still in flight.
  static Future<(int?, String?)> agentsRunRequestStatus(int id) async {
    final rows = await supa.rpc('agents_run_request_status', params: {'p_id': id}) as List;
    if (rows.isEmpty) return (null, null);
    final r = rows.first as Map<String, dynamic>;
    return ((r['status_code'] as num?)?.toInt(), r['message'] as String?);
  }
}
