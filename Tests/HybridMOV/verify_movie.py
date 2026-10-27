#!/usr/bin/env python3
"""Independent full decode and timeline/box checks for Hybrid MOV integration.

Copyright 2026 B00kerLouis. No user media is bundled.
Usage: python3 verify_movie.py movie.mov [--frames N] [--rate 30000/1001]
Requires ffmpeg and ffprobe on PATH. JSON goes to stdout.
"""

import argparse
import json
import pathlib
import struct
import subprocess
from fractions import Fraction


def top_boxes(path):
    size = path.stat().st_size
    result = []
    with path.open("rb") as stream:
        cursor = 0
        while cursor < size:
            stream.seek(cursor)
            header = stream.read(16)
            assert len(header) >= 8, "truncated atom header"
            length, kind = struct.unpack(">I4s", header[:8])
            header_size = 8
            if length == 1:
                length = struct.unpack(">Q", header[8:16])[0]
                header_size = 16
            if length == 0:
                length = size - cursor
            assert header_size <= length <= size - cursor, "truncated atom payload"
            result.append({"type": kind.decode("latin1"), "offset": cursor, "size": length})
            cursor += length
    assert cursor == size
    return result


def verify(path, frames=None, rate=None, hybrid=True):
    probe = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)
    ]))
    video = next(s for s in probe["streams"] if s["codec_type"] == "video")
    packets = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-select_streams", "v:0", "-show_packets",
        "-show_entries", "packet=pts,dts,duration,flags", "-of", "json", str(path)
    ]))["packets"]
    count = frames if frames is not None else int(video["nb_frames"])
    actual_rate = Fraction(rate or video["r_frame_rate"])
    scale = Fraction(video["time_base"])
    assert len(packets) == count, (len(packets), count)
    expected = [Fraction(i, 1) / actual_rate for i in range(count)]
    actual = sorted(Fraction(int(p["pts"])) * scale for p in packets)
    assert actual == expected, "missing, duplicate or shifted picture timestamp"
    dts = [int(p["dts"]) for p in packets]
    assert all(a < b for a, b in zip(dts, dts[1:])), "decode timestamps are not strictly increasing"
    assert all(Fraction(int(p["duration"])) * scale == 1 / actual_rate for p in packets)
    decoded = subprocess.run([
        "ffmpeg", "-hide_banner", "-v", "error", "-xerror", "-threads", "8", "-i", str(path),
        "-map", "0:v:0", "-an", "-fps_mode", "passthrough", "-progress", "pipe:1", "-f", "null", "-"
    ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=True)
    decoded_count = int([line.split("=", 1)[1] for line in decoded.stdout.splitlines() if line.startswith("frame=")][-1])
    assert decoded_count == count, (decoded_count, count)
    boxes = top_boxes(path)
    if hybrid:
        assert [b["type"] for b in boxes] == ["ftyp", "mdat", "moov"], boxes
        assert boxes[1]["offset"] == 20 and boxes[1]["size"] > 16
    return {"path": str(path), "frames": count, "decoded": decoded_count,
            "rate": str(actual_rate), "codec": video["codec_name"], "tag": video["codec_tag_string"],
            "time_base": video["time_base"], "color_primaries": video.get("color_primaries"),
            "color_transfer": video.get("color_transfer"), "color_space": video.get("color_space"),
            "timecode": video.get("tags", {}).get("timecode"), "boxes": boxes}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("movie", type=pathlib.Path)
    parser.add_argument("--frames", type=int)
    parser.add_argument("--rate")
    args = parser.parse_args()
    print(json.dumps(verify(args.movie, args.frames, args.rate), indent=2))
