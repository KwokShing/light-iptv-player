import 'dart:async';

import 'package:flutter/material.dart';

import '../constants.dart';
import '../models/playlist.dart';
import 'common.dart';

class Sidebar extends StatefulWidget {
  const Sidebar({
    super.key,
    required this.source,
    required this.groups,
    required this.activeGroup,
    required this.onBack,
    required this.onSearch,
    required this.onGroup,
  });

  final PlaylistSource source;
  final Map<String, int> groups;
  final String activeGroup;
  final VoidCallback onBack;
  final ValueChanged<String> onSearch;
  final ValueChanged<String> onGroup;

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void didUpdateWidget(Sidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source.id != widget.source.id &&
        _searchController.text.isNotEmpty) {
      _searchController.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onSearch('');
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xffeef1f6),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: widget.onBack,
              child: const Align(
                alignment: Alignment.centerLeft,
                child: Text('← Sources'),
              ),
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _searchController,
            onChanged: (value) {
              widget.onSearch(value);
              setState(() {});
            },
            decoration: InputDecoration(
              filled: true,
              fillColor: Colors.white,
              hintText: 'Search channels',
              border: const OutlineInputBorder(),
              suffixIcon: _searchController.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      tooltip: 'Clear search',
                      onPressed: () {
                        _searchController.clear();
                        widget.onSearch('');
                        setState(() {});
                      },
                    ),
            ),
          ),
          const SizedBox(height: 18),
          const Divider(),
          Text(
            widget.source.name,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
          ),
          Text(
            '${widget.groups.length - 1} groups',
            style: const TextStyle(color: Color(0xff7d8490)),
          ),
          const SizedBox(height: 18),
          Expanded(
            child: ListView(
              children: widget.groups.entries.map((entry) {
                final selected = entry.key == widget.activeGroup;
                return _GroupTile(
                  label: entry.key,
                  count: entry.value,
                  selected: selected,
                  onTap: () => widget.onGroup(entry.key),
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
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: selected ? const Color(0xffeee6ff) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontWeight: selected ? FontWeight.w900 : FontWeight.w500,
                      color: selected ? const Color(0xff8357f7) : null,
                    ),
                  ),
                ),
                Text(
                  '$count',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    color: Color(0xff6f7681),
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
  });

  final String title;
  final List<Channel> channels;
  final Channel? selected;
  final ScrollController scrollController;
  final ValueChanged<Channel> onPlay;
  final bool showGroup;

  @override
  State<ChannelList> createState() => _ChannelListState();
}

class _ChannelListState extends State<ChannelList> {
  // Names that appear on more than one channel get a "routes" tag. Computed
  // once whenever the channel list changes instead of rescanning inside every
  // visible tile (which made large playlists freeze while scrolling).
  late Set<String> _duplicateNames;

  // Logos are remote images. Loading them for every tile that flies past
  // during a fast scroll spawns a storm of HTTP requests + decodes. So we only
  // load logos once scrolling has settled.
  bool _scrolling = false;
  Timer? _scrollIdleTimer;

  @override
  void initState() {
    super.initState();
    _computeDuplicateNames();
  }

  @override
  void didUpdateWidget(ChannelList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.channels, widget.channels)) {
      _computeDuplicateNames();
    }
  }

  @override
  void dispose() {
    _scrollIdleTimer?.cancel();
    super.dispose();
  }

  void _computeDuplicateNames() {
    final seen = <String>{};
    final duplicates = <String>{};
    for (final channel in widget.channels) {
      if (!seen.add(channel.name)) {
        duplicates.add(channel.name);
      }
    }
    _duplicateNames = duplicates;
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
    return Container(
      color: const Color(0xfff4efff),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(
                  '${channels.length} channels',
                  style: const TextStyle(color: Color(0xff7d8490)),
                ),
              ],
            ),
          ),
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScroll,
              child: ListView.builder(
                controller: widget.scrollController,
                itemCount: channels.length,
                // Fixed row height makes scrollbar dragging O(1) and exact.
                itemExtent: channelRowHeight,
                itemBuilder: (context, index) {
                  final channel = channels[index];
                  final selectedChannel = widget.selected?.url == channel.url;
                  return _ChannelTile(
                    channel: channel,
                    selected: selectedChannel,
                    hasRoutes: _duplicateNames.contains(channel.name),
                    loadLogo: !_scrolling,
                    measurePing: !_scrolling,
                    showGroup: widget.showGroup,
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
    required this.hasRoutes,
    required this.loadLogo,
    required this.measurePing,
    required this.onTap,
    this.showGroup = false,
  });

  final Channel channel;
  final bool selected;
  final bool hasRoutes;
  final bool loadLogo;
  final bool measurePing;
  final bool showGroup;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? const Color(0xffeee6ff) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: channelRowHeight,
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Color(0x1f000000), width: 1),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
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
                            maxLines: showGroup ? 1 : 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              height: 1.15,
                            ),
                          ),
                        ),
                        if (hasRoutes) ...const [
                          SizedBox(width: 8),
                          Tag(label: 'routes'),
                        ],
                      ],
                    ),
                    if (showGroup) ...[
                      const SizedBox(height: 4),
                      Text(
                        channel.group,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Color(0xff7d8490)),
                      ),
                    ],
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
