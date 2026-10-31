# lineshift.py <frames> <w> <h> <maxshift> <axis x|y> <ref first|last>: per frame, the shift of the reference band that best matches it
import sys, numpy as np
path, w, h, M, axis, which = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5], sys.argv[6]
n = w * h * 3 + 8; raw = open(path, "rb").read(); k = len(raw) // n
t = [np.frombuffer(raw[i*n:i*n+8], "<f8")[0] for i in range(k)]
F = [np.frombuffer(raw[i*n+8:(i+1)*n], np.uint8).reshape(h, w, 3).astype(float).sum(2) for i in range(k)]
if axis == "y": F = [f.T for f in F]
ref = F[0] if which == "first" else F[-1]; N = ref.shape[1]; last = None
for ti, f in zip(t, F):
    best = None
    for s in range(-M, M + 1):
        a = ref[:, max(0, -s):N - max(0, s)]; b = f[:, max(0, s):N - max(0, -s)]
        if a.shape[1] < N // 3: continue
        e = np.abs(a - b).mean()
        if best is None or e < best[1]: best = (s, e)
    if last is None or best[0] != last[0]:
        print(f"{ti:8.1f} shift={best[0]:4d} err={best[1]:6.1f}"); last = best
