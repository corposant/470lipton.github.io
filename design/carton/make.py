import math, sys
SYNTH = ["#FF4FA3","#E35CD6","#B26EFF","#7E84FF","#4FA8FF","#3FD3FF"]
RAINBOW = ["#E2506A","#E8894A","#E2C454","#4CC27E","#4596E0","#9070DD"]

DEFS = """<defs>
 <radialGradient id="bg" cx="45%" cy="40%" r="80%"><stop offset="0" stop-color="#2a2b36"/><stop offset=".55" stop-color="#1a1b22"/><stop offset="1" stop-color="#101116"/></radialGradient>
 <linearGradient id="glass" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".26"/><stop offset=".55" stop-color="#fff" stop-opacity=".07"/><stop offset="1" stop-color="#fff" stop-opacity=".16"/></linearGradient>
 <linearGradient id="glassSide" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".12"/><stop offset="1" stop-color="#fff" stop-opacity=".04"/></linearGradient>
 <linearGradient id="rim" x1="0" y1="1" x2="1" y2="0"><stop offset="0" stop-color="#4FB3FF"/><stop offset=".5" stop-color="#E9E6FF"/><stop offset="1" stop-color="#FF5FB0"/></linearGradient>
 <linearGradient id="inner" x1="0" y1="1" x2="1" y2="0"><stop offset="0" stop-color="#fff" stop-opacity=".95"/><stop offset="1" stop-color="#fff" stop-opacity=".55"/></linearGradient>
 <linearGradient id="gridfade" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FF5FB0" stop-opacity="0"/><stop offset=".4" stop-color="#C77DFF" stop-opacity=".45"/><stop offset="1" stop-color="#4FB3FF" stop-opacity=".8"/></linearGradient>
 <filter id="glow" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="13" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
 <filter id="soft" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="6" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
 <clipPath id="below"><rect x="0" y="838" width="1024" height="300"/></clipPath>
</defs>"""

def grid():
    lines = []
    for i in range(8):
        y = 838 + 4.2 * (i + 1) ** 2 * 1.0 + i * 0
        y = [842.2,851.6,865.2,882.3,902.8,926.3,952.8,982.0][i]
        lines.append(f'<line x1="0" y1="{y}" x2="1024" y2="{y}"/>')
    for k in range(-11, 12):
        lines.append(f'<line x1="512" y1="838" x2="{470 + k*170 + 0}" y2="1300"/>')
    return ('<g clip-path="url(#below)" stroke="url(#gridfade)" stroke-width="3" opacity=".6">' + "".join(lines) + '</g>'
            '<line x1="0" y1="838" x2="1024" y2="838" stroke="#C77DFF" stroke-width="3" opacity=".7" filter="url(#soft)"/>')

def fan(origin_a, origin_b, far_top, far_bottom, colors, x_far=1110):
    """Bands from a short exit edge (a→b) out to the right edge, between far_top and far_bottom y."""
    n = len(colors); out = []
    for i, c in enumerate(colors):
        t0, t1 = i / n, (i + 1) / n
        ax = origin_a[0] + (origin_b[0] - origin_a[0]) * t0; ay = origin_a[1] + (origin_b[1] - origin_a[1]) * t0
        bx = origin_a[0] + (origin_b[0] - origin_a[0]) * t1; by = origin_a[1] + (origin_b[1] - origin_a[1]) * t1
        fy0 = far_top + (far_bottom - far_top) * t0; fy1 = far_top + (far_bottom - far_top) * t1
        out.append(f'<polygon points="{ax:.1f},{ay:.1f} {x_far},{fy0:.1f} {x_far},{fy1:.1f} {bx:.1f},{by:.1f}" fill="{c}"/>')
    return '<g filter="url(#glow)" opacity=".95">' + "".join(out) + '</g>'

