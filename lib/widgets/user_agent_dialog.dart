import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/playback_controller.dart';
import '../controllers/user_agent_controller.dart';
import '../models/user_agent_settings.dart';
import '../theme.dart';

Future<void> showUserAgentDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => const _UserAgentDialog(),
  );
}

class _UserAgentDialog extends StatefulWidget {
  const _UserAgentDialog();

  @override
  State<_UserAgentDialog> createState() => _UserAgentDialogState();
}

class _UserAgentDialogState extends State<_UserAgentDialog> {
  late UserAgentPreset preset;
  late final TextEditingController custom;
  String? error;

  @override
  void initState() {
    super.initState();
    final settings = context.read<UserAgentController>().settings;
    preset = settings.preset;
    custom = TextEditingController(text: settings.customUserAgent);
  }

  @override
  void dispose() {
    custom.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final controller = context.read<UserAgentController>();
    final playback = context.read<PlaybackController>();
    final next = UserAgentSettings(
      preset: preset,
      customUserAgent: custom.text.trim(),
    );

    if (preset == UserAgentPreset.custom && next.effectiveUserAgent == null) {
      setState(() => error = 'Enter a custom User-Agent value');
      return;
    }

    final changed =
        controller.settings.effectiveUserAgent != next.effectiveUserAgent;
    await controller.save(next);
    if (mounted) Navigator.pop(context);

    final playing = playback.nowPlaying;
    if (changed && playing != null) await playback.play(playing);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text(
        'User-Agent Settings',
        style: TextStyle(color: AppColors.textPrimary),
      ),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Choose the identity sent to playlist, EPG and stream servers. '
              'Default keeps each player component’s built-in behavior.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 18),
            DropdownButtonFormField<UserAgentPreset>(
              initialValue: preset,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'User-Agent preset',
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: AppColors.accent),
                ),
              ),
              items: [
                for (final option in UserAgentPreset.values)
                  DropdownMenuItem(value: option, child: Text(option.label)),
              ],
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  preset = value;
                  error = null;
                });
              },
            ),

            if (preset == UserAgentPreset.custom) ...[
              const SizedBox(height: 16),
              TextField(
                controller: custom,
                autofocus: true,
                minLines: 2,
                maxLines: 4,
                style: const TextStyle(color: AppColors.textPrimary),
                decoration: InputDecoration(
                  labelText: 'Custom User-Agent',
                  hintText: 'Enter the complete User-Agent string',
                  errorText: error,
                  alignLabelWithHint: true,
                  focusedBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: AppColors.accent),
                  ),
                  border: const OutlineInputBorder(),
                ),
              ),
            ] else if (preset.userAgent != null) ...[
              const SizedBox(height: 16),
              SelectableText(
                preset.userAgent!,
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _save,
          style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
