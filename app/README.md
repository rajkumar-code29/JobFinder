# JobFinder app

Flutter client for web and iOS. Needs `env.json` (copy `env.example.json`) with the Supabase URL and publishable key.

```bash
flutter run -d chrome --dart-define-from-file=env.json
flutter build ios --release --dart-define-from-file=env.json
```
