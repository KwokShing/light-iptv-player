import 'package:flutter/material.dart';

import '../theme.dart';
import 'common.dart';

/// A slim app-wide top bar: brand on the left, optional centered search box,
/// and optional trailing actions on the right. Shared by the sources page and
/// the player page so the two screens feel like one app.
class TopBar extends StatelessWidget {
  const TopBar({
    super.key,
    required this.title,
    this.subtitle,
    this.search,
    this.trailing = const [],
  });

  final String title;
  final String? subtitle;

  /// When provided, a search field is shown in the center of the bar.
  final TopBarSearch? search;

  /// Widgets rendered on the right edge of the bar.
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(
          bottom: BorderSide(color: AppColors.border, width: 1),
        ),
      ),
      child: Row(
        children: [
          const AppLogo(size: 38),
          const SizedBox(width: 12),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
              if (subtitle != null && subtitle!.isNotEmpty)
                Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textMuted,
                  ),
                ),
            ],
          ),
          const SizedBox(width: 24),
          if (search != null)
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: _SearchField(search: search!),
                ),
              ),
            )
          else
            const Spacer(),
          const SizedBox(width: 12),
          ...trailing,
        ],
      ),
    );
  }
}

/// Search wiring passed to [TopBar].
class TopBarSearch {
  const TopBarSearch({
    required this.controller,
    required this.onChanged,
    this.hint = 'Search',
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String hint;
}

class _SearchField extends StatefulWidget {
  const _SearchField({required this.search});
  final TopBarSearch search;

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  @override
  Widget build(BuildContext context) {
    final search = widget.search;
    return TextField(
      controller: search.controller,
      style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
      onChanged: (value) {
        search.onChanged(value);
        setState(() {});
      },
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: AppColors.surfaceMuted,
        hintText: search.hint,
        hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 14),
        prefixIcon: const Icon(
          Icons.search_rounded,
          size: 20,
          color: AppColors.textMuted,
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 10),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.accent),
        ),
        suffixIcon: search.controller.text.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.clear, size: 18),
                color: AppColors.textMuted,
                tooltip: 'Clear search',
                onPressed: () {
                  search.controller.clear();
                  search.onChanged('');
                  setState(() {});
                },
              ),
      ),
    );
  }
}

/// A compact bordered pill button used in the top bar / headers.
class TopBarButton extends StatelessWidget {
  const TopBarButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final bg = primary ? AppColors.accent : AppColors.surface;
    final fg = primary
        ? Colors.white
        : (enabled ? AppColors.textPrimary : AppColors.textMuted);
    final iconColor = primary
        ? Colors.white
        : (enabled ? AppColors.accent : AppColors.textMuted);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(10),
        hoverColor: primary ? Colors.white24 : AppColors.surfaceMuted,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: primary ? AppColors.accent : AppColors.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: Center(
                  child: busy
                      ? SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(iconColor),
                          ),
                        )
                      : Icon(icon, size: 18, color: iconColor),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                label,
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
    );
  }
}
