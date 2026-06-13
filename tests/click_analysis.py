#!/usr/bin/env python3
"""
click_analysis.py — quantify the clicks in a recording using ffmpeg's research-backed
`adeclick` filter as the detector. We do NOT roll our own click detector: ffmpeg's
adeclick implements the autoregressive impulsive-noise model from Godsill & Rayner,
"Digital Audio Restoration: A Statistical Model Based Approach" (Springer, 1998).

Method: residual = original - adeclick(original). What adeclick removes IS the clicks
it detected, so the residual isolates them. We then report the residual level (the
click energy) and the spacing between click bursts (which reveals the period — for a
block-rate artifact, fs/blocksize).

A click burst at the buffer rate (fs / block) is the zipper-noise signature.

Usage: click_analysis.py <original.wav> <declicked.wav> [label] [--max-bursts N]
       [--max-bursts N] turns the run into a gate: exit 1 if more bursts are found
       (a click-free sweep should yield ~0). Without it, just reports and exits 0.
"""
import sys, wave
import numpy as np

def read_wav(path):
    with wave.open(path, 'rb') as w:
        sr = w.getframerate(); ch = w.getnchannels(); n = w.getnframes()
        raw = w.readframes(n)
    x = np.frombuffer(raw, dtype='<i2').astype(np.float64) / 32768.0
    x = x.reshape(-1, ch).mean(axis=1)   # mono mix
    return sr, x

def dbfs(v): return -np.inf if v <= 1e-12 else 20*np.log10(v)

argv = sys.argv[1:]
max_bursts = None
if "--max-bursts" in argv:
    i = argv.index("--max-bursts"); max_bursts = int(argv[i+1]); del argv[i:i+2]
orig_p, decl_p = argv[0], argv[1]
label = argv[2] if len(argv) > 2 else orig_p
sr, a = read_wav(orig_p)
_,  b = read_wav(decl_p)
n = min(len(a), len(b)); a, b = a[:n], b[:n]
resid = a - b                                   # the clicks adeclick removed

peak = np.max(np.abs(resid))
rms  = np.sqrt(np.mean(resid**2))
sig_rms = np.sqrt(np.mean(a**2))

# Click positions: residual samples that stand out as outliers vs the residual's own
# robust spread (MAD). This only LOCATES the bursts adeclick already isolated; it
# doesn't decide what a click is.
env = np.abs(resid)
med = np.median(env); mad = np.median(np.abs(env - med)) + 1e-12
thr = med + 12 * 1.4826 * mad
hits = np.where(env > thr)[0]
# collapse runs into bursts (>= 5 ms apart = separate clicks)
bursts = []
if len(hits):
    start = hits[0]; prev = hits[0]
    for h in hits[1:]:
        if h - prev > sr*0.005:
            bursts.append((start+prev)//2); start = h
        prev = h
    bursts.append((start+prev)//2)
bursts = np.array(bursts)

print(f"── {label}")
print(f"   signal RMS            {dbfs(sig_rms):6.1f} dBFS")
print(f"   residual (clicks) RMS {dbfs(rms):6.1f} dBFS   peak {dbfs(peak):6.1f} dBFS")
print(f"   click-to-signal       {dbfs(rms)-dbfs(sig_rms):6.1f} dB")
print(f"   click bursts detected {len(bursts)}")
if len(bursts) > 2:
    gaps = np.diff(bursts) / sr * 1000.0        # ms between bursts
    med_gap = np.median(gaps)
    rate = 1000.0/med_gap
    print(f"   median burst spacing  {med_gap:6.2f} ms  → {rate:6.1f} Hz"
          f"  (block size ≈ {sr/rate:6.0f} frames @ {sr} Hz)")

if max_bursts is not None:
    ok = len(bursts) <= max_bursts
    print(f"   verdict: {'PASS' if ok else 'FAIL'} "
          f"({len(bursts)} bursts, allowed ≤ {max_bursts})")
    sys.exit(0 if ok else 1)
