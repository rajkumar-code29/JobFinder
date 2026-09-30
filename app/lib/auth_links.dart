import 'package:flutter/foundation.dart';

/// Invite and password-reset emails land on the web app as
/// `https://jobs.example.com/#access_token=…&type=invite` (or `type=recovery`),
/// and expired/used links as `#error=…&error_description=…`.
/// Supabase turns the tokens into a session; we additionally remember that this person
/// still has to choose a password, and surface link errors on the login screen.
class AuthLinks {
  static final needsPassword = ValueNotifier<bool>(false);
  static String? linkError;

  /// Call before Supabase.initialize(), which consumes the URL fragment.
  static void captureInitialUrl() {
    if (!kIsWeb) return;
    final params = <String, String>{...Uri.base.queryParameters};
    try {
      params.addAll(Uri.splitQueryString(Uri.base.fragment));
    } catch (_) {}
    final type = params['type'];
    if (params.containsKey('access_token') && (type == 'invite' || type == 'recovery')) {
      needsPassword.value = true;
    }
    final error = params['error_description'] ?? params['error'];
    if (error != null && error.isNotEmpty) linkError = error;
  }
}