def nog_letters(x, y, h, stroke="url(#rim)", w=10, skew=0.0):
    """N O G drawn as neon strokes, cap height h, starting at (x, y=baseline)."""
    lw = h * 0.72; gap = h * 0.28
    def P(px, py):  # skew for the side-on face
        return f"{px:.1f},{py + (px - x) * skew:.1f}"
    n0 = x; o0 = n0 + lw + gap; g0 = o0 + lw + gap
    top = y - h
    N = f'<polyline points="{P(n0,y)} {P(n0,top)} {P(n0+lw,y)} {P(n0+lw,top)}"/>'
    cx, cy, r = o0 + lw / 2, y - h / 2, h / 2
    O = f'<ellipse cx="{cx:.1f}" cy="{cy + (cx - x) * skew:.1f}" rx="{lw/2:.1f}" ry="{r:.1f}"/>'
    gx, gy = g0 + lw / 2, y - h / 2
    # G: arc from upper-right round to the right middle, then a bar inwards.
    a1 = math.radians(-40); a2 = math.radians(0)
    sx, sy = gx + lw / 2 * math.cos(a1), gy + r * math.sin(a1)
    ex, ey = gx + lw / 2, gy + r * 0.05
    G = (f'<path d="M{sx:.1f} {sy + (sx - x)*skew:.1f} A{lw/2:.1f} {r:.1f} 0 1 0 {ex:.1f} {ey + (ex - x)*skew:.1f} '
         f'L{gx + lw*0.02:.1f} {ey + (gx - x)*skew:.1f}"/>')
    return (f'<g fill="none" stroke="{stroke}" stroke-width="{w}" stroke-linecap="round" stroke-linejoin="round" '
            f'filter="url(#soft)">{N}{O}{G}</g>')

