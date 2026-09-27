import 'dart:convert';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

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
}
