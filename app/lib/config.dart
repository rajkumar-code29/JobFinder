/// Build-time config: `flutter run --dart-define-from-file=env.json` (see env.example.json).
class AppConfig {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  /// owner/repo, for the link to the workflow.
  static const githubRepo = String.fromEnvironment('GITHUB_REPO');

  /// Admin UI is shown for this email domain. The real check is public.is_admin() in the DB.
  static const adminEmailDomain = String.fromEnvironment('ADMIN_EMAIL_DOMAIN', defaultValue: 'rajkumar.codes');

  static bool get isConfigured => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
}
