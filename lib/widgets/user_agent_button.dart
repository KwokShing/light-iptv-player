import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/user_agent_controller.dart';
import 'top_bar.dart';
import 'user_agent_dialog.dart';

class UserAgentButton extends StatelessWidget {
  const UserAgentButton({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<UserAgentController>().settings;
    final selected = settings.selectedAgent;
    final label = selected != null && settings.preset.name == 'custom'
        ? selected.name
        : settings.preset.label;
    return TopBarButton(
      icon: Icons.language_rounded,
      label: 'UA: $label',
      onPressed: () => showUserAgentDialog(context),
    );
  }
}
