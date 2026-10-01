import 'package:flutter/foundation.dart';

/// Invite/reset links arrive with `#access_token=...&type=invite|recovery`, or `#error_description=...`
/// when the link is dead. Supabase handles the session; we just remember to ask for a password.
class AuthLinks {
  static final needsPassword = ValueNotifier<bool>(false);
  static String? linkError;

  /// Must run before Supabase.initialize() eats the fragment.
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
