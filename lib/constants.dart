import 'package:flutter/material.dart';

const sourcesStorageKey = 'light-iptv-player:sources:flutter:v1';
const installedTagStorageKey = 'light-iptv-player:installed-tag:v1';
const allChannels = 'All Channels';
const ungroupedGroup = 'Ungrouped';

/// The git tag this build was released under, injected at build time via
/// `--dart-define=RELEASE_TAG=...`. Empty for local/dev builds.
const releaseTag = String.fromEnvironment('RELEASE_TAG');
const fullscreenAnimationDuration = Duration(milliseconds: 180);
const fullscreenAnimationCurve = Curves.easeOutCubic;

// Fixed height of a channel row, including its bottom divider. Sized to fit the
// 46px logo (plus padding) and, while searching, a single-line name above the
// group label without overflow, with a little slack for larger system text
// scaling.
const channelRowHeight = 70.0;
