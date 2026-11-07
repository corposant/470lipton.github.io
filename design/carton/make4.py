import math, random, importlib.util, sys
spec = importlib.util.spec_from_file_location("m", "make.py"); m = importlib.util.module_from_spec(spec)
sys.argv = ["x"]; spec.loader.exec_module(m)
SYNTH, RAINBOW, grid, nog_letters, DEFS = m.SYNTH, m.RAINBOW, m.grid, m.nog_letters, m.DEFS
INK = "#0A0908"

def svg(body, extra=""):
    defs = DEFS.replace("</defs>", extra + """
 <linearGradient id="paper" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FBF3E0"/><stop offset="1" stop-color="#E9DCC0"/></linearGradient>
 <linearGradient id="paperSide" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#E2D3B4"/><stop offset="1" stop-color="#CDBB98"/></linearGradient>
 <linearGradient id="darkFront" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#3a3b4a"/><stop offset="1" stop-color="#22232d"/></linearGradient>
 <linearGradient id="darkSide" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#22232e"/><stop offset="1" stop-color="#121219"/></linearGradient>
</defs>""")
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">{defs}<rect width="1024" height="1024" fill="url(#bg)"/>{body}</svg>'

def bulgy(points, bulges, seed=1, jit=2.5):
    """Closed path whose edges bow outward by `bulges[i]` (px), with a slight hand wobble."""
    rnd = random.Random(seed); n = len(points)
    cx = sum(p[0] for p in points) / n; cy = sum(p[1] for p in points) / n
    d = f"M{points[0][0]:.1f} {points[0][1]:.1f} "
    for i in range(n):
        (x0, y0), (x1, y1) = points[i], points[(i + 1) % n]
        mx, my = (x0 + x1) / 2, (y0 + y1) / 2
        L = math.hypot(x1 - x0, y1 - y0) or 1
        nx, ny = -(y1 - y0) / L, (x1 - x0) / L
        if (mx + nx - cx) ** 2 + (my + ny - cy) ** 2 < (mx - cx) ** 2 + (my - cy) ** 2: nx, ny = -nx, -ny
        b = bulges[i]
        qx, qy = mx + nx * b * 2 + rnd.uniform(-jit, jit), my + ny * b * 2 + rnd.uniform(-jit, jit)
        d += f"Q{qx:.1f} {qy:.1f} {x1:.1f} {y1:.1f} "
    return d + "Z"

def contour(d, w=13, color=INK):
    """Brushy ink line: a heavy stroke with a thinner offset echo, like a dip pen pressing."""
    return (f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{w}" stroke-linejoin="round" stroke-linecap="round"/>'
            f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{w*0.45:.1f}" stroke-linejoin="round" '
            f'stroke-linecap="round" transform="translate(2.5 2)" opacity=".85"/>')

def hatch(clip_id, box, angle, spacing, w=3.2, color=INK, seed=5, gap=0.12, opacity=1.0):
    """Hand hatching: parallel, slightly uneven strokes across `box`, clipped to `clip_id`."""
    rnd = random.Random(seed)
    x0, y0, x1, y1 = box
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    a = math.radians(angle); ux, uy = math.cos(a), math.sin(a); vx, vy = -uy, ux
    hw, hh = (x1 - x0) / 2, (y1 - y0) / 2
    # Cover just the box: offsets across it, line lengths along it.
    across = abs(vx) * hw + abs(vy) * hh
    R = abs(ux) * hw + abs(uy) * hh + 10
    lines = []
    k = -across
    while k < across:
        off = k + rnd.uniform(-spacing * 0.18, spacing * 0.18)
        px, py = cx + vx * off, cy + vy * off
        s = -R + rnd.uniform(0, R * gap); e = R - rnd.uniform(0, R * gap)
        wob = rnd.uniform(-2, 2)
        lines.append(f'<path d="M{px + ux*s:.1f} {py + uy*s:.1f} Q{px + vx*wob:.1f} {py + vy*wob:.1f} {px + ux*e:.1f} {py + uy*e:.1f}"/>')
        k += spacing
    return (f'<g clip-path="url(#{clip_id})" stroke="{color}" stroke-width="{w}" stroke-linecap="round" fill="none" opacity="{opacity}">'
            + "".join(lines) + '</g>')

def comix_letters(x, y, h, fill="#FFF3DC", ink=INK):
    """Fat, outlined hand lettering: the NOG strokes inked thick, then filled in."""
    g = nog_letters(x, y, h, stroke="X", w=1).replace(' filter="url(#soft)"', '')
    thick = g.replace('stroke="X"', f'stroke="{ink}"').replace('stroke-width="1"', f'stroke-width="{h*0.42:.1f}"')
    inner = g.replace('stroke="X"', f'stroke="{fill}"').replace('stroke-width="1"', f'stroke-width="{h*0.22:.1f}"')
    shadow = thick.replace('<g ', '<g transform="translate(7 7)" opacity=".9" ', 1)
    return shadow + thick + inner

def blast_fan(a, b, far_top, far_bottom, colors, x_far=1120):
    n = len(colors); out = []
    for i, c in enumerate(colors):
        t0, t1 = i / n, (i + 1) / n
        ax, ay = a[0] + (b[0]-a[0]) * t0, a[1] + (b[1]-a[1]) * t0
        bx, by = a[0] + (b[0]-a[0]) * t1, a[1] + (b[1]-a[1]) * t1
        f0 = far_top + (far_bottom - far_top) * t0; f1 = far_top + (far_bottom - far_top) * t1
        out.append(f'<polygon points="{ax:.1f},{ay:.1f} {x_far},{f0:.1f} {x_far},{f1:.1f} {bx:.1f},{by:.1f}" fill="{c}"/>')
    return '<g filter="url(#glow)" opacity=".96">' + "".join(out) + '</g>'

def comix_carton(colors, dark=False, letters=True, scale=1.0, seed=11):
    FL, FR, TOP, BOT, DX, DY = 250, 590, 450, 905, 150, -50
    gable, fin = 140, 46
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

    d_front = bulgy(front, [-22, 6, 0, 5], seed)       # left edge bows out, bottom sags
    d_side = bulgy(side, [4, 18, 10, 0], seed + 1)
    d_gable = bulgy(gable_tri, [5, 5, 0], seed + 2)
    d_roof = bulgy(roof, [3, 4, 6, 0], seed + 3)
    d_fin = bulgy(fin_poly, [2, 3, 2, 0], seed + 4)
    clips = (f'<clipPath id="cSide"><path d="{d_side}"/></clipPath><clipPath id="cRoof"><path d="{d_roof}"/></clipPath>'
             f'<clipPath id="cFront"><path d="{d_front}"/></clipPath><clipPath id="cShadow"><ellipse cx="520" cy="922" rx="300" ry="34"/></clipPath>')

    body = grid()
    beam_in = (FL - 6, 640)
    body += f'<line x1="-30" y1="810" x2="{beam_in[0]}" y2="{beam_in[1]}" stroke="#fff" stroke-width="11" stroke-linecap="round" filter="url(#glow)"/>'
    ea, eb = (FR + DX + 14, 440), (FR + DX + 14, 540)
    body += blast_fan(ea, eb, -150, 480, colors)
    # cross-hatched cast shadow on the floor
    body += hatch("cShadow", (200, 880, 840, 960), 35, 9, w=2.6, color=INK if not dark else "#000", seed=seed + 9)
    body += hatch("cShadow", (200, 880, 840, 960), -35, 11, w=2.2, color=INK if not dark else "#000", seed=seed + 10, opacity=.8)
    carton = ""
    carton += f'<path d="{d_side}" fill="{fill_side}"/>'
    carton += hatch("cSide", (FR - 10, TOP + DY - 20, FR + DX + 30, BOT + 20), 70, 13, color=hatch_col, seed=seed + 5, opacity=.85)
    carton += hatch("cSide", (FR - 10, TOP + DY + 160, FR + DX + 30, BOT + 20), -20, 15, color=hatch_col, seed=seed + 6, opacity=.75)
    carton += f'<path d="{d_roof}" fill="{fill_side}"/>'
    carton += hatch("cRoof", (rf[0] - 20, rb[1] - 20, FR + DX + 20, TOP + 20), 20, 16, w=2.8, color=hatch_col2, seed=seed + 7, opacity=.7)
    carton += f'<path d="{d_front}" fill="{fill_front}"/>'
    # contour hatching down the bulging left side and along the sagging bottom
    carton += hatch("cFront", (FL - 30, TOP, FL + 70, BOT), 84, 11, w=2.6, color=hatch_col, seed=seed + 8, opacity=.75)
    carton += hatch("cFront", (FL, BOT - 70, FR, BOT + 20), 8, 10, w=2.4, color=hatch_col, seed=seed + 12, opacity=.6)
    carton += f'<path d="{d_gable}" fill="{fill_front}"/>'
    carton += f'<path d="{d_fin}" fill="{fill_side}"/>'
    for d in (d_side, d_roof, d_front, d_gable, d_fin):
        carton += contour(d, w=12, color=line)
    # dents and creases, a few shine ticks (emanata)
    carton += (f'<g stroke="{line}" stroke-width="5" stroke-linecap="round" fill="none">'
               f'<path d="M{FR + 40} {TOP + 120} q18 30 6 70"/>'
               f'<path d="M{FL + 40} {TOP + 30} q-8 40 0 90"/></g>')
    shine = "#fff" if dark else INK
    carton += (f'<g stroke="{shine}" stroke-width="6" stroke-linecap="round" opacity=".9">'
               f'<line x1="{FL - 60}" y1="{TOP - 40}" x2="{FL - 30}" y2="{TOP - 20}"/>'
               f'<line x1="{FL - 70}" y1="{TOP + 10}" x2="{FL - 34}" y2="{TOP + 14}"/>'
               f'<line x1="{FL - 40}" y1="{TOP - 86}" x2="{FL - 18}" y2="{TOP - 58}"/></g>')
    if letters:
        carton += f'<g transform="rotate(-5 420 760)">{comix_letters(FL + 60, BOT - 90, 86, fill="#FF8CC6" if dark else "#FFF3DC")}</g>'
    body += carton
    body += f'<line x1="{beam_in[0]}" y1="{beam_in[1]}" x2="{FR + DX}" y2="{(ea[1]+eb[1])/2}" stroke="#fff" stroke-width="7" stroke-linecap="round" opacity=".55" filter="url(#glow)"/>'
    if scale != 1.0:
        body = f'<g transform="translate(500 560) scale({scale}) translate(-500 -560)">{body}</g>'
    return svg(body, clips)

out = {"G-comix-synthwave": comix_carton(SYNTH), "G-comix-spectrum": comix_carton(RAINBOW),
       "H-comix-dark": comix_carton(SYNTH, dark=True), "I-comix-bold": comix_carton(SYNTH, letters=False, scale=1.16)}
for k, v in out.items(): open(f"{k}.svg", "w").write(v)
print(" ".join(out))
