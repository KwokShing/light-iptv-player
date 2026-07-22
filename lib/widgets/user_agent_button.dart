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
    return TopBarButton(
      icon: Icons.language_rounded,
      label: 'UA: ${settings.preset.label}',
      onPressed: () => showUserAgentDialog(context),
    );
  }
}
