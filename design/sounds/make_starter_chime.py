"""Synthesizes Nog's two-minute-start chime: a soft, rising, celesta-like
arpeggio (G C E G) whose top note rings out. Run: python3 design/sounds/make_starter_chime.py
(needs numpy; ffmpeg turns the WAV into Nog/Resources/StarterChime.caf)."""
import subprocess, sys, wave
import numpy as np

SR = 44100
LENGTH = 2.0

def bell(freq, start, dur, gain, tau):
    t = np.arange(int(dur * SR)) / SR
    # Soft attack (no click), long gentle decay.
    env = (1 - np.exp(-t / 0.025)) * np.exp(-t / tau)
    partials = [(1.0, 1.0), (2.0, 0.12), (3.0, 0.02)]  # mostly the fundamental: soft, not bell-bright
    tone = sum(a * np.sin(2 * np.pi * freq * m * t) * np.exp(-t * (m - 1) * 3.0) for m, a in partials)
    # A whisper of vibrato so it feels alive, not electronic.
    tone *= 1 + 0.004 * np.sin(2 * np.pi * 5.2 * t)
    out = np.zeros(int(LENGTH * SR))
    i = int(start * SR)
    n = min(len(t), len(out) - i)
    out[i:i + n] += gain * env[:n] * tone[:n]
    return out

C5, E5, G5, C6, E6 = 523.25, 659.25, 783.99, 1046.50, 1318.51
G4 = 392.00
signal = (
    # A four-step rise; the top note rings out.
    bell(G4, 0.00, 1.2, 0.55, 0.45)
    + bell(C5, 0.14, 1.2, 0.55, 0.45)
    + bell(E5, 0.28, 1.2, 0.55, 0.45)
    + bell(G5, 0.42, 1.6, 0.58, 0.60)
)
# A small room: a few soft early reflections.
for delay, g in [(0.043, 0.12), (0.071, 0.08), (0.113, 0.05)]:
    d = int(delay * SR)
    signal[d:] += g * signal[:-d].copy()
# Fade the last 300 ms to silence.
fade = int(0.3 * SR)
signal[-fade:] *= np.linspace(1, 0, fade)
# Soft: peak at -8 dBFS.
signal *= 0.4 / np.max(np.abs(signal))

wav = sys.argv[1] if len(sys.argv) > 1 else "/tmp/StarterChime.wav"
with wave.open(wav, "wb") as f:
    f.setnchannels(1); f.setsampwidth(2); f.setframerate(SR)
    f.writeframes((signal * 32767).astype("<i2").tobytes())
if len(sys.argv) > 2:
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav, "-c:a", "pcm_s16be", "-f", "caf", sys.argv[2]],
                   check=True)
