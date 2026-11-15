"""Contained carton: the carton is the icon's outer shape, and the beam and spectrum
happen on its faces instead of out in the scene. Reads as one silhouette at
notification-banner size. Writes AppIcon-comix.svg and AppIcon-neon.svg.

    python3 make5.py && node render.js AppIcon-comix AppIcon-neon
"""
import importlib.util
spec = importlib.util.spec_from_file_location("m4", "make4.py"); m4 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m4)
SYNTH, svg, bulgy, contour, hatch, comix_letters, INK = m4.SYNTH, m4.svg, m4.bulgy, m4.contour, m4.hatch, m4.comix_letters, m4.INK


def lerp(p, q, t):
    return (p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t)


def contained_carton(colors, dark=False, seed=11):
    # Big three-quarter carton, centred, with room for the iOS corner mask.
    FL, FR, TOP, BOT, DX, DY = 176, 600, 392, 928, 240, -76
    gable, fin = 150, 54
    rf = ((FL + FR) / 2, TOP - gable); rb = (rf[0] + DX, rf[1] + DY)
    front = [(FL, BOT), (FL, TOP), (FR, TOP), (FR, BOT)]
    side = [(FR, TOP), (FR + DX, TOP + DY), (FR + DX, BOT + DY), (FR, BOT)]
    gable_tri = [(FL, TOP), rf, (FR, TOP)]
    roof = [rf, rb, (FR + DX, TOP + DY), (FR, TOP)]
    fin_poly = [rf, (rf[0], rf[1] - fin), (rb[0], rb[1] - fin), rb]
    fill_front = "url(#darkFront)" if dark else "url(#paper)"
    fill_side = "url(#darkSide)" if dark else "url(#paperSide)"
    hatch_col = "#FF8CC6" if dark else INK
    hatch_col2 = "#4FB3FF" if dark else INK
    line = "#F4EEFF" if dark else INK

    d_front = bulgy(front, [-18, 6, 0, 5], seed)
    d_side = bulgy(side, [4, 14, 8, 0], seed + 1)
    d_gable = bulgy(gable_tri, [5, 5, 0], seed + 2)
    d_roof = bulgy(roof, [3, 4, 6, 0], seed + 3)
    d_fin = bulgy(fin_poly, [2, 3, 2, 0], seed + 4)
    clips = (f'<clipPath id="cSide"><path d="{d_side}"/></clipPath><clipPath id="cRoof"><path d="{d_roof}"/></clipPath>'
             f'<clipPath id="cFront"><path d="{d_front}"/></clipPath>'
             # user-space region so a thin beam's glow is not cut to its own bounding box
             '<filter id="beamGlow" filterUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">'
             '<feGaussianBlur stdDeviation="12" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>')

    # The beam enters the front face at the left edge, crosses it, and splits at the
    # corner; the spectrum fans across the side face and stops at the carton's edge.
    beam_in = (FL + 4, 600)
    split = (FR, 540)
    far_a, far_b = (FR + DX, TOP + DY + 10), (FR + DX, TOP + DY + 420)
    n = len(colors)
    bands = ""
    for i, c in enumerate(colors):
        a0, a1 = lerp(far_a, far_b, i / n), lerp(far_a, far_b, (i + 1) / n)
        # each band starts as a sliver at the split point, so the fan opens from one spot
        s0, s1 = (split[0], split[1] - 7 + 14 * i / n), (split[0], split[1] - 7 + 14 * (i + 1) / n)
        far_x = FR + DX + 40
        bands += (f'<polygon points="{s0[0]:.1f},{s0[1]:.1f} {far_x},{a0[1] - 10:.1f} '
                  f'{far_x},{a1[1] - 10:.1f} {s1[0]:.1f},{s1[1]:.1f}" fill="{c}"/>')

    body = ""
    carton = ""
    carton += f'<path d="{d_side}" fill="{fill_side}"/>'
    carton += hatch("cSide", (FR - 10, TOP + DY - 20, FR + DX + 30, BOT + 20), 70, 15, color=hatch_col, seed=seed + 5, opacity=.6)
    carton += hatch("cSide", (FR - 10, TOP + DY - 20, FR + DX + 30, BOT + 20), -20, 17, color=hatch_col, seed=seed + 6, opacity=.5)
    carton += f'<g clip-path="url(#cSide)"><g filter="url(#beamGlow)" opacity=".93">{bands}</g></g>'
    carton += f'<path d="{d_roof}" fill="{fill_side}"/>'
    carton += hatch("cRoof", (rf[0] - 20, rb[1] - 20, FR + DX + 20, TOP + 20), 20, 18, w=3, color=hatch_col2, seed=seed + 7, opacity=.7)
    carton += f'<path d="{d_front}" fill="{fill_front}"/>'
    carton += hatch("cFront", (FL - 30, TOP, FL + 80, BOT), 84, 12, w=2.8, color=hatch_col, seed=seed + 8, opacity=.7)
    carton += hatch("cFront", (FL, BOT - 80, FR, BOT + 20), 8, 11, w=2.6, color=hatch_col, seed=seed + 12, opacity=.55)
    # the beam across the front face, clipped so it never leaves the carton
    carton += (f'<g clip-path="url(#cFront)">'
               f'<line x1="{beam_in[0] - 40}" y1="{beam_in[1] + 6}" x2="{split[0]}" y2="{split[1]}" stroke="#fff" '
               f'stroke-width="17" stroke-linecap="round" filter="url(#beamGlow)"/>'
               f'<line x1="{beam_in[0] - 40}" y1="{beam_in[1] + 6}" x2="{split[0]}" y2="{split[1]}" stroke="{"#fff" if dark else INK}" '
               f'stroke-width="3" stroke-linecap="round" opacity="{.0 if dark else .35}"/></g>')
    carton += f'<path d="{d_gable}" fill="{fill_front}"/>'
    carton += f'<path d="{d_fin}" fill="{fill_side}"/>'
    for d in (d_side, d_roof, d_front, d_gable, d_fin):
        carton += contour(d, w=15, color=line)
    # a flare where the light splits, sitting on the corner line
    carton += f'<circle cx="{split[0]}" cy="{split[1]}" r="15" fill="#fff" filter="url(#beamGlow)"/>'
    carton += (f'<g stroke="{line}" stroke-width="6" stroke-linecap="round" fill="none">'
               f'<path d="M{FL + 44} {TOP + 40} q-8 44 0 100"/></g>')
    carton += f'<g transform="rotate(-5 400 800)">{comix_letters(FL + 62, BOT - 100, 112, fill="#FF8CC6" if dark else "#FFF3DC")}</g>'
    body += carton
    return svg(body, clips)


if __name__ == "__main__":
    out = {"AppIcon-comix": contained_carton(SYNTH), "AppIcon-neon": contained_carton(SYNTH, dark=True)}
    for k, v in out.items():
        open(f"{k}.svg", "w").write(v)
    print(" ".join(out))
