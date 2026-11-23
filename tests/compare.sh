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

OURS="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
REF="$2"
MTX="$3"
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
for who in ours ref; do
  BIN=$([ $who = ours ] && echo "$OURS" || echo "$REF")
  BEST=999999
  for run in 1 2; do # best of two, so neither pays for reading the file from disk first
    S=$(now); "$BIN" -hide_banner -loglevel error -y -i long.mp4 -map 0 -c copy -movflags +faststart long_$who.mp4; E=$(now)
    BEST=$($PY -c "print(round(min($BEST, $E - $S), 2))")
  done
  eval "TIME_$who=$BEST"
done
row "Speed: finishing 30 minutes of video" "$($PY -c "print('PASS' if $TIME_ours <= $TIME_ref * 1.25 + 0.5 else 'FAIL')")" "ours ${TIME_ours}s, reference ${TIME_ref}s"
SO=$(wc -c < "$OURS"); SR=$(wc -c < "$(command -v "$REF" || echo "$REF")")
row "Size" "$([ "$SO" -le "$SR" ] && echo PASS || echo FAIL)" "ours $((SO / 1048576)) MB, reference $((SR / 1048576)) MB"

# --- 3. Live streaming over RTMP, fed through a pipe the way the app feeds it ----------------------
#     (RTMPS is the app's job: it encrypts the engine's RTMP itself; see the app's tests.)
cat > mtx.yml <<YML
logLevel: error
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
sleep 2
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
OK=$($PY -c "import json; o=json.loads('$RO'); r=json.loads('$RR'); ok=o['received']>=0.9*r['received'] and o['received']>200 and o['matched']/o['received']>=r['matched']/max(1,r['received'])-0.02; print('PASS' if ok else 'FAIL')")
row "Live stream over RTMP: arrives as intact as the reference's" "$OK" "ours $RO, reference $RR"
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
row "Server drops mid-stream: engine stops within 20 s" "$(echo "$GONE_OURS" | grep -q still && echo FAIL || echo PASS)" "stopped after ${GONE_OURS}s"

# --- 5. Licence: nothing GPL, nonfree or x264 slipped in --------------------------------------------
B=$("$OURS" -hide_banner -buildconf)
row "Licence: LGPL only (no GPL, nonfree or x264)" "$(echo "$B" | grep -qiE 'enable-(gpl|nonfree|version3|libx264)' && echo FAIL || echo PASS)" "$("$OURS" -hide_banner -L 2>/dev/null | grep -m1 -i 'lesser\|lgpl' | sed 's/^ *//' | cut -c1-70)"

echo
printf '%-70s %-5s %s\n' "Check" "Result" "Details"
for r in "${RESULTS[@]}"; do IFS='|' read -r a b c <<< "$r"; printf '%-70s %-5s %s\n' "$a" "$b" "$c"; done
echo
[ "$FAILS" -eq 0 ] && echo "All checks passed." || echo "$FAILS check(s) failed."
exit $((FAILS > 0))
