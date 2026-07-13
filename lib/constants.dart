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

// Height reserved for the transport bar's info line (channel name + inline EPG
// + stream URL). It is always reserved — even before playback starts — so the
// bottom bar (and therefore the video pane's height) does not change when a
// channel begins playing. Keeping this stable lets the default window size be
// tuned so a 16:9 stream fills the pane with no letterboxing.
const transportInfoLineHeight = 18.0;

// --- Default window geometry -------------------------------------------------
//
// The video pane is `Expanded` in the player page, so its width is
// `windowWidth - sideColumnsWidth` and its height is
// `clientHeight - topBar - transportBar`. We size the default window so that
// pane sits at exactly 16:9, filling a 16:9 stream with no letterboxing on any
// side. Because the transport bar's info line is now always reserved, this
// geometry holds both before and after playback starts.

// Fixed top bar height (see [TopBar]).
const _topBarHeight = 64.0;

// Total height of the transport control card (see [PlaybackControls]):
//   margin-top 8 + vertical padding (6+6) + info line + control row.
// The control row's tallest element is the 40px primary button inside 4px
// padding on each side (48px), per [TransportButton].
const _transportBarHeight = 8.0 + 12.0 + transportInfoLineHeight + 48.0;

// Windows counts the OS title bar + frame as part of the window `size`, so the
// Flutter client area is shorter than the window by roughly this much.
const _windowChromeHeight = 32.0;

// Chosen video pane width; the rest of the geometry follows from 16:9.
const _defaultPaneWidth = 1040.0;
const _defaultPaneHeight = _defaultPaneWidth * 9.0 / 16.0;

const defaultWindowWidth = _defaultPaneWidth + sideColumnsWidth;
const defaultWindowHeight =
    _defaultPaneHeight + _topBarHeight + _transportBarHeight + _windowChromeHeight;

// Minimum keeps a usable pane while still respecting the fixed side columns.
const minWindowWidth = 720.0 + sideColumnsWidth;
const minWindowHeight = 405.0 +
    _topBarHeight +
    _transportBarHeight +
    _windowChromeHeight;

// Horizontal padding inside the top bar. Matches the sidebar's left padding so
// the top bar's leading control (home button) lines up with the sidebar's left
// content edge.
const topBarHorizontalPadding = 14.0;
