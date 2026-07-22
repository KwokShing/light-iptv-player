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
  late List<SavedUserAgent> savedAgents;
  String? selectedAgentId;
  String? error;

  @override
  void initState() {
    super.initState();
    final settings = context.read<UserAgentController>().settings;
    preset = settings.preset;
    savedAgents = List<SavedUserAgent>.from(settings.savedAgents);
    selectedAgentId = settings.selectedAgentId;
    // Migrate a legacy single custom UA into the saved list on first open.
    if (savedAgents.isEmpty && settings.customUserAgent.trim().isNotEmpty) {
      final migrated = SavedUserAgent(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: 'ua1',
        value: settings.customUserAgent.trim(),
      );
      savedAgents = [migrated];
      if (preset == UserAgentPreset.custom) selectedAgentId = migrated.id;
    }
  }

  String _nextName() {
    var i = 1;
    while (savedAgents.any((a) => a.name == 'ua$i')) {
      i++;
    }
    return 'ua$i';
  }

  Future<void> _addAgent() async {
    final result = await _showEditAgentDialog(name: _nextName());
    if (result == null) return;
    setState(() {
      savedAgents = [...savedAgents, result];
      selectedAgentId = result.id;
      preset = UserAgentPreset.custom;
      error = null;
    });
  }

  Future<void> _editAgent(SavedUserAgent agent) async {
    final result = await _showEditAgentDialog(
      id: agent.id,
      name: agent.name,
      value: agent.value,
    );
    if (result == null) return;
    setState(() {
      savedAgents = [
        for (final a in savedAgents) if (a.id == agent.id) result else a,
      ];
      error = null;
    });
  }

  void _deleteAgent(SavedUserAgent agent) {
    setState(() {
      savedAgents = [for (final a in savedAgents) if (a.id != agent.id) a];
      if (selectedAgentId == agent.id) selectedAgentId = null;
    });
  }

  Future<SavedUserAgent?> _showEditAgentDialog({
    String? id,
    String name = '',
    String value = '',
  }) {
    return showDialog<SavedUserAgent>(
      context: context,
      builder: (context) => _EditAgentDialog(
        id: id,
        initialName: name,
        initialValue: value,
      ),
    );
  }

  Future<void> _save() async {
    final controller = context.read<UserAgentController>();
    final playback = context.read<PlaybackController>();

    if (preset == UserAgentPreset.custom &&
        (selectedAgentId == null ||
            !savedAgents.any((a) => a.id == selectedAgentId))) {
      setState(() => error = 'Select or add a custom User-Agent');
      return;
    }

    final next = UserAgentSettings(
      preset: preset,
      savedAgents: savedAgents,
      selectedAgentId: preset == UserAgentPreset.custom ? selectedAgentId : null,
    );

    if (preset == UserAgentPreset.custom && next.effectiveUserAgent == null) {
      setState(() => error = 'The selected User-Agent is empty');
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
              _buildCustomSection(),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(
                  error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ],
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

  Widget _buildCustomSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Saved User-Agents',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            TextButton.icon(
              onPressed: _addAgent,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add'),
              style: TextButton.styleFrom(foregroundColor: AppColors.accent),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (savedAgents.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'No saved User-Agents yet. Tap “Add” to create one.',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: SingleChildScrollView(
              child: Column(
                children: [
                  for (final agent in savedAgents) _buildAgentTile(agent),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildAgentTile(SavedUserAgent agent) {
    final selected = agent.id == selectedAgentId;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        border: Border.all(
          color: selected ? AppColors.accent : AppColors.textMuted.withValues(alpha: 0.3),
          width: selected ? 1.5 : 1,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: RadioListTile<String>(
        value: agent.id,
        // ignore: deprecated_member_use
        groupValue: selectedAgentId,
        // ignore: deprecated_member_use
        onChanged: (value) => setState(() {
          selectedAgentId = value;
          error = null;
        }),
        activeColor: AppColors.accent,
        dense: true,
        contentPadding: const EdgeInsets.only(left: 8, right: 4),
        title: Text(
          agent.name.isEmpty ? '(unnamed)' : agent.name,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          agent.value,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
        ),
        secondary: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.edit_rounded, size: 18),
              color: AppColors.textSecondary,
              tooltip: 'Edit',
              onPressed: () => _editAgent(agent),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              color: AppColors.textSecondary,
              tooltip: 'Delete',
              onPressed: () => _deleteAgent(agent),
            ),
          ],
        ),
      ),
    );
  }
}

class _EditAgentDialog extends StatefulWidget {
  const _EditAgentDialog({
    this.id,
    required this.initialName,
    required this.initialValue,
  });

  final String? id;
  final String initialName;
  final String initialValue;

  @override
  State<_EditAgentDialog> createState() => _EditAgentDialogState();
}

class _EditAgentDialogState extends State<_EditAgentDialog> {
  late final TextEditingController name;
  late final TextEditingController value;
  String? valueError;

  @override
  void initState() {
    super.initState();
    name = TextEditingController(text: widget.initialName);
    value = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    name.dispose();
    value.dispose();
    super.dispose();
  }

  void _submit() {
    final trimmedValue = value.text.trim();
    if (trimmedValue.isEmpty) {
      setState(() => valueError = 'Enter a User-Agent value');
      return;
    }
    final trimmedName = name.text.trim();
    Navigator.pop(
      context,
      SavedUserAgent(
        id: widget.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
        name: trimmedName.isEmpty ? 'ua' : trimmedName,
        value: trimmedValue,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.id == null ? 'Add User-Agent' : 'Edit User-Agent',
        style: const TextStyle(color: AppColors.textPrimary),
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'e.g. ua1',
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: AppColors.accent),
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: value,
              minLines: 2,
              maxLines: 4,
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: InputDecoration(
                labelText: 'User-Agent',
                hintText: 'Enter the complete User-Agent string',
                errorText: valueError,
                alignLabelWithHint: true,
                focusedBorder: const OutlineInputBorder(
                  borderSide: BorderSide(color: AppColors.accent),
                ),
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) {
                if (valueError != null) setState(() => valueError = null);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
          child: const Text('OK'),
        ),
      ],
    );
  }
}
