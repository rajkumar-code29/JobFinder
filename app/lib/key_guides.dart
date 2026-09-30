import 'dart:convert';

import 'package:http/http.dart' as http;

/// How to get each provider's key, and a quick live check run from this device (the key never goes through
/// our database). Used by Settings → API keys → Add API key.
class KeyGuide {
  const KeyGuide({required this.url, required this.steps, this.note, this.keyHint});
  final String url;
  final List<String> steps;
  final String? note;
  final String? keyHint;
}

const keyGuides = {
  'gemini': KeyGuide(
    url: 'https://aistudio.google.com/apikey',
    keyHint: 'starts with AIza',
    steps: [
      'Open Google AI Studio and sign in with your own Google account.',
      'Click "Create API key" (let it create a project if asked).',
      'Copy the key and paste it below, then tap Test.',
    ],
    note: 'Free and required: the agents use it for tailoring, interview prep, scoring and salary search. '
        'Create it in your own Google account – keys from the same project share one free quota.',
  ),
  'groq': KeyGuide(
    url: 'https://console.groq.com/keys',
    keyHint: 'starts with gsk_',
    steps: [
      'Open console.groq.com and sign up (free).',
      'Go to API Keys → Create API Key, give it a name.',
      'Copy the key (it is shown only once) and paste it below.',
    ],
    note: 'Optional. Free tier ≈1,000 requests/day per model but only short prompts, so it helps the Scout '
        'and the Writer if your admin routes them to Groq.',
  ),
  'openrouter': KeyGuide(
    url: 'https://openrouter.ai/keys',
    keyHint: 'starts with sk-or-',
    steps: ['Sign in at openrouter.ai.', 'Open Keys → Create key.', 'Copy it and paste it below.'],
    note: 'Optional fallback. Free models allow about 50 requests a day.',
  ),
  'adzuna': KeyGuide(
    url: 'https://developer.adzuna.com/signup',
    steps: [
      'Register at developer.adzuna.com (free).',
      'Open your Dashboard: your app shows an "Application ID" and an "Application Key".',
      'Paste the ID into "Adzuna app id" and the key into "Adzuna app key".',
    ],
    note: 'Optional but recommended: a big job aggregator in 19 countries.',
  ),
  'rapidapi': KeyGuide(
    url: 'https://rapidapi.com/letscrape-6bRBa3QguO5/api/jsearch',
    steps: [
      'Sign up at rapidapi.com and open the JSearch API page.',
      'Click "Subscribe to Test" and choose the free Basic plan.',
      'On the API page, copy the "X-RapidAPI-Key" value and paste it below.',
    ],
    note: 'Optional: LinkedIn / Indeed / Glassdoor postings with full descriptions. Free plan is 200 requests '
        'a month, so the agents use it once a day. Testing uses one of those requests.',
  ),
};

class KeyTestResult {
  const KeyTestResult(this.ok, this.message);
  final bool ok;
  final String message;
}

String _error(http.Response r) {
  try {
    final body = jsonDecode(r.body);
    final err = body is Map ? (body['error'] ?? body['message'] ?? body) : body;
    return err is Map ? '${err['message'] ?? err}' : '$err';
  } catch (_) {
    return r.body.length > 160 ? r.body.substring(0, 160) : r.body;
  }
}

/// Live check of a key. Returns a friendly verdict.
Future<KeyTestResult> testKey(String provider, String key, {String? appId}) async {
  key = key.trim();
  try {
    switch (provider) {
      case 'gemini':
        final list = await http.get(Uri.parse('https://generativelanguage.googleapis.com/v1beta/models?key=$key&pageSize=200'));
        if (list.statusCode != 200) return KeyTestResult(false, 'Google rejected the key: ${_error(list)}');
        final models = ((jsonDecode(list.body)['models'] as List?) ?? []).map((m) => '${m['name']}').toList();
        final lite = models.where((m) => RegExp(r'gemini-[\d.]+-flash-lite$').hasMatch(m)).toList()..sort();
        if (lite.isEmpty) return const KeyTestResult(true, 'Key works (no Flash-Lite model found to test the free quota).');
        final gen = await http.post(
          Uri.parse('https://generativelanguage.googleapis.com/v1beta/${lite.last}:generateContent?key=$key'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'contents': [{'parts': [{'text': 'Reply with the single word OK'}]}],
            'generationConfig': {'maxOutputTokens': 5},
          }),
        );
        if (gen.statusCode == 200) return const KeyTestResult(true, 'Key works and has free quota available.');
        if (gen.statusCode == 429) {
          return KeyTestResult(false, gen.body.contains('limit: 0')
              ? 'Key is valid, but this project has no free-tier quota. Create the key in a Google account with the free tier.'
              : 'Key is valid but its limit is used up right now – it will work again later.');
        }
        return KeyTestResult(false, 'Key is valid, but a test request failed: ${_error(gen)}');
      case 'groq':
        final r = await http.get(Uri.parse('https://api.groq.com/openai/v1/models'), headers: {'Authorization': 'Bearer $key'});
        return r.statusCode == 200
            ? KeyTestResult(true, 'Key works (${((jsonDecode(r.body)['data'] as List?) ?? []).length} models available).')
            : KeyTestResult(false, 'Groq rejected the key: ${_error(r)}');
      case 'openrouter':
        final r = await http.get(Uri.parse('https://openrouter.ai/api/v1/key'), headers: {'Authorization': 'Bearer $key'});
        return r.statusCode == 200
            ? const KeyTestResult(true, 'Key works.')
            : KeyTestResult(false, 'OpenRouter rejected the key: ${_error(r)}');
      case 'adzuna':
        if ((appId ?? '').trim().isEmpty) return const KeyTestResult(false, 'Enter the Adzuna app id too.');
        final r = await http.get(Uri.parse('https://api.adzuna.com/v1/api/jobs/gb/search/1'
            '?app_id=${Uri.encodeQueryComponent(appId!.trim())}&app_key=${Uri.encodeQueryComponent(key)}&results_per_page=1'));
        return r.statusCode == 200
            ? const KeyTestResult(true, 'App id and key work.')
            : KeyTestResult(false, 'Adzuna rejected them (HTTP ${r.statusCode}): ${_error(r)}');
      case 'rapidapi':
        final r = await http.get(Uri.parse('https://jsearch.p.rapidapi.com/search?query=developer&num_pages=1'),
            headers: {'X-RapidAPI-Key': key, 'X-RapidAPI-Host': 'jsearch.p.rapidapi.com'});
        if (r.statusCode == 200) return const KeyTestResult(true, 'Key works and is subscribed to JSearch.');
        if (r.statusCode == 403) return const KeyTestResult(false, 'Key is valid but not subscribed to JSearch – subscribe to the free Basic plan.');
        return KeyTestResult(false, 'RapidAPI rejected the key (HTTP ${r.statusCode}): ${_error(r)}');
    }
    return const KeyTestResult(false, 'No test available for this provider.');
  } catch (e) {
    // Browsers can block some providers' APIs from web pages (CORS); the phone app isn't affected.
    return KeyTestResult(false, 'Couldn\'t reach the provider from here ($e). If you\'re on the web app, it may '
        'block this test – the agents will still check the key on their next run.');
  }
}
