import 'dart:async';

import 'package:flutter/material.dart';

import '../constants.dart';
import '../models/playlist.dart';
import '../theme.dart';
import 'common.dart';
import 'epg_widgets.dart';

/// Left navigation column showing the source name and its group list.
/// Search lives in the app top bar now, so this only holds groups.
class Sidebar extends StatelessWidget {
  const Sidebar({
    super.key,
    required this.source,
    required this.groups,
    required this.activeGroup,
    required this.onGroup,
  });

  final PlaylistSource source;
  final Map<String, int> groups;
  final String activeGroup;
  final ValueChanged<String> onGroup;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.sidebar,
        border: Border(right: BorderSide(color: AppColors.border, width: 1)),
      ),
      padding: const EdgeInsets.fromLTRB(14, 18, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            source.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: AppColors.textPrimary,
            ),
          ),
          Text(
            '${groups.length - 1} groups',
            style: const TextStyle(color: AppColors.textMuted),
          ),
          const SizedBox(height: 14),
          const Divider(height: 1, color: AppColors.border),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: groups.entries.map((entry) {
                final selected = entry.key == activeGroup;
                return _GroupTile(
                  label: entry.key,
                  count: entry.value,
                  selected: selected,
                  onTap: () => onGroup(entry.key),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupTile extends StatelessWidget {
  const _GroupTile({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected ? AppColors.selected : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          hoverColor: AppColors.surfaceMuted,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                      color: selected
                          ? AppColors.accent
                          : AppColors.textSecondary,
                    ),
                  ),
                ),
                Text(
                  '$count',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: selected ? AppColors.accent : AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ChannelList extends StatefulWidget {
  const ChannelList({
    super.key,
    required this.title,
    required this.channels,
    required this.selected,
    required this.scrollController,
    required this.onPlay,
    this.showGroup = false,
    this.epgUrl,
  });

  final String title;
  final List<Channel> channels;
  final Channel? selected;
  final ScrollController scrollController;
  final ValueChanged<Channel> onPlay;
  final bool showGroup;
  final String? epgUrl;

  @override
  State<ChannelList> createState() => _ChannelListState();
}

class _ChannelListState extends State<ChannelList> {
  // Logos are remote images. Loading them for every tile that flies past
  // during a fast scroll spawns a storm of HTTP requests + decodes. So we only
  // load logos once scrolling has settled.
  bool _scrolling = false;
  Timer? _scrollIdleTimer;

  @override
  void dispose() {
    _scrollIdleTimer?.cancel();
    super.dispose();
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification is ScrollEndNotification) {
      _scrollIdleTimer?.cancel();
      _scrollIdleTimer = Timer(const Duration(milliseconds: 120), () {
        if (mounted && _scrolling) setState(() => _scrolling = false);
      });
    } else if (notification is ScrollStartNotification ||
        notification is ScrollUpdateNotification) {
      _scrollIdleTimer?.cancel();
      if (!_scrolling) setState(() => _scrolling = true);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final channels = widget.channels;
    final hasEpg = widget.epgUrl != null && widget.epgUrl!.isNotEmpty;
    final rowHeight = hasEpg ? channelRowHeightWithEpg : channelRowHeight;
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(right: BorderSide(color: AppColors.border, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    color: AppColors.textPrimary,
                  ),
                ),
                Text(
                  '${channels.length} channels',
                  style: const TextStyle(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.border),
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScroll,
              child: ListView.builder(
                controller: widget.scrollController,
                itemCount: channels.length,
                // Fixed row height makes scrollbar dragging O(1) and exact.
                itemExtent: rowHeight,
                itemBuilder: (context, index) {
                  final channel = channels[index];
                  final selectedChannel = widget.selected?.url == channel.url;
                  return _ChannelTile(
                    channel: channel,
                    selected: selectedChannel,
                    loadLogo: !_scrolling,
                    measurePing: !_scrolling,
                    showGroup: widget.showGroup,
                    epgUrl: hasEpg ? widget.epgUrl : null,
                    rowHeight: rowHeight,
                    onTap: () => widget.onPlay(channel),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({
    required this.channel,
    required this.selected,
    required this.loadLogo,
    required this.measurePing,
    required this.onTap,
    required this.rowHeight,
    this.showGroup = false,
    this.epgUrl,
  });

  final Channel channel;
  final bool selected;
  final bool loadLogo;
  final bool measurePing;
  final bool showGroup;
  final String? epgUrl;
  final double rowHeight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // While searching we show the group label instead of EPG (results span
    // groups), so the guide line only appears in the normal browsing view.
    final showEpg = epgUrl != null && !showGroup;
    return Material(
      color: selected ? AppColors.selected : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        hoverColor: AppColors.surfaceMuted,
        child: Container(
          height: rowHeight,
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: AppColors.border, width: 1),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              if (selected)
                Container(
                  width: 3,
                  height: 34,
                  margin: const EdgeInsets.only(right: 9),
                  decoration: BoxDecoration(
                    color: AppColors.accent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ChannelLogo(url: channel.logo, load: loadLogo),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            channel.name,
                            maxLines: (showGroup || showEpg) ? 1 : 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              height: 1.15,
                              color: selected
                                  ? AppColors.accent
                                  : AppColors.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (showGroup) ...[
                      const SizedBox(height: 4),
                      Text(
                        channel.group,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.textMuted),
                      ),
                    ] else if (showEpg)
                      ChannelEpgLine(channel: channel, epgUrl: epgUrl),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ChannelPing(url: channel.url, active: measurePing),
            ],
          ),
        ),
      ),
    );
  }
}
