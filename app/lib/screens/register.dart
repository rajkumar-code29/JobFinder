import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../config.dart';
import '../registration.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  String? _confirmEmail; // set when Supabase wants the email confirmed first

  Future<String?> _submit(Registration r) async {
    try {
      final res = await Api.register(r);
      // with email confirmation off we're signed in now and the router shows the waiting screen
      if (res.session == null && mounted) setState(() => _confirmEmail = r.email);
      return null;
    } on AuthException catch (e) {
      if (e.message.contains('Database error')) return 'Couldn\'t save your details. Check each field and try again.';
      return e.message;
    } catch (e) {
      return '$e';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.go('/login')),
        title: const Text('Create your account'),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: _confirmEmail != null
                ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Icon(Icons.mark_email_unread_outlined, size: 56, color: theme.colorScheme.primary),
                    const SizedBox(height: 12),
                    Text('Check your inbox', textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 8),
                    Text('We sent a confirmation link to $_confirmEmail. Open it, then sign in. '
                        'An admin approves new accounts, and you can use Pounce once you\'re approved.',
                        textAlign: TextAlign.center),
                    const SizedBox(height: 24),
                    FilledButton(onPressed: () => context.go('/login'), child: const Text('Back to sign in')),
                  ])
                : RegisterForm(onSubmit: _submit),
          ),
        ),
      ),
    );
  }
}

/// The sign-up form. onSubmit returns an error message, or null when it worked.
class RegisterForm extends StatefulWidget {
  const RegisterForm({super.key, required this.onSubmit});
  final Future<String?> Function(Registration) onSubmit;

  @override
  State<RegisterForm> createState() => _RegisterFormState();
}

class _RegisterFormState extends State<RegisterForm> {
  final _form = GlobalKey<FormState>();
  final _first = TextEditingController();
  final _last = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool? _wantsApp;
  String? _platform;
  bool _tried = false;
  bool _busy = false;
  String? _error;

  String? get _appError {
    if (!_tried) return null;
    if (_wantsApp == null) return 'Choose yes or no';
    if (_wantsApp! && _platform == null) return 'Choose iPhone or Android';
    return null;
  }

  Future<void> _submit() async {
    setState(() {
      _tried = true;
      _error = null;
    });
    final fieldsOk = _form.currentState!.validate();
    if (!fieldsOk || _appError != null) return;
    setState(() => _busy = true);
    final error = await widget.onSubmit(Registration(
      firstName: _first.text.trim(),
      lastName: _last.text.trim(),
      email: _email.text.trim(),
      phone: normalizePhone(_phone.text)!,
      password: _password.text,
      wantsMobileApp: _wantsApp!,
      mobilePlatform: _wantsApp! ? _platform : null,
    ));
    if (mounted) {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  InputDecoration _decoration(String label, {String? hint}) =>
      InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder(), errorMaxLines: 2);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final privacy = Uri.parse('${AppConfig.siteUrl}/privacy.html');
    return Form(
      key: _form,
      autovalidateMode: _tried ? AutovalidateMode.onUserInteraction : AutovalidateMode.disabled,
      child: AutofillGroup(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('An admin approves every new account. You can sign in once you\'re approved.',
              style: theme.textTheme.bodyMedium),
          const SizedBox(height: 20),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: TextFormField(
                key: const Key('first_name'),
                controller: _first,
                textCapitalization: TextCapitalization.words,
                autofillHints: const [AutofillHints.givenName],
                decoration: _decoration('First name'),
                validator: (v) => validateName(v, 'first name'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                key: const Key('last_name'),
                controller: _last,
                textCapitalization: TextCapitalization.words,
                autofillHints: const [AutofillHints.familyName],
                decoration: _decoration('Last name'),
                validator: (v) => validateName(v, 'last name'),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          TextFormField(
            key: const Key('email'),
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: _decoration('Email'),
            validator: validateEmail,
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: const Key('phone'),
            controller: _phone,
            keyboardType: TextInputType.phone,
            autofillHints: const [AutofillHints.telephoneNumber],
            decoration: _decoration('Phone number', hint: '+91 98765 43210'),
            validator: validatePhone,
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: const Key('password'),
            controller: _password,
            obscureText: true,
            autofillHints: const [AutofillHints.newPassword],
            decoration: _decoration('Password'),
            validator: validatePassword,
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: const Key('confirm'),
            controller: _confirm,
            obscureText: true,
            autofillHints: const [AutofillHints.newPassword],
            decoration: _decoration('Confirm password'),
            validator: (v) => v != _password.text ? 'The passwords don\'t match' : null,
          ),
          const SizedBox(height: 20),
          Text('Do you want the mobile app?', style: theme.textTheme.titleSmall),
          RadioGroup<bool>(
            groupValue: _wantsApp,
            onChanged: (v) => setState(() {
              _wantsApp = v;
              if (v != true) _platform = null;
            }),
            child: const Row(children: [
              Expanded(child: RadioListTile<bool>(key: Key('app_yes'), value: true, title: Text('Yes'), contentPadding: EdgeInsets.zero)),
              Expanded(child: RadioListTile<bool>(key: Key('app_no'), value: false, title: Text('No'), contentPadding: EdgeInsets.zero)),
            ]),
          ),
          if (_wantsApp == true) ...[
            Text('Which phone?', style: theme.textTheme.titleSmall),
            RadioGroup<String>(
              groupValue: _platform,
              onChanged: (v) => setState(() => _platform = v),
              child: const Row(children: [
                Expanded(child: RadioListTile<String>(key: Key('ios'), value: 'ios', title: Text('iPhone (iOS)'), contentPadding: EdgeInsets.zero)),
                Expanded(child: RadioListTile<String>(key: Key('android'), value: 'android', title: Text('Android'), contentPadding: EdgeInsets.zero)),
              ]),
            ),
          ],
          if (_appError != null) Text(_appError!, style: TextStyle(color: theme.colorScheme.error, fontSize: 12)),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: 20),
          FilledButton(
            key: const Key('register'),
            onPressed: _busy ? null : _submit,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: _busy
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Create account'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => launchUrl(privacy, mode: LaunchMode.externalApplication),
            child: const Text('By creating an account you agree to the privacy policy'),
          ),
        ]),
      ),
    );
  }
}
