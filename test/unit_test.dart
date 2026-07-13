import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_iptv_player/constants.dart';
import 'package:light_iptv_player/controllers/sources_controller.dart';
import 'package:light_iptv_player/dash/dash_manifest_parser.dart';
import 'package:light_iptv_player/models/epg.dart';
import 'package:light_iptv_player/models/playlist.dart';
import 'package:light_iptv_player/services/epg_parser.dart';
import 'package:light_iptv_player/services/playlist_parser.dart';
import 'package:light_iptv_player/update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('parsePlaylist', () {
    test('parses groups, logos and KODIPROP DRM hints', () {
      final channels = parsePlaylist('''
#EXTM3U url-tvg="http://example.com/epg.xml"
#EXTINF:-1 tvg-id="news1" tvg-logo="logo.png" group-title="News",News One
https://example.com/news.m3u8
#EXTGRP:Movies
#EXTINF:-1,Movie One
https://example.com/movie.m3u8
#KODIPROP:inputstream.adaptive.manifest_type=mpd
#KODIPROP:inputstream.adaptive.license_type=clearkey
#KODIPROP:inputstream.adaptive.license_key=abc:def
#EXTINF:-1,Protected
https://example.com/drm.mpd
''').channels;

      expect(channels, hasLength(3));
      expect(channels[0].name, 'News One');
      expect(channels[0].group, 'News');
      expect(channels[0].logo, 'logo.png');
      expect(channels[0].tvgId, 'news1');
      expect(channels[1].group, 'Movies');

      final drm = channels[2];
      expect(drm.manifestType, 'mpd');
      expect(drm.isDash, isTrue);
      expect(drm.licenseType, 'clearkey');
      expect(drm.licenseKey, 'abc:def');
    });

    test('extracts the EPG url from the header', () {
      final parsed = parsePlaylist(
        '#EXTM3U x-tvg-url="http://example.com/guide.xml.gz"\n'
        '#EXTINF:-1,Ch\nhttp://example.com/ch.ts\n',
      );
      expect(parsed.epgUrl, 'http://example.com/guide.xml.gz');
    });

    test('falls back to the url as name and Ungrouped group', () {
      final channels = parsePlaylist('http://example.com/stream.ts\n').channels;
      expect(channels, hasLength(1));
      expect(channels.single.name, 'http://example.com/stream.ts');
      expect(channels.single.group, ungroupedGroup);
    });
  });

  group('parseXmltv', () {
    Uint8List xml(String s) => Uint8List.fromList(utf8.encode(s));

    const guideXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<tv>
  <channel id="CCTV1">
    <display-name>CCTV 1</display-name>
  </channel>
  <programme start="20260712180000 +0000" stop="20260712190000 +0000" channel="CCTV1">
    <title>Evening News</title>
    <desc>Headlines</desc>
  </programme>
  <programme start="20260712190000 +0000" stop="20260712200000 +0000" channel="CCTV1">
    <title>Drama</title>
  </programme>
</tv>
''';

    test('parses channels and programmes, sorted by start', () {
      final guide = parseXmltv(xml(guideXml));
      expect(guide.channelCount, 1);
      expect(guide.programmeCount, 2);
      final list = guide.byChannelId['cctv1']!;
      expect(list.first.title, 'Evening News');
      expect(list.first.description, 'Headlines');
      expect(list[1].title, 'Drama');
    });

    test('applies the timezone offset to produce UTC instants', () {
      final guide = parseXmltv(
        xml(
          '<tv><programme start="20260712180000 +0800" '
          'stop="20260712190000 +0800" channel="c"><title>X</title>'
          '</programme></tv>',
        ),
      );
      final p = guide.byChannelId['c']!.single;
      // 18:00 +08:00 == 10:00 UTC.
      expect(p.start, DateTime.utc(2026, 7, 12, 10, 0, 0));
    });

    test('nowNext returns the airing programme and the following one', () {
      final guide = parseXmltv(xml(guideXml));
      final result = guide.nowNext(
        'CCTV1',
        'ignored',
        DateTime.utc(2026, 7, 12, 18, 30),
      );
      expect(result.now?.title, 'Evening News');
      expect(result.next?.title, 'Drama');
      expect(result.now!.progressAt(DateTime.utc(2026, 7, 12, 18, 30)), 0.5);
    });

    test('falls back to a display-name match when tvg-id misses', () {
      final guide = parseXmltv(xml(guideXml));
      final result = guide.nowNext(
        'unknown-id',
        'CCTV 1',
        DateTime.utc(2026, 7, 12, 18, 30),
      );
      expect(result.now?.title, 'Evening News');
    });

    test('gunzips a gzip-compressed guide', () {
      final gz = Uint8List.fromList(gzip.encode(utf8.encode(guideXml)));
      final guide = parseXmltv(gz);
      expect(guide.programmeCount, 2);
    });

    group('fuzzy channel matching', () {
      Uint8List named(String id, String displayName) => xml(
        '<tv><channel id="$id"><display-name>$displayName</display-name>'
        '</channel>'
        '<programme start="20260712180000 +0000" stop="20260712190000 +0000" '
        'channel="$id"><title>Show</title></programme></tv>',
      );

      EpgProgramme? matchNow(EpgGuide g, String? tvgId, String name) =>
          g.nowNext(tvgId, name, DateTime.utc(2026, 7, 12, 18, 30)).now;

      test('matches after stripping quality/format/bracket noise', () {
        final guide = parseXmltv(named('tvbplus', 'TVB Plus'));
        // Playlist name has "(字幕)" and an "HD" tag the guide lacks.
        expect(matchNow(guide, 'no-such-id', 'TVB Plus HD (字幕)')?.title, 'Show');
      });

      test('matches a near-miss name via edit distance', () {
        final guide = parseXmltv(named('phoenixcn', 'Phoenix Chinese'));
        // One-character typo should still resolve.
        expect(matchNow(guide, null, 'Phoenix Chinesee')?.title, 'Show');
      });

      test('simplifies CJK generic tokens (台/频道) before matching', () {
        final guide = parseXmltv(named('fenghuang', '凤凰中文台'));
        expect(matchNow(guide, null, '凤凰中文频道')?.title, 'Show');
      });

      test('does not fuzzy-match clearly different channels', () {
        final guide = parseXmltv(named('cctv1', 'CCTV 1'));
        expect(matchNow(guide, 'x', 'HBO Family'), isNull);
      });

      test('does not fuzzy-match on very short ambiguous names', () {
        final guide = parseXmltv(named('a1', 'AB'));
        expect(matchNow(guide, null, 'AC'), isNull);
      });
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

  group('DashManifestParser', () {
    const mpd = '<?xml version="1.0"?>'
        '<MPD type="static" mediaPresentationDuration="PT10S" minBufferTime="PT2S">'
        '<Period>'
        '<AdaptationSet contentType="video" mimeType="video/mp4">'
        '<Representation id="v0" bandwidth="500000" codecs="avc1.4d401f">'
        '<SegmentTemplate timescale="1000" duration="2000" startNumber="1" '
        'initialization="init_\$RepresentationID\$.mp4" '
        'media="seg_\$RepresentationID\$_\$Number\$.mp4"/>'
        '</Representation>'
        '</AdaptationSet>'
        '</Period>'
        '</MPD>';

    test('parses a minimal MPD into a manifest tree', () {
      final manifest =
          const DashManifestParser().parse('https://cdn.test/x.mpd', mpd);
      expect(manifest.periodCount, 1);
      final as_ = manifest.getPeriod(0).adaptationSets.single;
      expect(as_.representations.single.format.id, 'v0');
    });

    test('tolerates a leading BOM and surrounding whitespace', () {
      final withJunk = '\uFEFF\n   $mpd\n\n';
      final manifest =
          const DashManifestParser().parse('https://cdn.test/x.mpd', withJunk);
      expect(manifest.periodCount, 1);
    });

    test('tolerates trailing content after the closing MPD tag', () {
      final withTrailer = '$mpd<!-- edge cache footer -->trailing junk';
      final manifest = const DashManifestParser()
          .parse('https://cdn.test/x.mpd', withTrailer);
      expect(manifest.periodCount, 1);
    });
  });
}
