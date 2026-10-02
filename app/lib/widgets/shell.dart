import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'common.dart';

/// Bottom nav on phones, rail on wide screens.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.location, required this.child});
  final String location;
  final Widget child;

  static const _tabs = [
    (path: '/', label: 'Home', icon: Icons.dashboard_outlined, selected: Icons.dashboard),
    (path: '/jobs', label: 'Jobs', icon: Icons.work_outline, selected: Icons.work),
    (path: '/agents', label: 'Agents', icon: Icons.smart_toy_outlined, selected: Icons.smart_toy),
    (path: '/settings', label: 'Settings', icon: Icons.tune_outlined, selected: Icons.tune),
  ];

  int get _index {
    for (var i = _tabs.length - 1; i > 0; i--) {
      if (location.startsWith(_tabs[i].path)) return i;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 840;
    void go(int i) => context.go(_tabs[i].path);
    if (wide) {
      return Scaffold(
        body: Row(children: [
          NavigationRail(
            selectedIndex: _index,
            onDestinationSelected: go,
            labelType: NavigationRailLabelType.all,
            leading: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: const AppLogo(size: 36),
            ),
            destinations: [
              for (final t in _tabs)
                NavigationRailDestination(icon: Icon(t.icon), selectedIcon: Icon(t.selected), label: Text(t.label)),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: child),
        ]),
      );
    }
    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: go,
        destinations: [
          for (final t in _tabs)
            NavigationDestination(icon: Icon(t.icon), selectedIcon: Icon(t.selected), label: t.label),
        ],
      ),
    );
  }
}
