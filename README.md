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
- Hardware decode toggle (HW/SW).
- Real-time playback info: resolution, FPS, bitrate.
- Double-click video area to enter/exit fullscreen.
- Channel list scroll position preserved across fullscreen toggle.
