import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'screens/agents.dart';
import 'screens/home.dart';
import 'screens/interview.dart';
import 'screens/job_detail.dart';
import 'screens/jobs.dart';
import 'screens/login.dart';
import 'screens/settings.dart';
import 'widgets/shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();
  if (!AppConfig.isConfigured) {
    runApp(const _MissingConfig());
    return;
  }
  await Supabase.initialize(url: AppConfig.supabaseUrl, publishableKey: AppConfig.supabaseAnonKey);
  runApp(JobFinderApp());
}

class _AuthNotifier extends ChangeNotifier {
  _AuthNotifier() {
    _sub = Supabase.instance.client.auth.onAuthStateChange.listen((_) => notifyListeners());
  }
  late final StreamSubscription _sub;

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

class JobFinderApp extends StatelessWidget {
  JobFinderApp({super.key});

  final _auth = _AuthNotifier();

  late final _router = GoRouter(
    refreshListenable: _auth,
    redirect: (context, state) {
      final signedIn = Supabase.instance.client.auth.currentSession != null;
      final atLogin = state.matchedLocation == '/login';
      if (!signedIn) return atLogin ? null : '/login';
      if (atLogin) return '/';
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      ShellRoute(
        builder: (context, state, child) => AppShell(location: state.matchedLocation, child: child),
        routes: [
          GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
          GoRoute(
            path: '/jobs',
            builder: (_, state) => JobsScreen(initialStatus: state.uri.queryParameters['status']),
            routes: [
              GoRoute(
                path: ':jobId',
                builder: (_, state) => JobDetailScreen(jobId: state.pathParameters['jobId']!),
                routes: [
                  GoRoute(
                    path: 'interview',
                    builder: (_, state) => InterviewScreen(jobId: state.pathParameters['jobId']!),
                  ),
                ],
              ),
            ],
          ),
          GoRoute(path: '/agents', builder: (_, _) => const AgentsScreen()),
          GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
        ],
      ),
    ],
  );

  ThemeData _theme(Brightness b) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF3B5BDB), brightness: b);
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        margin: EdgeInsets.zero,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
        title: 'JobFinder',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        routerConfig: _router,
      );
}

class _MissingConfig extends StatelessWidget {
  const _MissingConfig();

  @override
  Widget build(BuildContext context) => const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Missing Supabase config.\nRun with --dart-define-from-file=env.json (see env.example.json).',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      );
}
