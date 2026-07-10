import 'package:flutter/material.dart';

import '../constants.dart';
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
    this.onLogoTap,
    this.leading,
    this.searchLeftInset,
    this.showLogo = true,
  });

  final String title;
  final String? subtitle;

  /// When provided, a search field is shown in the center of the bar.
  final TopBarSearch? search;

  /// Widgets rendered on the right edge of the bar.
  final List<Widget> trailing;

  /// When provided, tapping the brand (logo + title) invokes this — e.g. to
  /// return to the sources/home page from the player.
  final VoidCallback? onLogoTap;

  /// Optional widget shown immediately to the right of the brand (before the
  /// search field), e.g. a home/back icon button.
  final Widget? leading;

  /// When set, the search field is left-aligned so its left edge sits this
  /// many pixels from the bar's left content edge (used to line the search box
  /// up with the video pane on the player page). When null, search is centered.
  final double? searchLeftInset;

  /// Whether to show the IPTV logo tile in the brand block.
  final bool showLogo;

  @override
  Widget build(BuildContext context) {
    final brand = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Brand(
          title: title,
          subtitle: subtitle,
          onTap: onLogoTap,
          showLogo: showLogo,
        ),
        if (leading != null) ...[const SizedBox(width: 12), leading!],
      ],
    );

    final Widget content;
    if (search != null && searchLeftInset != null) {
      // Left-align the search field to a fixed inset so it lines up with the
      // video pane. Brand sits on the left, trailing on the right; both float
      // above so a wide search box can't push them around.
      content = Stack(
        children: [
          Align(alignment: Alignment.centerLeft, child: brand),
          Positioned(
            left: searchLeftInset! - topBarHorizontalPadding,
            top: 0,
            bottom: 0,
            child: Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: _SearchField(search: search!),
              ),
            ),
          ),
          if (trailing.isNotEmpty)
            Align(
              alignment: Alignment.centerRight,
              child: Row(mainAxisSize: MainAxisSize.min, children: trailing),
            ),
        ],
      );
    } else {
      content = Row(
        children: [
          brand,
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
      );
    }

    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: topBarHorizontalPadding),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border, width: 1)),
      ),
      child: content,
    );
  }
}

/// Brand block (logo + title/subtitle). Becomes a tappable, tooltip-bearing
/// button when [onTap] is provided (used to go home from the player).
class _Brand extends StatelessWidget {
  const _Brand({
    required this.title,
    this.subtitle,
    this.onTap,
    this.showLogo = true,
  });

  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final bool showLogo;

  @override
  Widget build(BuildContext context) {
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showLogo) ...[
          const AppLogo(size: 38),
          if (title.isNotEmpty) const SizedBox(width: 12),
        ],
        if (title.isNotEmpty)
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
      ],
    );

    if (onTap == null) return content;

    return Tooltip(
      message: 'Back to sources',
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          hoverColor: AppColors.surfaceMuted,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: content,
          ),
        ),
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
                            valueColor: AlwaysStoppedAnimation<Color>(
                              iconColor,
                            ),
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

/// A square, bordered icon-only button for the top bar (e.g. the home button
/// placed next to the brand).
class TopBarIconButton extends StatelessWidget {
  const TopBarIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(10),
          hoverColor: AppColors.surfaceMuted,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border),
            ),
            child: Icon(
              icon,
              size: 20,
              color: enabled ? AppColors.accent : AppColors.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}
