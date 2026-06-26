import 'package:flutter_test/flutter_test.dart';
import 'package:light_iptv_player/main.dart';

void main() {
  test('parses m3u groups and logos', () {
    final channels = parsePlaylist('''
#EXTM3U
#EXTINF:-1 tvg-logo="logo.png" group-title="News",News One
https://example.com/news.m3u8
#EXTGRP:Movies
#EXTINF:-1,Movie One
https://example.com/movie.m3u8
''');

    expect(channels, hasLength(2));
    expect(channels[0].name, 'News One');
    expect(channels[0].group, 'News');
    expect(channels[0].logo, 'logo.png');
    expect(channels[1].group, 'Movies');
  });
}
