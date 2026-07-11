import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/playback_controller.dart';
import '../controllers/proxy_controller.dart';
import '../theme.dart';
import 'proxy_dialog.dart';

/// Split proxy button for the top bar: the main area toggles the proxy with a
/// single click (opening settings instead when nothing is configured yet),
/// and the gear on the right always opens the settings dialog. Shown on both
/// the sources page and the player page so the proxy can be flipped without
/// leaving the current screen.
///
/// Toggling while a channel is playing reconnects it so the change takes
/// effect immediately.
class ProxyButton extends StatelessWidget {
  const ProxyButton({super.key});

  Future<void> _toggle(BuildContext context) async {
    final proxy = context.read<ProxyController>();
    final playback = context.read<PlaybackController>();
    final settings = proxy.settings;
    if (!settings.isConfigured) {
      await showProxyDialog(context);
      return;
    }
    await proxy.save(settings.copyWith(enabled: !settings.enabled));
    final playing = playback.nowPlaying;
    if (playing != null) await playback.play(playing);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<ProxyController>().settings;
    final active = settings.active;
    final fg = active ? Colors.white : AppColors.textPrimary;
    final iconColor = active ? Colors.white : AppColors.textMuted;

    return Container(
      decoration: BoxDecoration(
        color: active ? AppColors.accent : AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: active ? AppColors.accent : AppColors.border,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: settings.isConfigured
                  ? (active ? 'Turn proxy off' : 'Turn proxy on')
                  : 'Set up a proxy',
              child: InkWell(
                onTap: () => _toggle(context),
                borderRadius: const BorderRadius.horizontal(
                  left: Radius.circular(10),
                ),
                hoverColor: active ? Colors.white24 : AppColors.surfaceMuted,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        active
                            ? Icons.vpn_lock_rounded
                            : Icons.public_rounded,
                        size: 18,
                        color: iconColor,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        active ? 'Proxy On' : 'Proxy Off',
                        style: TextStyle(
                          color: fg,
                          fontWeight: FontWeight.w600,
                          fontSize: 13.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(
              height: 22,
              child: VerticalDivider(
                width: 1,
                thickness: 1,
                color: active ? Colors.white38 : AppColors.border,
              ),
            ),
            Tooltip(
              message: 'Proxy settings',
              child: InkWell(
                onTap: () => showProxyDialog(context),
                borderRadius: const BorderRadius.horizontal(
                  right: Radius.circular(10),
                ),
                hoverColor: active ? Colors.white24 : AppColors.surfaceMuted,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 9,
                  ),
                  child: Icon(
                    Icons.settings_rounded,
                    size: 18,
                    color: iconColor,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
