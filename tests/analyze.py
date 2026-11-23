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

cmd = sys.argv[1]
if cmd == "same":  # two framemd5 files: identical packets (data and timing)?
    a, b = packets(sys.argv[2]), packets(sys.argv[3])
    print(json.dumps({"same": a == b, "a": len(a), "b": len(b)}))
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
