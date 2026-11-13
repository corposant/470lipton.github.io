"""Synthesizes Nog's notification chimes with the same soft, celesta-like recipe as
the starter chime: Nodge (the default reminder), Bipple and Heyhey (the default
alarm). Nodge and Bipple last 0.75 s, Heyhey 1 s, each with a short sustain.
Run: python3 design/sounds/make_notification_chimes.py [out_dir]
(needs numpy and ffmpeg; writes NodgeChime.caf, BippleChime.caf, HeyheyChime.caf)."""
import os, subprocess, sys, tempfile, wave
import numpy as np

SR = 44100
C5, E5, G5, C6, E6, G6 = 523.25, 659.25, 783.99, 1046.50, 1318.51, 1567.98

def bell(out, freq, start, gain, tau, bright=0.12, attack=0.02):
    t = np.arange(len(out) - int(start * SR)) / SR
    env = (1 - np.exp(-t / attack)) * np.exp(-t / tau)  # soft attack, short decay
    partials = [(1.0, 1.0), (2.0, bright), (3.0, bright / 6), (4.07, bright / 10)]
    tone = sum(a * np.sin(2 * np.pi * freq * m * t) * np.exp(-t * (m - 1) * 3.0) for m, a in partials)
    tone *= 1 + 0.004 * np.sin(2 * np.pi * 5.2 * t)
    out[int(start * SR):] += gain * env * tone

def render(notes, peak, length=0.75, **kw):
    s = np.zeros(int(length * SR))
    for n in notes:
        bell(s, *n, **kw)
    for delay, g in [(0.043, 0.12), (0.071, 0.08), (0.113, 0.05)]:  # a small room
        d = int(delay * SR)
        s[d:] += g * s[:-d].copy()
    fade = int(0.12 * SR)
    s[-fade:] *= np.linspace(1, 0, fade)
    return s * peak / np.max(np.abs(s))

CHIMES = {
    # Up a fifth, "hey there".
    "NodgeChime": render([(G5, 0.00, 0.55, 0.14), (C6, 0.11, 0.6, 0.19)], 0.45),
    # The starter chime turned over: falling C6 G5 E5 C5.
    "BippleChime": render([(C6, 0.00, 0.5, 0.10), (G5, 0.08, 0.5, 0.10),
                           (E5, 0.16, 0.5, 0.10), (C5, 0.24, 0.6, 0.17)], 0.42),
    # Brighter C E G, twice. Firm, never harsh.
    "HeyheyChime": render([(C6, 0.00, 0.55, 0.09), (E6, 0.08, 0.55, 0.09), (G6, 0.16, 0.55, 0.12),
                           (C6, 0.42, 0.55, 0.09), (E6, 0.50, 0.55, 0.09), (G6, 0.58, 0.6, 0.18)],
                          0.6, length=1.0, bright=0.3, attack=0.008),
}

out_dir = sys.argv[1] if len(sys.argv) > 1 else "Nog/Resources"
for name, signal in CHIMES.items():
    wav = os.path.join(tempfile.gettempdir(), name + ".wav")
    with wave.open(wav, "wb") as f:
        f.setnchannels(1); f.setsampwidth(2); f.setframerate(SR)
        f.writeframes((signal * 32767).astype("<i2").tobytes())
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav, "-c:a", "pcm_s16be", "-f", "caf",
                    os.path.join(out_dir, name + ".caf")], check=True)
