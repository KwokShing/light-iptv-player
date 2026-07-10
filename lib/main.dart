import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'controllers/playback_controller.dart';
import 'controllers/sources_controller.dart';
import 'controllers/ui_controller.dart';
import 'controllers/update_controller.dart';
import 'pages/player_page.dart';
import 'pages/sources_page.dart';
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
  MediaKit.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      title: 'Light IPTV Player',
      // Sized so the video pane lands close to 16:9 with the current chrome
      // (64px top bar + 190+250 side columns + ~170px transport bar),
      // minimizing the empty margin around a 16:9 stream.
      size: Size(1446, 832),
      minimumSize: Size(1120, 640),
      center: true,
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
  runApp(const IptvApp());
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
  const IptvApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => SourcesController()..load()),
        ChangeNotifierProvider(create: (_) => PlaybackController()),
        ChangeNotifierProvider(create: (_) => UpdateController()..checkForUpdate()),
        ChangeNotifierProxyProvider<SourcesController, UiController>(
          create: (context) => UiController(
            sources: context.read<SourcesController>(),
          ),
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
