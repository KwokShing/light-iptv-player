import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_iptv_player/constants.dart';
import 'package:light_iptv_player/controllers/sources_controller.dart';
import 'package:light_iptv_player/models/playlist.dart';
import 'package:light_iptv_player/services/playlist_parser.dart';
import 'package:light_iptv_player/update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('parsePlaylist', () {
    test('parses groups, logos and KODIPROP DRM hints', () {
      final channels = parsePlaylist('''
#EXTM3U
#EXTINF:-1 tvg-logo="logo.png" group-title="News",News One
https://example.com/news.m3u8
#EXTGRP:Movies
#EXTINF:-1,Movie One
https://example.com/movie.m3u8
#KODIPROP:inputstream.adaptive.manifest_type=mpd
#KODIPROP:inputstream.adaptive.license_type=clearkey
#KODIPROP:inputstream.adaptive.license_key=abc:def
#EXTINF:-1,Protected
https://example.com/drm.mpd
''');

      expect(channels, hasLength(3));
      expect(channels[0].name, 'News One');
      expect(channels[0].group, 'News');
      expect(channels[0].logo, 'logo.png');
      expect(channels[1].group, 'Movies');

      final drm = channels[2];
      expect(drm.manifestType, 'mpd');
      expect(drm.isDash, isTrue);
      expect(drm.licenseType, 'clearkey');
      expect(drm.licenseKey, 'abc:def');
    });

    test('falls back to the url as name and Ungrouped group', () {
      final channels = parsePlaylist('http://example.com/stream.ts\n');
      expect(channels, hasLength(1));
      expect(channels.single.name, 'http://example.com/stream.ts');
      expect(channels.single.group, ungroupedGroup);
    });
  });

  group('decodePlaylistBytes', () {
    test('strips a UTF-8 BOM', () async {
      final bytes = [0xef, 0xbb, 0xbf, ...utf8.encode('#EXTM3U')];
      expect(await decodePlaylistBytes(bytes), '#EXTM3U');
    });

    test('decodes plain UTF-8 with multibyte characters', () async {
      final bytes = utf8.encode('中文频道');
      expect(await decodePlaylistBytes(bytes), '中文频道');
    });
  });

  group('UpdateService.isNewer', () {
    test('detects a higher semantic version', () {
      expect(UpdateService.isNewer('1.2.0', '1.1.9'), isTrue);
      expect(UpdateService.isNewer('v2.0.0', '1.9.9'), isTrue);
    });

    test('rejects equal or older versions', () {
      expect(UpdateService.isNewer('1.0.0', '1.0.0'), isFalse);
      expect(UpdateService.isNewer('1.0.0', '1.0.1'), isFalse);
    });

    test('ignores build/prerelease suffixes on the core version', () {
      expect(UpdateService.isNewer('1.0.0+5', '1.0.0'), isFalse);
      expect(UpdateService.isNewer('1.2.0-beta', '1.1.0'), isTrue);
    });
  });

  group('SourcesController', () {
    setUp(() {
      // In-memory backing store for shared_preferences so persistence works
      // without a platform channel.
      SharedPreferences.setMockInitialValues({});
      // Suppress debugPrint noise from controllers under test.
      debugPrint = (message, {wrapWidth}) {};
    });

    PlaylistSource singleSource(String id, String name) => PlaylistSource(
      id: id,
      name: name,
      kind: SourceKind.single,
      source: 'http://example.com/$id',
      channels: [
        Channel(name: name, url: 'http://example.com/$id', group: 'Quick Test'),
      ],
      cached: true,
    );

    test('load starts empty and marks itself loaded', () async {
      final controller = SourcesController();
      expect(controller.loaded, isFalse);
      await controller.load();
      expect(controller.loaded, isTrue);
      expect(controller.sources, isEmpty);
    });

    test('upsert prepends, persists, and reloads', () async {
      final controller = SourcesController();
      await controller.load();
      await controller.upsert(singleSource('a', 'Alpha'));
      await controller.upsert(singleSource('b', 'Bravo'));

      expect(controller.sources.map((s) => s.id), ['b', 'a']);

      final reloaded = SourcesController();
      await reloaded.load();
      expect(reloaded.sources.map((s) => s.name), ['Bravo', 'Alpha']);
    });

    test('replace updates in place and emits onSourceReplaced', () async {
      final controller = SourcesController();
      await controller.load();
      await controller.upsert(singleSource('a', 'Alpha'));

      final replacedFuture = controller.onSourceReplaced.first;
      await controller.replace(singleSource('a', 'Renamed'));

      expect(controller.sources.single.name, 'Renamed');
      expect((await replacedFuture).name, 'Renamed');
    });

    test('delete removes and emits onSourceRemoved', () async {
      final controller = SourcesController();
      await controller.load();
      await controller.upsert(singleSource('a', 'Alpha'));

      final removedFuture = controller.onSourceRemoved.first;
      await controller.delete(controller.sources.single);

      expect(controller.sources, isEmpty);
      expect(await removedFuture, 'a');
    });

    test('refreshAll with only single channels reports nothing to refresh',
        () async {
      final controller = SourcesController();
      await controller.load();
      await controller.upsert(singleSource('a', 'Alpha'));

      final message = controller.messages.first;
      await controller.refreshAll();
      expect(await message, 'No playlists to refresh');
      expect(controller.refreshingAll, isFalse);
    });
  });
}
