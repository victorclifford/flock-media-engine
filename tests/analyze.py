"""Helpers for compare.sh: reads ffmpeg's framemd5 output and MP4 box order (no dependencies)."""
import struct, sys, json

def packets(path):
    """framemd5 lines -> [(stream, pts, size, hash)], skipping header comments."""
    out = []
    for line in open(path, encoding="utf-8", errors="replace"):
        if line.startswith("#") or not line.strip():
            continue
        p = [x.strip() for x in line.split(",")]
        if len(p) >= 6:
            out.append((int(p[0]), int(p[2]), int(p[4]), p[5]))
    return out

def top_boxes(path):
    order, f = [], open(path, "rb")
    while True:
        h = f.read(8)
        if len(h) < 8:
            break
        size, typ = struct.unpack(">I4s", h)
        order.append(typ.decode("latin1"))
        if size == 1:
            size = struct.unpack(">Q", f.read(8))[0]
            f.seek(size - 16, 1)
        elif size == 0:
            break
        else:
            f.seek(size - 8, 1)
    return order

def timed(argv):
    """Runs a command; returns (wall seconds, CPU seconds or None where the OS can't say)."""
    import subprocess, time
    try:
        import resource
        before = resource.getrusage(resource.RUSAGE_CHILDREN)
    except ImportError:  # Windows
        resource = None
    t = time.time()
    subprocess.run(argv, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    wall = time.time() - t
    if resource is None:
        return wall, None
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    return wall, (after.ru_utime - before.ru_utime) + (after.ru_stime - before.ru_stime)

cmd = sys.argv[1]
if cmd == "speed":  # speed OURS REF INPUT: 9 alternating runs each, median wall and CPU time
    import statistics
    ours, ref, src = sys.argv[2], sys.argv[3], sys.argv[4]
    runs = {"ours": [], "ref": []}
    for i in range(9):
        order = (("ours", ours), ("ref", ref)) if i % 2 == 0 else (("ref", ref), ("ours", ours))
        for who, binary in order:
            runs[who].append(timed([binary, "-hide_banner", "-loglevel", "error", "-y", "-i", src, "-map", "0", "-c", "copy", "-movflags", "+faststart", f"speed_{who}.mp4"]))
    med = lambda who, i: statistics.median(r[i] for r in runs[who]) if runs[who][0][i] is not None else None
    ow, rw, oc, rc = med("ours", 0), med("ref", 0), med("ours", 1), med("ref", 1)
    # Shared build machines vary by a third from one moment to the next (the same binary has
    # measured 4.63s and 6.12s against a reference at about 4.8s), so this catches what matters:
    # a build setting that makes it clearly slower (those are 2 to 3 times). Fails above 25%.
    ok = (oc <= rc * 1.25 + 0.1 if oc is not None else True) and ow <= rw * 1.25 + 0.3
    detail = (f"median CPU ours {oc:.2f}s, reference {rc:.2f}s; " if oc is not None else "") + f"median wall ours {ow:.2f}s, reference {rw:.2f}s"
    print(("PASS" if ok else "FAIL") + "|" + detail)
    sys.exit(0)

if cmd == "same":  # two framemd5 files: identical packets (data and timing)?
    a, b = packets(sys.argv[2]), packets(sys.argv[3])
    print(json.dumps({"same": bool(a) and a == b, "a": len(a), "b": len(b)}))  # nothing isn't "the same"
elif cmd == "count":
    print(len(packets(sys.argv[2])))
elif cmd == "faststart":  # moov before mdat?
    o = top_boxes(sys.argv[2])
    print("yes" if "moov" in o and "mdat" in o and o.index("moov") < o.index("mdat") else "no")
elif cmd == "payload_subset":  # each stream's received packets (data only) appear in the source, in order
    src = packets(sys.argv[2])
    got = packets(sys.argv[3])
    total = matched = 0
    for stream in sorted({p[0] for p in got}):
        s_ = [(z, h) for st, _, z, h in src if st == stream]
        g_ = [(z, h) for st, _, z, h in got if st == stream]
        i = 0
        for g in g_:
            total += 1
            while i < len(s_) and s_[i] != g:
                i += 1
            if i < len(s_):
                matched += 1
                i += 1
    print(json.dumps({"received": total, "matched": matched}))
elif cmd == "keyframe_gaps":  # seconds between video keyframes in an FLV/MP4 (from showinfo-free framemd5 is impossible; uses pts list)
    pts = [float(x) for x in open(sys.argv[2]).read().split()]
    gaps = [round(b - a, 2) for a, b in zip(pts, pts[1:])]
    print(json.dumps({"max_gap": max(gaps) if gaps else None, "keyframes": len(pts)}))
