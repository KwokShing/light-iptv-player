import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../controllers/proxy_controller.dart';
import '../models/proxy_settings.dart';
import '../services/proxy_service.dart';
import '../theme.dart';

/// Proxy settings dialog: enable switch, host/port, optional credentials and
/// a connection test. Saving applies immediately to all HTTP requests and to
/// the next stream mpv opens.
Future<void> showProxyDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => const _ProxyDialog(),
  );
}

class _ProxyDialog extends StatefulWidget {
  const _ProxyDialog();

  @override
  State<_ProxyDialog> createState() => _ProxyDialogState();
}

class _ProxyDialogState extends State<_ProxyDialog> {
  late bool enabled;
  late ProxyType type;
  late final TextEditingController host;
  late final TextEditingController port;
  late final TextEditingController username;
  late final TextEditingController password;

  bool testing = false;
  bool obscurePassword = true;
  String? testResult;
  bool testOk = false;

  @override
  void initState() {
    super.initState();
    final settings = context.read<ProxyController>().settings;
    enabled = settings.enabled;
    type = settings.type;
    host = TextEditingController(text: settings.host);
    port = TextEditingController(text: '${settings.port}');
    username = TextEditingController(text: settings.username);
    password = TextEditingController(text: settings.password);
  }

  @override
  void dispose() {
    host.dispose();
    port.dispose();
    username.dispose();
    password.dispose();
    super.dispose();
  }

  ProxySettings _collect() {
    return ProxySettings(
      enabled: enabled,
      type: type,
      host: host.text.trim(),
      port: int.tryParse(port.text.trim()) ?? 0,
      username: username.text,
      password: password.text,
    );
  }

  Future<void> _test() async {
    setState(() {
      testing = true;
      testResult = null;
    });
    final error = await ProxyService.testConnection(_collect());
    if (!mounted) return;
    setState(() {
      testing = false;
      testOk = error == null;
      testResult = error ?? 'Proxy is reachable';
    });
  }

  Future<void> _save() async {
    final next = _collect();
    if (next.enabled && !next.isConfigured) {
      setState(() {
        testOk = false;
        testResult = 'Enter a valid host and port (1-65535)';
      });
      return;
    }
    await context.read<ProxyController>().save(next);
    if (mounted) Navigator.pop(context);
  }

  InputDecoration _decoration(String label, {Widget? suffixIcon}) {
    return InputDecoration(
      labelText: label,
      suffixIcon: suffixIcon,
      focusedBorder: const UnderlineInputBorder(
        borderSide: BorderSide(color: AppColors.accent),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text(
        'Proxy Settings',
        style: TextStyle(color: AppColors.textPrimary),
      ),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Route playlist downloads and streams through an HTTP or '
              'SOCKS5 proxy to watch region-restricted channels.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              activeThumbColor: AppColors.accent,
              title: const Text(
                'Use proxy',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              value: enabled,
              onChanged: (value) => setState(() => enabled = value),
            ),
            const SizedBox(height: 4),
            SegmentedButton<ProxyType>(
              showSelectedIcon: false,
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                foregroundColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.selected)
                      ? Colors.white
                      : AppColors.textSecondary,
                ),
                backgroundColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.selected)
                      ? AppColors.accent
                      : AppColors.surface,
                ),
                side: const WidgetStatePropertyAll(
                  BorderSide(color: AppColors.border),
                ),
              ),
              segments: const [
                ButtonSegment(value: ProxyType.http, label: Text('HTTP')),
                ButtonSegment(value: ProxyType.socks5, label: Text('SOCKS5')),
              ],
              selected: {type},
              onSelectionChanged: (selection) => setState(() {
                type = selection.first;
                testResult = null;
              }),
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: host,
                    style: const TextStyle(color: AppColors.textPrimary),
                    decoration: _decoration('Host (e.g. 127.0.0.1)'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: port,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style: const TextStyle(color: AppColors.textPrimary),
                    decoration: _decoration('Port'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: username,
                    style: const TextStyle(color: AppColors.textPrimary),
                    decoration: _decoration('Username (optional)'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: password,
                    obscureText: obscurePassword,
                    style: const TextStyle(color: AppColors.textPrimary),
                    decoration: _decoration(
                      'Password',
                      suffixIcon: IconButton(
                        icon: Icon(
                          obscurePassword
                              ? Icons.visibility_off_rounded
                              : Icons.visibility_rounded,
                          size: 18,
                          color: AppColors.textMuted,
                        ),
                        onPressed: () => setState(
                          () => obscurePassword = !obscurePassword,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                TextButton.icon(
                  onPressed: testing ? null : _test,
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.accent,
                  ),
                  icon: testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              AppColors.accent,
                            ),
                          ),
                        )
                      : const Icon(Icons.wifi_tethering_rounded, size: 18),
                  label: const Text('Test connection'),
                ),
                const SizedBox(width: 8),
                if (testResult != null)
                  Expanded(
                    child: Text(
                      testResult!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: testOk ? AppColors.good : AppColors.danger,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Applies to playlist downloads immediately; streams use the '
              'proxy from the next channel you open.',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          style: TextButton.styleFrom(foregroundColor: AppColors.textSecondary),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
