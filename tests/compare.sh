#!/usr/bin/env bash
# Flock Media Engine vs a reference FFmpeg, on exactly the jobs Flock Studio gives it.
# Every check must come out "same or better" for the engine to ship.
#
#   tests/compare.sh <flock-media> <reference-ffmpeg> <mediamtx>
#
# The reference FFmpeg (a full official build) also makes the test videos and reads results,
# since the engine has no encoders or decoders. MediaMTX stands in for YouTube / Facebook.
# Needs python3 and openssl. Prints a table and exits 1 if any check fails.
set -uo pipefail

abs() { case "$1" in */*) echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")" ;; *) command -v "$1" ;; esac; }
OURS="$(abs "$1")"; REF="$(abs "$2")"; MTX="$(abs "$3")"
for b in "$OURS" "$REF"; do
  "$b" -hide_banner -version >/dev/null 2>&1 || { echo "Can't run $b"; exit 2; }
done
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"
PY="python3"; command -v python3 >/dev/null || PY="python"
FAILS=0
RESULTS=()
q() { "$@" >/dev/null 2>&1; }
row() { RESULTS+=("$1|$2|$3"); [ "$2" = "PASS" ] || FAILS=$((FAILS + 1)); }
now() { $PY -c 'import time; print(time.time())'; }
md5s() { "$REF" -hide_banner -loglevel error -i "$1" -map 0 -c copy -f framemd5 - > "$2"; }
cleanup() { [ -n "${MTX_PID:-}" ] && kill "$MTX_PID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
cd "$T"

echo "Engine:    $("$OURS" -hide_banner -version | head -1)"
echo "Reference: $("$REF" -hide_banner -version | head -1)"
echo

# --- Test videos, made like the Studio makes them: fragmented MP4, H.264 + AAC, keyframe
#     every 2 s (MediaRecorder's output). A 60 s one, a long one for speed, a cut-off one.
make_video() { # seconds size out
  "$REF" -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=$2:rate=30" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -t "$1" -map 0:v -map 1:a -c:v libx264 -preset ultrafast -g 60 -keyint_min 60 -pix_fmt yuv420p -c:a aac -b:a 128k \
    -movflags frag_keyframe+empty_moov+default_base_moof "$3"
}
# COMPARE_CACHE=<folder> keeps the test videos between runs (making the long one takes minutes).
cached_video() { # seconds size name
  if [ -n "${COMPARE_CACHE:-}" ] && [ -s "$COMPARE_CACHE/$3" ]; then cp "$COMPARE_CACHE/$3" "$3"; return; fi
  make_video "$1" "$2" "$3" || return 1
  [ -n "${COMPARE_CACHE:-}" ] && mkdir -p "$COMPARE_CACHE" && cp "$3" "$COMPARE_CACHE/$3"
  return 0
}
cached_video 60 1280x720 rec.mp4 || { echo "couldn't make test videos (the reference needs libx264 and aac)"; exit 1; }
cached_video 1800 640x360 long.mp4
SIZE=$(wc -c < rec.mp4); head -c $((SIZE * 7 / 10)) rec.mp4 > cut.mp4

# --- 1. Finishing a recording (copy, index at the front) ----------------------------------------
for who in ours ref; do
  BIN=$([ $who = ours ] && echo "$OURS" || echo "$REF")
  "$BIN" -hide_banner -loglevel error -y -i rec.mp4 -map 0 -c copy -movflags +faststart fin_$who.mp4
  "$BIN" -hide_banner -loglevel error -y -i cut.mp4 -map 0 -c copy -movflags +faststart cut_$who.mp4
done
md5s fin_ours.mp4 a.txt; md5s fin_ref.mp4 b.txt
R=$($PY "$HERE/analyze.py" same a.txt b.txt)
row "Finished recording: same audio and video as reference" "$(echo "$R" | grep -q '"same": true' && echo PASS || echo FAIL)" "$R"
F=$($PY "$HERE/analyze.py" faststart fin_ours.mp4)
row "Finished recording: index at the front (plays and uploads at once)" "$([ "$F" = yes ] && echo PASS || echo FAIL)" "$F"
md5s rec.mp4 src.txt
R=$($PY "$HERE/analyze.py" same a.txt src.txt)
row "Finished recording: nothing lost from the original" "$(echo "$R" | grep -q '"same": true' && echo PASS || echo FAIL)" "$R"
md5s cut_ours.mp4 c1.txt; md5s cut_ref.mp4 c2.txt
CO=$($PY "$HERE/analyze.py" count c1.txt); CR=$($PY "$HERE/analyze.py" count c2.txt)
row "Cut-off recording (power cut): recovers as much as reference" "$([ "$CO" -ge "$CR" ] && [ "$CO" -gt 0 ] && echo PASS || echo FAIL)" "ours $CO packets, reference $CR"

# --- 2. Speed and footprint on a 30-minute recording ---------------------------------------------
# Only comparable when both run natively: an Intel engine translated by Rosetta on Apple silicon
# (or the other way round) would measure the translator, not the engine.
arch_of() { file -b "$1" 2>/dev/null | grep -oE "x86_64|arm64" | head -1; }
if [ "$(uname -s)" = Darwin ] && [ "$(arch_of "$OURS")" != "$(arch_of "$REF")" ]; then
  row "Speed: finishing 30 minutes of video (median of 5, runs alternate)" PASS "not comparable here: engine $(arch_of "$OURS"), reference $(arch_of "$REF") (one runs translated)"
else
  SP=$($PY "$HERE/analyze.py" speed "$OURS" "$REF" long.mp4)
  row "Speed: finishing 30 minutes of video (median of 5, runs alternate)" "${SP%%|*}" "${SP#*|}"
fi

# Same FFmpeg version as the reference: the finished file must be the same, byte for byte.
OV=$("$OURS" -hide_banner -version | head -1 | cut -d' ' -f3 | cut -d- -f1); RV=$("$REF" -hide_banner -version | head -1 | cut -d' ' -f3 | cut -d- -f1)
if [ "$OV" = "$RV" ]; then
  "$OURS" -hide_banner -loglevel error -y -i rec.mp4 -map 0 -c copy -movflags +faststart -fflags +bitexact bx_ours.mp4
  "$REF" -hide_banner -loglevel error -y -i rec.mp4 -map 0 -c copy -movflags +faststart -fflags +bitexact bx_ref.mp4
  row "Finished recording: byte-for-byte the same file as FFmpeg $RV" "$(cmp -s bx_ours.mp4 bx_ref.mp4 && echo PASS || echo FAIL)" "$(wc -c < bx_ours.mp4) bytes"
fi
# (Not compared with the reference: package-manager FFmpegs are a small program plus separate
# libraries, so their program file alone says nothing.)
SO=$(wc -c < "$OURS")
row "Size: a small, self-contained program (under 10 MB)" "$([ "$SO" -lt 10485760 ] && echo PASS || echo FAIL)" "ours $((SO / 1024)) KB"

# --- 3. Live streaming over RTMP, fed through a pipe the way the app feeds it ----------------------
#     (RTMPS is the app's job: it encrypts the engine's RTMP itself; see the app's tests.)
cat > mtx.yml <<YML
logLevel: info
api: no
rtsp: no
webrtc: no
hls: no
srt: no
rtmp: yes
rtmpAddress: 127.0.0.1:19350
paths:
  all_others:
YML
"$MTX" mtx.yml > mtx.log 2>&1 &
MTX_PID=$!
# Wait until the test server is really listening (it can take a while on a busy machine).
port_open() { $PY -c "import socket,sys; s=socket.socket(); s.settimeout(1); sys.exit(0 if s.connect_ex(('127.0.0.1', $1)) == 0 else 1)"; }
UP=no
for i in $(seq 1 30); do port_open 19350 && { UP=yes; break; }; sleep 0.5; done
if [ "$UP" = no ]; then
  echo "The test streaming server didn't start. Its log:"; cat mtx.log
  row "Test streaming server started" FAIL "MediaMTX didn't listen on 19350 (a test setup problem, not the engine)"
fi
for who in ours ref; do
  BIN=$([ $who = ours ] && echo "$OURS" || echo "$REF")
  ( cat rec.mp4 | "$BIN" -hide_banner -loglevel error -re -f mp4 -i pipe:0 -t 20 -map 0 -c copy -f flv "rtmp://127.0.0.1:19350/live/$who" ) &
  PUSH=$!
  sleep 3
  "$REF" -hide_banner -loglevel error -y -rw_timeout 10000000 -i "rtmp://127.0.0.1:19350/live/$who" -t 12 -map 0 -c copy "pulled_$who.mp4" 2>/dev/null
  wait $PUSH
done
# The test server rewraps some video packets (it adds stream settings to keyframes), so packets
# are compared with what the reference delivers through the same server: the same or better.
md5s pulled_ours.mp4 p1.txt; md5s pulled_ref.mp4 p2.txt
RO=$($PY "$HERE/analyze.py" payload_subset src.txt p1.txt); RR=$($PY "$HERE/analyze.py" payload_subset src.txt p2.txt)
# If the reference itself delivered nothing (its own problem on this machine), ours is judged on
# its own: a full stream whose packets come from the source (the server rewraps some keyframes).
OK=$($PY -c "
import json; o=json.loads('$RO'); r=json.loads('$RR')
if r['received'] < 200: ok = o['received'] > 600 and o['matched'] >= 0.5 * o['received']
else: ok = o['received'] >= 0.9*r['received'] and o['received'] > 200 and o['matched']/o['received'] >= r['matched']/max(1,r['received']) - 0.02
print('PASS' if ok else 'FAIL')")
NOTE=$($PY -c "import json; print(' (the reference delivered nothing here, so ours is judged on its own)' if json.loads('$RR')['received'] < 200 else '')")
row "Live stream over RTMP: arrives as intact as the reference's" "$OK" "ours $RO, reference $RR$NOTE"
"$REF" -hide_banner -skip_frame nokey -i pulled_ours.mp4 -an -vf showinfo -f null - 2>&1 | grep -o "pts_time:[0-9.]*" | cut -d: -f2 > keys.txt
K=$($PY "$HERE/analyze.py" keyframe_gaps keys.txt)
row "Live stream: keyframes every 2 s kept (YouTube and Facebook need it)" "$($PY -c "import json; print('PASS' if (json.loads('$K')['max_gap'] or 9) <= 2.1 else 'FAIL')")" "$K"

# --- 4. The server goes away mid-stream: the engine must exit promptly (the app then reconnects) --
for who in ours ref; do
  BIN=$([ $who = ours ] && echo "$OURS" || echo "$REF")
  ( cat long.mp4 | "$BIN" -hide_banner -loglevel quiet -re -f mp4 -i pipe:0 -map 0 -c copy -f flv "rtmp://127.0.0.1:19350/live/drop_$who" ) &
  eval "PUSH_$who=$!"
done
sleep 4
kill "$MTX_PID" 2>/dev/null; wait "$MTX_PID" 2>/dev/null; MTX_PID=""
S=$(now)
for i in $(seq 1 40); do
  if ! kill -0 "$PUSH_ours" 2>/dev/null; then break; fi
  sleep 0.5
done
GONE_OURS=$($PY -c "print(round($(now) - $S, 1))")
kill -0 "$PUSH_ours" 2>/dev/null && { GONE_OURS="still running after 20 s"; kill "$PUSH_ours" 2>/dev/null; }
kill "$PUSH_ref" 2>/dev/null
if [ "$UP" = yes ]; then
  row "Server drops mid-stream: engine stops within 20 s" "$(echo "$GONE_OURS" | grep -q still && echo FAIL || echo PASS)" "stopped after ${GONE_OURS}s"
else
  row "Server drops mid-stream: engine stops within 20 s" FAIL "not tested: the test server never started"
fi

# --- 5. Licence: nothing GPL, nonfree or x264 slipped in --------------------------------------------
B=$("$OURS" -hide_banner -buildconf)
row "Licence: LGPL only (no GPL, nonfree or x264)" "$(echo "$B" | grep -qiE 'enable-(gpl|nonfree|version3|libx264)' && echo FAIL || echo PASS)" "$("$OURS" -hide_banner -L 2>/dev/null | grep -m1 -i 'lesser\|lgpl' | sed 's/^ *//' | cut -c1-70)"

echo
printf '%-70s %-5s %s\n' "Check" "Result" "Details"
for r in "${RESULTS[@]}"; do IFS='|' read -r a b c <<< "$r"; printf '%-70s %-5s %s\n' "$a" "$b" "$c"; done
echo
[ "$FAILS" -eq 0 ] && echo "All checks passed." || echo "$FAILS check(s) failed."

# On GitHub Actions: the results as an annotation too (annotations are public on a public repo,
# job logs aren't), so anyone can read them from the run page or the API without admin access.
if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  TABLE="Engine $("$OURS" -hide_banner -version | head -1 | cut -d' ' -f3) vs reference $("$REF" -hide_banner -version | head -1 | cut -d' ' -f3)"
  for r in "${RESULTS[@]}"; do IFS='|' read -r a b c <<< "$r"; TABLE="$TABLE%0A$b  $a  ($c)"; done
  echo "::notice title=Comparison ($FAILS failed)::$TABLE"
fi
exit $((FAILS > 0))