def svg(body):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">{DEFS}<rect width="1024" height="1024" fill="url(#bg)"/>{body}</svg>'

def carton_34(colors):
    # Front face, side face, gable, fin — a gable-top carton in three-quarter view.
    FL, FR, TOP, BOT = 300, 580, 450, 920       # front face box
    DX, DY = 170, -55                            # depth offset to the back edge
    ridge_f = (440, 330); ridge_b = (ridge_f[0] + DX, ridge_f[1] + DY)
    fin_h = 44
    silhouette = (f"M{FL} {BOT} L{FL} {TOP} L{ridge_f[0]} {ridge_f[1]} L{ridge_f[0]} {ridge_f[1]-fin_h} "
                  f"L{ridge_b[0]} {ridge_b[1]-fin_h} L{FR+DX} {TOP+DY} L{FR+DX} {BOT+DY} L{FR} {BOT} Z")
    side = f"{FR},{TOP} {FR+DX},{TOP+DY} {FR+DX},{BOT+DY} {FR},{BOT}"
    roof = f"{ridge_f[0]},{ridge_f[1]} {ridge_b[0]},{ridge_b[1]} {FR+DX},{TOP+DY} {FR},{TOP}"
    beam_in = (FL, 655)
    exit_a, exit_b = (FR + DX, 470 + DY + 10), (FR + DX, 560 + DY + 10)
    body = grid()
    body += f'<line x1="-20" y1="822" x2="{beam_in[0]}" y2="{beam_in[1]}" stroke="#fff" stroke-width="10" stroke-linecap="round" filter="url(#glow)"/>'
    body += fan(exit_a, exit_b, -140, 470, colors)
    body += f'<path d="{silhouette}" fill="url(#glass)" stroke="url(#rim)" stroke-width="8" stroke-linejoin="round" filter="url(#soft)"/>'
    body += f'<polygon points="{side}" fill="url(#glassSide)"/>'
    body += f'<polygon points="{roof}" fill="#fff" fill-opacity=".06"/>'
    # inner edges
    body += (f'<g stroke="url(#rim)" stroke-width="4" stroke-linejoin="round" fill="none" opacity=".75">'
             f'<polyline points="{FL},{TOP} {FR},{TOP} {FR},{BOT}"/>'
             f'<polyline points="{ridge_f[0]},{ridge_f[1]} {FR},{TOP}"/>'
             f'<polyline points="{ridge_f[0]},{ridge_f[1]} {ridge_b[0]},{ridge_b[1]}"/>'
             f'<polyline points="{ridge_f[0]},{ridge_f[1]-fin_h} {ridge_f[0]},{ridge_f[1]}"/></g>')
    body += nog_letters(FL + 46, 800, 112, w=11)
    body += f'<line x1="{beam_in[0]}" y1="{beam_in[1]}" x2="{(exit_a[0]+exit_b[0])/2}" y2="{(exit_a[1]+exit_b[1])/2}" stroke="url(#inner)" stroke-width="8" stroke-linecap="round" opacity=".5" filter="url(#glow)"/>'
    return svg(body)

def carton_front(colors):
    # Flat, front-on: reads best at small sizes.
    L, R, TOP, BOT = 312, 712, 470, 930
    peak = (512, 300); fin = 46
    sil = (f"M{L} {BOT} L{L} {TOP} L{peak[0]-34} {peak[1]+22} L{peak[0]-34} {peak[1]-fin} L{peak[0]+34} {peak[1]-fin} "
           f"L{peak[0]+34} {peak[1]+22} L{R} {TOP} L{R} {BOT} Z")
    beam_in = (L, 610)
    exit_a, exit_b = (R, 560), (R, 660)
    body = grid()
    body += f'<line x1="-20" y1="790" x2="{beam_in[0]}" y2="{beam_in[1]}" stroke="#fff" stroke-width="10" stroke-linecap="round" filter="url(#glow)"/>'
    body += fan(exit_a, exit_b, 110, 640, colors)
    body += f'<path d="{sil}" fill="url(#glass)" stroke="url(#rim)" stroke-width="8" stroke-linejoin="round" filter="url(#soft)"/>'
    body += (f'<g stroke="url(#rim)" stroke-width="4" fill="none" opacity=".7">'
             f'<line x1="{L}" y1="{TOP}" x2="{R}" y2="{TOP}"/></g>')
    body += f'<line x1="{beam_in[0]}" y1="{beam_in[1]}" x2="{R}" y2="{(exit_a[1]+exit_b[1])/2}" stroke="url(#inner)" stroke-width="8" stroke-linecap="round" opacity=".5" filter="url(#glow)"/>'
    body += nog_letters(L + 62, 860, 120, w=12)
    return svg(body)

def carton_pour(colors):
    # Tilted carton, spout open, pouring the spectrum like nog into the grid.
    body = grid()
    # stream: bands curving from the spout down to the horizon at right
    n = len(colors); bands = ""
    sx, sy = 640, 300
    for i, c in enumerate(colors):
        off = (i - (n - 1) / 2) * 15
        bands += (f'<path d="M{sx + off*0.6:.1f} {sy + off*0.8:.1f} C{820 + off:.1f} {300 + off*0.2:.1f} '
                  f'{900 + off*1.4:.1f} {560:.1f} {880 + off*2.2:.1f} {860:.1f}" stroke="{c}" stroke-width="17" fill="none" stroke-linecap="butt"/>')
    body += f'<g filter="url(#glow)" opacity=".95">{bands}</g>'
    body += f'<line x1="-20" y1="700" x2="252" y2="560" stroke="#fff" stroke-width="10" stroke-linecap="round" filter="url(#glow)"/>'
    # carton, tilted
    L, R, TOP, BOT = 0, 300, 0, 470
    peak = (150, -150); fin = 40
    sil = (f"M{L} {BOT} L{L} {TOP} L{peak[0]-28} {peak[1]+18} L{peak[0]-28} {peak[1]-fin} L{peak[0]+28} {peak[1]-fin} "
           f"L{R} {TOP-40} L{R} {BOT} Z")
    inner = (f'<g stroke="url(#rim)" stroke-width="4" fill="none" opacity=".7"><line x1="{L}" y1="{TOP}" x2="{R}" y2="{TOP}"/></g>')
    body += (f'<g transform="translate(330 440) rotate(-28 150 235)">'
             f'<path d="{sil}" fill="url(#glass)" stroke="url(#rim)" stroke-width="8" stroke-linejoin="round" filter="url(#soft)"/>{inner}'
             f'{nog_letters(L + 46, 400, 92, w=10)}'
             f'<line x1="-20" y1="210" x2="{peak[0]+20}" y2="{peak[1]+10}" stroke="url(#inner)" stroke-width="8" stroke-linecap="round" opacity=".45" filter="url(#glow)"/></g>')
    return svg(body)

designs = {
    "A-carton-synthwave": carton_34(SYNTH),
    "A-carton-spectrum": carton_34(RAINBOW),
    "B-front-synthwave": carton_front(SYNTH),
    "C-pour-synthwave": carton_pour(SYNTH),
}
for name, s in designs.items():
    open(f"{name}.svg", "w").write(s)
print("\n".join(designs))
