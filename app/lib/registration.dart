/// Sign-up details and the form rules. Migration 008 repeats the name rules in the database.
class Registration {
  const Registration({
    required this.firstName,
    required this.lastName,
    required this.email,
    required this.password,
    this.referralCode = '',
  });

  final String firstName, lastName, email, password, referralCode;

  /// Stored as user metadata; the new-user trigger copies it into accounts.
  Map<String, dynamic> get metadata => {
        'first_name': firstName,
        'last_name': lastName,
        if (referralCode.isNotEmpty) 'referral_code': referralCode,
      };
}

/// "ab cd-1234" -> "ABCD1234"
String normalizeReferralCode(String? value) => (value ?? '').toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

String? validateReferralCode(String? value) {
  final v = normalizeReferralCode(value);
  if (v.isEmpty) return null;
  if (v.length != 8) return 'Referral codes have 8 letters and numbers';
  return null;
}

// letters in any alphabet (José, राज), nothing else
final _letters = RegExp(r'^[\p{L}\p{M}]+$', unicode: true);
final _email = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@.]{2,}$');

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

String? validatePassword(String? value) =>
    (value ?? '').length < 8 ? 'Use at least 8 characters' : null;
