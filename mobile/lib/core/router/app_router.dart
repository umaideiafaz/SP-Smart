import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sp_smart/features/setup/presentation/setup_screen.dart';
import 'package:sp_smart/features/broadcast/presentation/broadcast_screen.dart';
import 'package:sp_smart/features/settings/presentation/settings_screen.dart';


// ── Route names ───────────────────────────────────────────────
abstract class Routes {
  static const setup     = '/';
  static const broadcast = '/broadcast';
  static const settings  = '/settings';
}

// @riverpod
GoRouter appRouter(Ref ref) {
  return GoRouter(
    initialLocation: Routes.setup,
    debugLogDiagnostics: true,
    routes: [
      GoRoute(
        path: Routes.setup,
        name: 'setup',
        pageBuilder: (context, state) => const NoTransitionPage(
          child: SetupScreen(),
        ),
      ),
      GoRoute(
        path: Routes.broadcast,
        name: 'broadcast',
        pageBuilder: (context, state) => const NoTransitionPage(
          child: BroadcastScreen(),
        ),
      ),
      GoRoute(
        path: Routes.settings,
        name: 'settings',
        builder: (context, state) => const SettingsScreen(),
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(
        child: Text('Route not found: ${state.uri}'),
      ),
    ),
  );
}

final appRouterProvider = Provider<GoRouter>(appRouter);

