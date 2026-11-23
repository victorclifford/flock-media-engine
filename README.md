<p align="center"><img src="branding/flock-media.png" width="96" alt="Flock"></p>

# Flock Media Engine

The media engine inside **Flock Studio**, Flock's live production app for churches. It is
[FFmpeg](https://ffmpeg.org), built with only the parts Flock Studio uses, by
[Flock Systems Limited](https://flocks.cc).

Flock Studio uses it for two jobs, neither of which re-encodes anything:

| Job | What it does |
|---|---|
| **Finishing recordings** | Turns the Studio's recording into a standard MP4 that plays and uploads straight away |
| **Live streaming** | Sends the Studio's stream to YouTube, Facebook or any RTMP / RTMPS server |

Everything else (every encoder and decoder, devices, filters, x264, OpenSSL) is left out. So it is:

- **LGPL-licensed** (no GPL, "version 3" or nonfree parts)
- **Small**: about 2 MB, against 35 to 70 MB for a full FFmpeg
- **Up to date**, with far less code that could carry security bugs
- **On the system's own encryption** for RTMPS: Secure Transport on macOS, Schannel on Windows

## Builds

| Platform | File |
|---|---|
| macOS, Apple silicon | `flock-media` |
| macOS, Intel | `flock-media` |
| Windows, 64-bit | `flock-media.exe` |

Each release lists the FFmpeg version it is built on, the exact build settings and a SHA-256
checksum per file. Flock Studio pins those checksums, so a file that doesn't match is never used.

## How it's built and tested

`scripts/build.sh <macos-arm64 | macos-x64 | windows-x64>` downloads the official FFmpeg source,
checks it against a pinned checksum, applies Flock's only change (Windows file details and icon),
and builds with the settings in the script.

`tests/compare.sh` runs the engine and a full official FFmpeg through the same jobs (finishing a
recording, recovering one cut off mid-file, streaming over RTMP and RTMPS, a server dropping
mid-stream) and requires the engine to be the same or better on every check. Releases are built
and tested on each platform by GitHub Actions (`.github/workflows/build.yml`).

## Licence

FFmpeg is licensed under the GNU Lesser General Public License, version 2.1 or later
(`LICENSE.txt` in each build). The build script and tests in this repository are LGPL 2.1 or
later too. FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project; Flock
Media Engine is not affiliated with or endorsed by the FFmpeg project.
