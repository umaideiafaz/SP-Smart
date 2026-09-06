// dart format width=80
// GENERATED CODE - DO NOT MODIFY BY HAND

// ============================================================
// SP Smart — App Entry Point
// ============================================================
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sp_smart/core/router/app_router.dart';
import 'package:sp_smart/core/theme/app_theme.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  // Keep screen on during live broadcast
  await WakelockPlus.enable();

  runApp(
    // ProviderScope is the root of the Riverpod state tree
    const ProviderScope(
      child: SpSmartApp(),
    ),
  );
}

class SpSmartApp extends ConsumerWidget {
  const SpSmartApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);

    return MaterialApp.router(
      title: 'SP Smart Broadcast',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      routerConfig: router,
    );
  }
}
