#!/usr/bin/env bash
# Flock Media Engine: FFmpeg, built with only what Flock Studio uses.
#
# Flock Studio uses it for two jobs, both without re-encoding anything:
#   1. finishing recordings into a normal MP4 (index at the front)   -c copy -movflags +faststart
#   2. sending a live stream over RTMP                                  -c copy -f flv rtmp://...
# So everything else (every encoder and decoder, devices, filters, x264, any TLS library) is left
# out. That makes it LGPL (no --enable-gpl, --enable-version3 or --enable-nonfree), small, and
# with far less code that could carry security bugs.
#
# No encryption inside: for RTMPS (YouTube, Facebook) Flock Studio encrypts the stream itself,
# with the TLS built into the app (Chromium's), through a relay on the same computer. FFmpeg's
# macOS TLS (Secure Transport) stalls a second into a long RTMPS stream (tested 2026-11-23, in
# both FFmpeg 4.1 and 9.0.2), and the app's TLS is current, the same on every platform.
#
#   scripts/build.sh macos-arm64 | macos-x64 | windows-x64
#
# macOS targets build on a Mac (Xcode command line tools). windows-x64 cross-compiles with
# mingw-w64 (Linux: apt install mingw-w64; macOS: brew install mingw-w64).
# Output: dist/<target>/flock-media[.exe], BUILDINFO.txt, LICENSE.txt
set -euo pipefail

FFMPEG_VERSION="9.0.2"
FFMPEG_SHA256="8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"

TARGET="${1:?target: macos-arm64 | macos-x64 | windows-x64}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE_VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
CACHE="$ROOT/.cache"
WORK="$ROOT/.build/$TARGET"
OUT="$ROOT/dist/$TARGET"
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
mkdir -p "$CACHE" "$OUT"

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# 1. The official source, checked against the pinned checksum (a different file never builds).
TARBALL="$CACHE/ffmpeg-$FFMPEG_VERSION.tar.xz"
[ -f "$TARBALL" ] || curl -sSfL "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" -o "$TARBALL"
GOT="$(sha256 "$TARBALL")"
if [ "$GOT" != "$FFMPEG_SHA256" ]; then
  echo "FFmpeg source checksum mismatch: got $GOT" >&2
  rm -f "$TARBALL"
  exit 1
fi
rm -rf "$WORK" && mkdir -p "$WORK"
tar xf "$TARBALL" -C "$WORK" --strip-components 1
cd "$WORK"

# 2. Flock's changes to the source (the only ones; LGPL asks that they're public, and they are):
#    Windows file properties and icon for flock-media.exe.
if [ "$TARGET" = "windows-x64" ]; then
  cp "$ROOT/branding/flock-media.ico" fftools/flock-media.ico
  IFS=. read -r MA MI PA <<< "$ENGINE_VERSION"
  cat >> fftools/fftoolsres.rc <<RC

// Flock Media Engine branding (added by Flock's build script)
1 ICON "flock-media.ico"
1 VERSIONINFO
FILEVERSION $MA,$MI,$PA,0
PRODUCTVERSION $MA,$MI,$PA,0
BEGIN
  BLOCK "StringFileInfo"
  BEGIN
    BLOCK "040904B0"
    BEGIN
      VALUE "CompanyName", "Flock Systems Limited"
      VALUE "FileDescription", "Flock Media Engine (built on FFmpeg $FFMPEG_VERSION)"
      VALUE "FileVersion", "$ENGINE_VERSION"
      VALUE "InternalName", "flock-media"
      VALUE "LegalCopyright", "FFmpeg is licensed under the LGPL 2.1 or later. Flock build script: Flock Systems Limited."
      VALUE "OriginalFilename", "flock-media.exe"
      VALUE "ProductName", "Flock Media Engine"
      VALUE "ProductVersion", "$ENGINE_VERSION"
    END
  END
  BLOCK "VarFileInfo"
  BEGIN
    VALUE "Translation", 0x409, 1200
  END
END
RC
fi

# 3. Only what Flock Studio uses.
FLAGS=(
  --disable-everything --disable-autodetect --disable-doc --disable-debug
  --disable-ffplay --disable-ffprobe --disable-avdevice --disable-swscale --disable-x86asm
  --enable-protocol=file,pipe,tcp,rtmp
  --enable-demuxer=mov,flv
  --enable-muxer=mp4,mov,flv,framemd5,null
  --enable-parser=h264,aac
  --enable-bsf=aac_adtstoasc,h264_mp4toannexb,extract_extradata
  --extra-version="flock-${ENGINE_VERSION}"
)
case "$TARGET" in
  macos-arm64|macos-x64)
    ARCH="${TARGET#macos-}"; [ "$ARCH" = "x64" ] && ARCH="x86_64"
    MAC_FLAGS="-arch $ARCH -mmacosx-version-min=12.0"
    FLAGS+=(--cc=clang --arch="$ARCH" --extra-cflags="$MAC_FLAGS" --extra-ldflags="$MAC_FLAGS")
    [ "$(uname -m)" = "$ARCH" ] || [ "$(uname -m)/$ARCH" = "arm64/arm64" ] || FLAGS+=(--enable-cross-compile --target-os=darwin)
    EXE="flock-media" ;;
  windows-x64)
    FLAGS+=(--target-os=mingw32 --arch=x86_64 --cross-prefix=x86_64-w64-mingw32- --enable-cross-compile --extra-ldflags=-static)
    EXE="flock-media.exe" ;;
  *) echo "unknown target $TARGET" >&2; exit 1 ;;
esac

./configure "${FLAGS[@]}" > configure.log 2>&1 || { tail -40 configure.log >&2; exit 1; }
make -j"$JOBS" ffmpeg > make.log 2>&1 || { tail -40 make.log >&2; exit 1; }

# 4. Out: the engine, signed on macOS (the free "ad-hoc" signature every Apple silicon program
#    needs to run; the app's real signature replaces it once Flock has an Apple developer account).
cp "ffmpeg$( [ "$TARGET" = windows-x64 ] && echo .exe )" "$OUT/$EXE"
case "$TARGET" in
  macos-*) strip "$OUT/$EXE"; codesign --force -s - -i cc.flocks.media "$OUT/$EXE" ;;
  windows-x64) x86_64-w64-mingw32-strip "$OUT/$EXE" ;;
esac
cp COPYING.LGPLv2.1 "$OUT/LICENSE.txt"
{
  echo "Flock Media Engine $ENGINE_VERSION ($TARGET)"
  echo "Built on FFmpeg $FFMPEG_VERSION, https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
  echo "Source SHA-256: $FFMPEG_SHA256"
  echo "Built: $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(uname -sm)"
  echo "Configure: ${FLAGS[*]}"
  echo "Licence: $(grep -m1 'License:' configure.log 2>/dev/null || echo 'LGPL version 2.1 or later')"
  echo "SHA-256: $(sha256 "$OUT/$EXE")"
} > "$OUT/BUILDINFO.txt"
cat "$OUT/BUILDINFO.txt"
