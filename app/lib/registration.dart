/// Sign-up details and the form rules. Migration 008 repeats the important ones in the database.
class Registration {
  const Registration({
    required this.firstName,
    required this.lastName,
    required this.email,
    required this.phone,
    required this.password,
    required this.wantsMobileApp,
    this.mobilePlatform,
  });

  final String firstName, lastName, email, phone, password;
  final bool wantsMobileApp;
  final String? mobilePlatform; // 'ios' | 'android'

  /// Stored as user metadata; the new-user trigger copies it into accounts.
  Map<String, dynamic> get metadata => {
        'first_name': firstName,
        'last_name': lastName,
        'phone': phone,
        'wants_mobile_app': wantsMobileApp,
        if (wantsMobileApp) 'mobile_platform': mobilePlatform,
      };
}

// letters in any alphabet (José, राज), nothing else
final _letters = RegExp(r'^[\p{L}\p{M}]+$', unicode: true);
final _email = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@.]{2,}$');
final _phoneChars = RegExp(r'^\+?[\d\s\-().]+$');

String? validateName(String? value, String field) {
  final v = (value ?? '').trim();
  if (v.isEmpty) return 'Enter your $field';
  if (v.runes.length > 50) return 'Use at most 50 letters';
  if (!_letters.hasMatch(v)) return 'Letters only: no spaces, numbers or symbols';
  return null;
}

String? validateEmail(String? value) {
  final v = (value ?? '').trim();
  if (v.isEmpty) return 'Enter your email';
  if (!_email.hasMatch(v)) return 'Enter a valid email, e.g. name@example.com';
  return null;
}

/// "+91 98765-43210" -> "+919876543210". Null unless it has 7-15 digits.
String? normalizePhone(String? value) {
  final v = (value ?? '').trim();
  if (!_phoneChars.hasMatch(v)) return null;
  final digits = v.replaceAll(RegExp(r'\D'), '');
  if (digits.length < 7 || digits.length > 15) return null;
  return '${v.startsWith('+') ? '+' : ''}$digits';
}

String? validatePhone(String? value) {
  if ((value ?? '').trim().isEmpty) return 'Enter your phone number';
  if (normalizePhone(value) == null) return 'Enter a valid number with country code, e.g. +91 98765 43210';
  return null;
}

String? validatePassword(String? value) =>
    (value ?? '').length < 8 ? 'Use at least 8 characters' : null;
