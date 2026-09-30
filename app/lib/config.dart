/// Values injected at build time:
///   flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
/// or `--dart-define-from-file=env.json` (see env.example.json).
class AppConfig {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  /// "owner/repo" – used to link to the agents workflow for manual runs.
  static const githubRepo = String.fromEnvironment('GITHUB_REPO');

  /// Accounts with an email on this domain get the admin tools (shared keys, Run now).
  /// The database enforces the same rule (public.is_admin()); this only decides what the UI shows.
  static const adminEmailDomain = String.fromEnvironment('ADMIN_EMAIL_DOMAIN', defaultValue: 'rajkumar.codes');

  static bool get isConfigured => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
}
