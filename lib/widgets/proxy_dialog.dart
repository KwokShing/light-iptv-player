import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../controllers/playback_controller.dart';
import '../controllers/proxy_controller.dart';
import '../models/proxy_settings.dart';
import '../services/proxy_list_service.dart';
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

  // Free-proxy-list fetch state.
  String fetchCountry = ProxyListService.defaultCountry.code;
  bool fetching = false;
  String? fetchError;
  List<FreeProxy> fetchedProxies = const [];
  FreeProxy? selectedProxy;

  @override
  void initState() {
    super.initState();
    final settings = context.read<ProxyController>().settings;
    // Start with the proxy switched off while configuring; it auto-enables
    // once a proxy is picked (or the user flips it on manually).
    enabled = false;
    type = settings.type;
    host = TextEditingController(text: settings.host);
    port = TextEditingController(text: '${settings.port}');
    username = TextEditingController(text: settings.username);
    password = TextEditingController(text: settings.password);

    // Restore the last fetched list so reopening the dialog keeps results
    // until the user fetches again.
    final cache = ProxyListService.lastFetch;
    if (cache != null) {
      fetchCountry = cache.countryCode;
      fetchedProxies = cache.proxies;
      selectedProxy = cache.selected;
    }
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

  Future<void> _fetchProxies() async {
    setState(() {
      fetching = true;
      fetchError = null;
      fetchedProxies = const [];
      selectedProxy = null;
    });
    try {
      final proxies = await ProxyListService.fetchAll(
        countryCode: fetchCountry,
      );
      if (!mounted) return;
      setState(() {
        fetching = false;
        fetchedProxies = proxies;
        if (proxies.isEmpty) {
          fetchError = 'No proxies found for this country';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        fetching = false;
        fetchError = 'Fetch failed: $e';
      });
    }
  }

  void _applyFetched(FreeProxy proxy) {
    setState(() {
      selectedProxy = proxy;
      type = proxy.protocol.proxyType;
      host.text = proxy.host;
      port.text = '${proxy.port}';
      // A freshly picked list proxy is enabled by default for convenience.
      enabled = true;
      testResult = null;
    });
    // Remember the selection so it's highlighted when the dialog reopens.
    ProxyListService.lastFetch?.selected = proxy;
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
    final proxy = context.read<ProxyController>();
    final playback = context.read<PlaybackController>();
    final previous = proxy.settings;
    await proxy.save(next);
    if (mounted) Navigator.pop(context);
    // Reconnect the playing channel when the change affects routing, so the
    // new proxy applies without the user having to reopen the channel.
    final routingChanged =
        previous.active != next.active ||
        (next.active && !previous.sameEndpoint(next));
    final playing = playback.nowPlaying;
    if (routingChanged && playing != null) {
      await playback.play(playing);
    }
  }

  Widget _buildFetchSection() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceMuted,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Get a free proxy',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 13.5,
            ),
          ),
          const SizedBox(height: 2),
          const Text(
            'Fetch public strict-SSL, elite-anonymity proxies by country with '
            'reported latency and protocol. Pick one below to auto-fill and '
            'enable it.',
            style: TextStyle(color: AppColors.textMuted, fontSize: 11.5),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: fetchCountry,
                  isDense: true,
                  isExpanded: true,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                  ),
                  decoration: _decoration('Country'),
                  items: [
                    for (final c in ProxyListService.countries)
                      DropdownMenuItem(value: c.code, child: Text(c.label)),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      fetchCountry = value;
                      fetchedProxies = const [];
                      selectedProxy = null;
                      fetchError = null;
                    });
                  },
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: fetching ? null : _fetchProxies,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                ),
                icon: fetching
                    ? const SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.white,
                          ),
                        ),
                      )
                    : const Icon(Icons.cloud_download_rounded, size: 17),
                label: const Text('Fetch'),
              ),
            ],
          ),
          if (fetchedProxies.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              'Pick a proxy (${fetchedProxies.length} found, sorted by latency)',
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              constraints: const BoxConstraints(maxHeight: 168),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppColors.border),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: fetchedProxies.length,
                itemBuilder: (context, index) {
                  final proxy = fetchedProxies[index];
                  return _proxyRow(proxy);
                },
              ),
            ),
          ],
          if (fetchError != null) ...[
            const SizedBox(height: 8),
            Text(
              fetchError!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.danger, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _proxyRow(FreeProxy proxy) {
    final selected = selectedProxy == proxy;
    return InkWell(
      onTap: () => _applyFetched(proxy),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        color: selected ? AppColors.accentSoft : Colors.transparent,
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: 16,
              color: selected ? AppColors.accent : AppColors.textMuted,
            ),
            const SizedBox(width: 8),
            _protocolBadge(proxy.protocol),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                proxy.hostPort,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                ),
              ),
            ),
            const SizedBox(width: 8),
            _latencyBadge(proxy.latencyMs),
          ],
        ),
      ),
    );
  }

  Widget _protocolBadge(FreeProxyProtocol protocol) {
    final color = switch (protocol) {
      FreeProxyProtocol.http => AppColors.accent,
      FreeProxyProtocol.socks5 => const Color(0xff7b5cf0),
    };
    return Container(
      width: 58,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        protocol.label,
        style: TextStyle(
          color: color,
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _latencyBadge(int? ms) {
    if (ms == null) {
      return const Text(
        'unknown',
        style: TextStyle(color: AppColors.textMuted, fontSize: 11.5),
      );
    }
    final color = ms < 300
        ? AppColors.good
        : (ms < 800 ? const Color(0xffd08700) : AppColors.danger);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '${ms}ms',
        style: TextStyle(
          color: color,
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
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
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 440,
          maxHeight: MediaQuery.of(context).size.height * 0.82,
        ),
        child: SizedBox(
          width: 440,
          child: SingleChildScrollView(
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
            const SizedBox(height: 12),
            _buildFetchSection(),
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
