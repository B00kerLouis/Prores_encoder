#!/usr/bin/env python3
"""Real process-kill, locked-job, corruption and interrupted-header integration.

Copyright 2026 B00kerLouis. Operates only on the new output-dir supplied here.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import time
from fractions import Fraction

from verify_movie import verify


def ledger(path):
    envelope = json.loads(path.read_bytes())
    payload = base64.b64decode(envelope["payload"])
    assert hashlib.sha256(payload).hexdigest() == envelope["sha256"]
    return json.loads(payload)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def run(args):
    root = args.output_dir.resolve()
    root.mkdir(parents=True, exist_ok=False)
    movie = root / "recovered.mov"
    state = root / ".recovered.mov.hybrid-state"
    journal = state / "journal.json"
    partial = root / "recovered.hybrid-partial.mov"
    command = [str(args.encoder.resolve()), "-i", str(args.input.resolve()), "-o", str(movie),
               "-q", args.quality]
    if not args.automatic:
        command += ["--hybrid-mov", "--vt-workers", "2"]
    if args.quality == "hevc":
        command += ["-b", "100", "--muti-pass", "off", "-dp", "5", "--cmu", "1000", "-ci",
                    "--gamut", "rec2020lm", "--oetf", "pq", "--nit", "1000"]
    log = (root / "killed.log").open("w")
    process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
    deadline = time.monotonic() + 120
    checkpoint = None
    try:
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError("job finished or failed before kill checkpoint")
            try:
                current = ledger(journal)
                frames = sum(len(fragment["video"]) for fragment in current["fragments"])
                if frames >= 480 and frames < args.frames:
                    checkpoint = current
                    process.send_signal(signal.SIGSTOP)
                    break
            except (FileNotFoundError, ValueError, KeyError):
                pass
            time.sleep(0.002)
        assert checkpoint is not None, "no kill checkpoint"
        locked = subprocess.run(command + ["--hybrid-resume"], capture_output=True, text=True, timeout=30)
        (root / "locked.log").write_text(locked.stdout + locked.stderr)
        assert locked.returncode != 0 and "another process owns this job" in locked.stdout
    finally:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=30)
        log.close()
    checkpoint = ledger(journal)
    frames = sum(len(fragment["video"]) for fragment in checkpoint["fragments"])
    original_journal = journal.read_bytes()
    resume = command + ["--hybrid-resume"]

    # The interrupted artifact must expose every committed packet as MOV,
    # independently of the journal-aware resume implementation.
    partial_probe = subprocess.run(["ffprobe", "-v", "warning", "-select_streams", "v:0",
        "-show_packets", "-show_streams", "-show_entries", "packet=pts:stream=time_base", "-of", "json", str(partial)],
        capture_output=True, text=True, timeout=30)
    (root / "partial-probe.log").write_text(partial_probe.stderr)
    parsed = json.loads(partial_probe.stdout)
    pts = sorted(int(p["pts"]) for p in parsed["packets"])
    assert len(pts) >= frames, (len(pts), frames)
    time_base = Fraction(parsed["streams"][0]["time_base"])
    rate = Fraction(args.rate)
    # FFmpeg applies a decoder-delay bias to signed CTS in fragmented MOV.
    # Check exact contiguous presentation intervals here; the finalized flat
    # movie below must additionally start at zero with no timestamp bias.
    initial_pts = pts[0]
    assert [(p - initial_pts) * time_base for p in pts[:frames]] == [Fraction(i, 1) / rate for i in range(frames)]

    # Changed encoding options must fail before the prefix is rewritten.
    before = digest(partial)
    mismatch = list(resume)
    if args.quality == "hevc":
        mismatch[mismatch.index("-b") + 1] = "99"
    else:
        mismatch[mismatch.index("-q") + 1] = "422lt"
    result = subprocess.run(mismatch, capture_output=True, text=True, timeout=30)
    (root / "mismatch.log").write_text(result.stdout + result.stderr)
    assert result.returncode != 0 and "source or options changed" in result.stdout
    assert digest(partial) == before

    # A damaged journal must be rejected, with the media left untouched.
    envelope = json.loads(original_journal)
    payload = bytearray(base64.b64decode(envelope["payload"]))
    payload[len(payload) // 2] ^= 1
    envelope["payload"] = base64.b64encode(payload).decode()
    journal.write_text(json.dumps(envelope))
    result = subprocess.run(resume, capture_output=True, text=True, timeout=30)
    (root / "journal-corruption.log").write_text(result.stdout + result.stderr)
    assert result.returncode != 0 and "journal checksum mismatch" in result.stdout
    assert digest(partial) == before
    journal.write_bytes(original_journal)

    # Committed-payload damage must not be mistaken for an incomplete tail.
    offset = checkpoint["fragments"][0]["video"][0]["offset"]
    with partial.open("r+b") as stream:
        stream.seek(offset)
        original = stream.read(1)
        stream.seek(offset)
        stream.write(bytes([original[0] ^ 1]))
        stream.flush()
        os.fsync(stream.fileno())
    damaged = digest(partial)
    result = subprocess.run(resume, capture_output=True, text=True, timeout=30)
    (root / "payload-corruption.log").write_text(result.stdout + result.stderr)
    assert result.returncode != 0 and "SHA-256 verification" in result.stdout
    assert digest(partial) == damaged
    with partial.open("r+b") as stream:
        stream.seek(offset)
        stream.write(original)
        # Simulate a torn final header and an uncommitted trailing write.
        stream.seek(20)
        stream.write(struct.pack(">I4sQ", 1, b"mdat", (1 << 64) - 1))
        stream.seek(0, 2)
        stream.write(b"incomplete-uncommitted-tail")
        stream.flush()
        os.fsync(stream.fileno())
    if "--vt-workers" in resume:
        resume[resume.index("--vt-workers") + 1] = "1"
    else:
        resume += ["--vt-workers", "1"]
    start = time.monotonic()
    result = subprocess.run(resume, capture_output=True, text=True, timeout=180)
    elapsed = time.monotonic() - start
    (root / "resume.log").write_text(result.stdout + result.stderr)
    assert result.returncode == 0, result.stdout + result.stderr
    assert f"reused {frames} committed frames" in result.stdout
    validation = verify(movie, args.frames, args.rate)
    report = {"quality": args.quality, "automatic_initial_job": args.automatic,
        "killed_process_exit": process.returncode, "reused_frames": frames,
        "independently_readable_committed_packets": frames,
        "partial_demuxer_start_seconds": str(initial_pts * time_base),
        "exclusive_lock_rejection": True, "option_mismatch_rejection": True,
        "journal_corruption_rejection": True, "committed_payload_corruption_rejection": True,
        "torn_header_and_tail_recovery": True, "changed_worker_count": "2 -> 1",
        "resume_seconds": elapsed, "validation": validation}
    (root / "report.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--encoder", type=Path, required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--frames", type=int, required=True)
    parser.add_argument("--rate", required=True)
    parser.add_argument("--automatic", action="store_true", help="exercise the default CLI route without Hybrid/worker flags")
    parser.add_argument("--quality", choices=["proxy", "hevc"], default="proxy",
                        help="hevc additionally exercises generated Dolby Vision Profile 5 subdivisions")
    run(parser.parse_args())
