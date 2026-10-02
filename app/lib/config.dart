/// Build-time config: `flutter run --dart-define-from-file=env.json` (see env.example.json).
class AppConfig {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  /// owner/repo, for the link to the workflow.
  static const githubRepo = String.fromEnvironment('GITHUB_REPO');

  /// Admin UI is shown for this email domain. The real check is public.is_admin() in the DB.
  static const adminEmailDomain = String.fromEnvironment('ADMIN_EMAIL_DOMAIN', defaultValue: 'rajkumar.codes');

  /// Web app address, for links from the iOS app (privacy policy).
  static const siteUrl = String.fromEnvironment('SITE_URL', defaultValue: 'https://jobs.rajkumar.codes');
  static const supportEmail = String.fromEnvironment('SUPPORT_EMAIL', defaultValue: 'support@rajkumar.codes');

  static bool get isConfigured => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
}
