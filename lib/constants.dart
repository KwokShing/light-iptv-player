import 'package:flutter/material.dart';

const sourcesStorageKey = 'light-iptv-player:sources:flutter:v1';
const installedTagStorageKey = 'light-iptv-player:installed-tag:v1';
const proxyStorageKey = 'light-iptv-player:proxy:v1';
const epgStorageKey = 'light-iptv-player:epg:v1';
const allChannels = 'All Channels';
const ungroupedGroup = 'Ungrouped';

/// How long a downloaded EPG guide is considered fresh before an automatic
/// re-fetch is allowed. Guides typically span a few days, so refreshing a few
/// times a day keeps now/next accurate without hammering the origin.
const epgRefreshInterval = Duration(hours: 6);

/// The git tag this build was released under, injected at build time via
/// `--dart-define=RELEASE_TAG=...`. Empty for local/dev builds.
const releaseTag = String.fromEnvironment('RELEASE_TAG');
const fullscreenAnimationDuration = Duration(milliseconds: 180);
const fullscreenAnimationCurve = Curves.easeOutCubic;

// Fixed height of a channel row, including its bottom divider. Sized to fit the
// 46px logo (plus padding) and, while searching, a single-line name above the
// group label without overflow, with a little slack for larger system text
// scaling. When EPG is available the tile also shows a "now" line + progress
// bar; the taller variant below is used then.
const channelRowHeight = 70.0;
const channelRowHeightWithEpg = 84.0;

// Widths of the two left columns on the player page. The video pane starts at
// their sum, so the top bar aligns its search field to that edge.
const sidebarWidth = 190.0;
const channelListWidth = 250.0;
const sideColumnsWidth = sidebarWidth + channelListWidth;

// Horizontal padding inside the top bar. Matches the sidebar's left padding so
// the top bar's leading control (home button) lines up with the sidebar's left
// content edge.
const topBarHorizontalPadding = 14.0;
