# Light IPTV Player

A lightweight Windows IPTV player built with Flutter. Playback is handled by `media_kit` (mpv/libmpv).

## Development

Requires Flutter SDK installed and available in PATH.

Run the desktop app:

```powershell
flutter run -d windows
```

Run checks:

```powershell
flutter analyze
```

Build the Windows app:

```powershell
flutter build windows
```

Output: `build\windows\x64\runner\Release\light_iptv_player.exe`

> Flutter Windows plugins require symlink support. If the build says symlink
> support is missing, enable Windows Developer Mode via `ms-settings:developers`.

## Features

- Manage playlist sources on a native Flutter start page.
- Import local `.m3u` / `.m3u8` files.
- Import online M3U URLs.
- Add a single stream URL for quick testing.
- Edit source name and URL after creation.
- Persist imported sources and parsed channels locally.
- Parse `group-title`, `#EXTGRP`, channel names, stream URLs, and logos.
- Group and channel lists beside an embedded mpv-backed player.
- AV3A (AVS3-P3 / Audio Vivid) playback on Windows through a synchronized
  AV3A-to-AAC transcoding bridge; video remains stream-copied.
- Hardware decode toggle (HW/SW).
- Real-time playback info: resolution, FPS, bitrate.
- Double-click video area to enter/exit fullscreen.
- Channel list scroll position preserved across fullscreen toggle.

## AV3A support

Windows builds download a SHA-256-pinned third-party FFmpeg runtime at CMake
configure time. AV3A is detected from HLS/MP4 signalling or MPEG-TS PMT stream
type `0xD5`; its audio is decoded and converted to stereo AAC while video is
copied unchanged into a streaming Matroska bridge. Set CMake option
`ENABLE_AV3A_SUPPORT=OFF` to omit it.

The upstream AV3A runtime release does not include a license file. Review its
redistribution terms before shipping it. The build installs a source/hash
notice under `data/licenses/av3a_ffmpeg`.
