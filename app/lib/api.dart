import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'config.dart';
import 'models.dart';
import 'registration.dart';
import 'screens/privacy_info.dart' show privacyVersion;

SupabaseClient get supa => Supabase.instance.client;

class BuilderException implements Exception {
  const BuilderException(this.message, this.code);
  final String message;
  final String? code;
  @override
  String toString() => message;
}

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

  // custom jobs (title + JD entered by hand)
  static Stream<List<Job>> customJobsStream() => supa
      .from('jobs')
      .stream(primaryKey: ['id'])
      .eq('source', 'custom')
      .order('created_at')
      .limit(300)
      .map((rows) => rows.map(Job.new).toList());

  /// Returns the new job id.
  static Future<String> addCustomJob({
    required String title,
    required String description,
    String? company,
    String? url,
    int? batch,
  }) async =>
      await supa.rpc('add_custom_job', params: {
        'p_title': title,
        'p_description': description,
        'p_company': company,
        'p_url': url,
        'p_batch': batch,
      }) as String;

  /// Puts a failed job back in the queue, keeping whatever the agents already made.
  static Future<void> retryJob(Job job) => supa.from('jobs').update({
        'attempts': 0,
        'error': null,
        'status': job.files.containsKey('resume_docx')
            ? 'tailored'
            : job.files.containsKey('report_json')
                ? 'scored'
                : 'new',
      }).eq('job_id', job.jobId);

  // credits and requested work (migration 012)
  static Stream<List<JobRequest>> requestsStream() => supa
      .from('job_requests')
      .stream(primaryKey: ['id'])
      .eq('user_id', uid)
      .order('created_at')
      .limit(300)
      .map((rows) => rows.map(JobRequest.new).toList());

  static Future<Credits> credits() async {
    final rows = await supa.rpc('my_credits') as List;
    if (rows.isEmpty) return const Credits(0, 0);
    final r = rows.first as Map<String, dynamic>;
    return Credits((r['credits'] as num).toInt(), (r['held'] as num).toInt());
  }

  /// kinds: 'tailor' (resume + cover letter) and/or 'interview'. Holds the credits; they're only taken on success.
  static Future<Map<String, dynamic>> requestWork(String jobId, List<String> kinds) async =>
      Map<String, dynamic>.from(await supa.rpc('request_job_work', params: {'p_job_id': jobId, 'p_kinds': kinds}) as Map);

  static Future<void> cancelRequest(int id) => supa.rpc('cancel_job_request', params: {'p_id': id});

  static Future<List<Map<String, dynamic>>> ledger() async =>
      List<Map<String, dynamic>>.from(await supa.from('credit_ledger').select().order('at', ascending: false).limit(100));

  // referrals
  static Future<Map<String, dynamic>> myReferrals() async {
    final rows = await supa.rpc('my_referrals') as List;
    return rows.isEmpty ? {} : Map<String, dynamic>.from(rows.first as Map);
  }

  static Future<Map<String, dynamic>> applyReferralCode(String code) async =>
      Map<String, dynamic>.from(await supa.rpc('apply_referral_code', params: {'p_code': code}) as Map);

  static Future<String> regenerateReferralCode() async => await supa.rpc('regenerate_referral_code') as String;

  static Future<List<Map<String, dynamic>>> adminReferrals() async =>
      List<Map<String, dynamic>>.from(await supa.rpc('admin_referrals') as List);

  // the shared Jobs board
  static Future<List<Map<String, dynamic>>> boardSearch({
    String query = '',
    String location = '',
    String remote = '',
    String type = '',
    int days = 0,
    num? salaryMin,
    String sort = 'newest',
    int offset = 0,
    int limit = 30,
  }) async =>
      List<Map<String, dynamic>>.from(await supa.rpc('board_search', params: {
        'p_query': query,
        'p_location': location,
        'p_remote': remote,
        'p_type': type,
        'p_days': days,
        'p_salary_min': salaryMin,
        'p_sort': sort,
        'p_limit': limit,
        'p_offset': offset,
      }) as List);

  static Future<Map<String, dynamic>?> boardPosting(int id) async {
    final rows = await supa.rpc('board_posting', params: {'p_id': id}) as List;
    return rows.isEmpty ? null : Map<String, dynamic>.from(rows.first as Map);
  }

  /// Copies a board posting into your own jobs; returns its job id.
  static Future<String> savePosting(int id) async => await supa.rpc('save_posting', params: {'p_id': id}) as String;

  // admin: credits and jobs
  static Future<List<Map<String, dynamic>>> adminSearchUsers(String query) async =>
      List<Map<String, dynamic>>.from(await supa.rpc('admin_search_users', params: {'p_query': query}) as List);

  static Future<int> adminAddCredits(String userId, int amount, String note) async =>
      (await supa.rpc('admin_add_credits', params: {'p_user': userId, 'p_amount': amount, 'p_note': note}) as num).toInt();

  /// To the board for everyone when [userId] is null, otherwise into that user's jobs.
  static Future<String> adminAddJob({
    required String title,
    required String company,
    required String description,
    String? location,
    String? url,
    String? remote,
    String? type,
    String? salary,
    String? userId,
  }) async =>
      await supa.rpc('admin_add_job', params: {
        'p_title': title,
        'p_company': company,
        'p_description': description,
        'p_location': location,
        'p_url': url,
        'p_remote': remote,
        'p_type': type,
        'p_salary': salary,
        'p_user': userId,
      }) as String;

  // resume builder
  static Stream<List<Map<String, dynamic>>> draftsStream() => supa
      .from('resume_drafts')
      .stream(primaryKey: ['id'])
      .order('updated_at')
      .limit(100);

  static Future<Map<String, dynamic>?> draft(String id) =>
      supa.from('resume_drafts').select().eq('id', id).maybeSingle();

  static Future<String> createDraft(String kind, String title, Map<String, dynamic> data) async =>
      (await supa.from('resume_drafts').insert({'kind': kind, 'title': title, 'data': data}).select('id').single())['id']
          as String;

  static Future<void> saveDraft(String id, String title, Map<String, dynamic> data) =>
      supa.from('resume_drafts').update({'title': title, 'data': data}).eq('id', id);

  static Future<void> deleteDraft(String id) => supa.from('resume_drafts').delete().eq('id', id);

  /// Calls an Edge Function. Throws [BuilderException] with a message that can be shown as is.
  static Future<Map<String, dynamic>> _invoke(String fn, Map<String, dynamic> body, String what) async {
    try {
      final res = await supa.functions.invoke(fn, body: body);
      return Map<String, dynamic>.from(res.data as Map);
    } on FunctionException catch (e) {
      final details = e.details;
      if (details is Map && details['error'] != null) {
        throw BuilderException('${details['error']}', details['code'] as String?);
      }
      if (e.status == 404) throw BuilderException('$what isn\'t switched on yet.', 'missing');
      throw BuilderException('$what failed (${e.status}). Try again in a minute.', null);
    }
  }

  static Future<Map<String, dynamic>> resumeAi(Map<String, dynamic> body) => _invoke('resume-ai', body, 'The resume builder');

  /// A Stripe Checkout page for a credit pack (website and Android).
  static Future<String> startCheckout(String pack) async =>
      (await _invoke('payments', {'action': 'checkout', 'pack': pack}, 'Buying credits'))['url'] as String;

  /// Has the server check an App Store purchase with Apple and add the credits.
  static Future<Map<String, dynamic>> verifyApplePurchase(String transactionId, String productId) =>
      _invoke('payments', {'action': 'apple', 'transaction_id': transactionId, 'product_id': productId}, 'App Store purchases');

  static Future<bool> hasMasterResume() async => (await parentFiles('resume')).isNotEmpty;

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
  static Future<void> acceptPrivacy() => supa.rpc('accept_privacy', params: {'p_version': privacyVersion});

  static Future<void> resendVerification(String email) =>
      supa.auth.resend(type: OtpType.signup, email: email, emailRedirectTo: kIsWeb ? Uri.base.origin : null);

  /// Deletes the account and everything in it (the account Edge Function), then signs out.
  static Future<void> deleteAccount() async {
    try {
      await supa.functions.invoke('account', body: {'action': 'delete', 'confirm': 'DELETE'});
    } on FunctionException catch (e) {
      final details = e.details;
      throw details is Map && details['error'] != null ? '${details['error']}' : 'Couldn\'t delete the account (${e.status})';
    }
    await supa.auth.signOut();
  }

  /// What's still missing for the agents to run.
  static Future<SetupStatus> setupStatus() async {
    final results = await Future.wait([
      parentFiles('resume'),
      settings(),
      profile(),
      supa.from('pipeline_runs').select('started_at,log').eq('user_id', uid).order('started_at', ascending: false).limit(1),
    ]);
    final resume = results[0] as List<String>;
    final prefs = results[1] as Map<String, dynamic>;
    final prof = results[2] as Map<String, dynamic>;
    final runs = results[3] as List;
    final log = runs.isEmpty ? '' : '${(runs.first as Map)['log'] ?? ''}';
    final waiting = log.split('\n').where((l) => l.contains('Skipping this user')).map((l) => l.replaceFirst(RegExp(r'^\S+ '), '')).firstOrNull;
    return SetupStatus(
      resumeDocx: resume.any((f) => f.toLowerCase().endsWith('.docx')),
      locations: ((prefs['countries'] as List?) ?? []).isNotEmpty,
      roles: ((prefs['target_roles'] as List?) ?? []).isNotEmpty || ((prof['titles'] as List?) ?? []).isNotEmpty,
      jobBoards: ((prefs['job_boards'] as List?) ?? []).isNotEmpty,
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
