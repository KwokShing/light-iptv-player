import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'controllers/epg_controller.dart';
import 'controllers/playback_controller.dart';
import 'controllers/proxy_controller.dart';
import 'controllers/sources_controller.dart';
import 'controllers/ui_controller.dart';
import 'controllers/update_controller.dart';
import 'controllers/user_agent_controller.dart';
import 'constants.dart';
import 'pages/player_page.dart';
import 'pages/sources_page.dart';
import 'services/proxy_service.dart';
import 'theme.dart';

// Re-exported so existing imports (e.g. tests) that reference these from
// `package:light_iptv_player/main.dart` keep working after the split.
export 'constants.dart';
export 'models/playlist.dart';
export 'services/playlist_parser.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _filterNoisyDebugLogs();
  // Keep more decoded logos resident so scrolling back through a long channel
  // list doesn't re-download and re-decode images it already showed.
  PaintingBinding.instance.imageCache.maximumSize = 2000;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 128 * 1024 * 1024;
  // Install the proxy-aware HttpOverrides and load persisted proxy settings
  // BEFORE anything can issue a network request (controllers start fetching
  // as soon as the widget tree builds).
  HttpOverrides.global = ProxyHttpOverrides();
  final proxyController = ProxyController();
  await proxyController.load();
  final userAgentController = UserAgentController();
  await userAgentController.load();
  MediaKit.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      title: 'Light IPTV Player',
      // Sized so the video pane (window minus the fixed 440px side columns and
      // the top/transport chrome) sits at exactly 16:9, so a 16:9 stream fills
      // it with no letterboxing. Derived from layout constants — see
      // constants.dart. Because the transport info line is always reserved, the
      // pane keeps this ratio before and after playback starts.
      size: Size(defaultWindowWidth, defaultWindowHeight),
      minimumSize: Size(minWindowWidth, minWindowHeight),
      center: true,
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
  runApp(
    IptvApp(
      proxyController: proxyController,
      userAgentController: userAgentController,
    ),
  );
}

void _filterNoisyDebugLogs() {
  final originalDebugPrint = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message == null) return;
    final noisy =
        message.startsWith('VideoOutput.Resize') ||
        message.startsWith('{handle:') ||
        message.startsWith('NativeVideoController: Texture ID:');
    if (noisy) return;
    originalDebugPrint(message, wrapWidth: wrapWidth);
  };
}

class IptvApp extends StatelessWidget {
  const IptvApp({
    super.key,
    required this.proxyController,
    required this.userAgentController,
  });

  final ProxyController proxyController;
  final UserAgentController userAgentController;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: proxyController),
        ChangeNotifierProvider.value(value: userAgentController),
        ChangeNotifierProvider(create: (_) => SourcesController()..load()),
        ChangeNotifierProvider(create: (_) => PlaybackController()),
        ChangeNotifierProvider(create: (_) => EpgController()..restore()),
        ChangeNotifierProvider(
          create: (_) => UpdateController()..checkForUpdate(),
        ),
        ChangeNotifierProxyProvider<SourcesController, UiController>(
          create: (context) =>
              UiController(sources: context.read<SourcesController>()),
          update: (context, sources, previous) =>
              previous ?? UiController(sources: sources),
        ),
      ],
      child: MaterialApp(
        title: 'Light IPTV Player',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: AppColors.accent,
            brightness: Brightness.light,
            primary: AppColors.accent,
            surface: AppColors.surface,
          ),
          scaffoldBackgroundColor: AppColors.bg,
          canvasColor: AppColors.surface,
          fontFamily: 'Segoe UI',
          useMaterial3: true,
          dividerColor: AppColors.border,
          textSelectionTheme: const TextSelectionThemeData(
            cursorColor: AppColors.accent,
            selectionColor: Color(0x333b6ef5),
            selectionHandleColor: AppColors.accent,
          ),
          snackBarTheme: const SnackBarThemeData(
            backgroundColor: AppColors.textPrimary,
            contentTextStyle: TextStyle(color: Colors.white),
            behavior: SnackBarBehavior.floating,
          ),
          dialogTheme: const DialogThemeData(
            backgroundColor: AppColors.surface,
            surfaceTintColor: Colors.transparent,
          ),
        ),
        builder: (context, child) =>
            ExcludeSemantics(child: child ?? const SizedBox.shrink()),
        home: const IptvHome(),
      ),
    );
  }
}

class IptvHome extends StatefulWidget {
  const IptvHome({super.key});

  @override
  State<IptvHome> createState() => _IptvHomeState();
}

class _IptvHomeState extends State<IptvHome> {
  final List<StreamSubscription<String>> _messageSubs = [];
  bool _wired = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_wired) return;
    _wired = true;
    // Bridge controller message streams to SnackBars now that we have a
    // Scaffold-bearing context.
    void wire(Stream<String> stream) {
      _messageSubs.add(stream.listen(_showMessage));
    }

    wire(context.read<SourcesController>().messages);
    wire(context.read<PlaybackController>().messages);
    wire(context.read<UpdateController>().messages);
  }

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  void dispose() {
    for (final sub in _messageSubs) {
      sub.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loaded = context.select<SourcesController, bool>((s) => s.loaded);
    if (!loaded) {
      return const Scaffold(
        body: Center(
          child: SizedBox(
            width: 40,
            height: 40,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              valueColor: AlwaysStoppedAnimation<Color>(AppColors.accent),
            ),
          ),
        ),
      );
    }
    final ui = context.watch<UiController>();
    final source = ui.activeSource ?? ui.playerSource;
    if (source == null) {
      return const SourcesPage();
    }
    // Keep the player page mounted underneath so returning to it (or a stream
    // playing while the sources list is shown) preserves the video output.
    return Stack(
      children: [
        PlayerPage(source: source),
        if (ui.activeSource == null) const SourcesPage(),
      ],
    );
  }
}
