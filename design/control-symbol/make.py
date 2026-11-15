from shapely.geometry import LineString, LinearRing, Polygon, MultiPolygon
from shapely.geometry.polygon import orient
from shapely.ops import unary_union
import sys
W=1.75  # stroke in the 25-unit carton drawing
outer=[(4.5,22.6),(4.5,11.2),(9.2,6.4),(9.2,3.9),(15.6,2.3),(15.6,4.8),(20.6,9.6),(20.6,20.9),(14,22.6)]
lines=[[(4.5,11.2),(14,11.2),(14,22.6)],[(9.2,6.4),(14,11.2),(20.6,9.6)],[(9.2,6.4),(15.6,4.8)]]
geoms=[LinearRing(outer).buffer(W/2,join_style=1,cap_style=1,quad_segs=8)]
geoms+=[LineString(l).buffer(W/2,join_style=1,cap_style=1,quad_segs=8) for l in lines]
u=unary_union(geoms)
minx,miny,maxx,maxy=u.bounds
H=88.0; s=H/(maxy-miny)
# baseline-relative: bottom at y=+8.8, top at -79.2; x from 0
def T(x,y): return ((x-minx)*s, 8.8-(maxy-y)*s - 0) if False else ((x-minx)*s, -79.2+(y-miny)*s)
polys=list(u.geoms) if isinstance(u,MultiPolygon) else [u]
def ring(coords):
    pts=[T(x,y) for x,y in coords[:-1]]
    return "M"+" L".join(f"{x:.2f} {y:.2f}" for x,y in pts)+" Z"
d=""
for p in polys:
    p=orient(p,1.0)
    d+=ring(list(p.exterior.coords))
    for h in p.interiors: d+=ring(list(h.coords))
width=(maxx-minx)*s
pad=3.0  # side bearings
# Xcode reads a v3 template by its text id "template-version", and builds every weight
# and scale by interpolating Ultralight-S, Regular-S and Black-S. The three are the
# same outline (same points), so every weight draws this carton; Regular-M is the
# hand-checked size. S glyphs are drawn a little smaller, as in Apple's symbols.
GUIDE='style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;"'
MARGIN='style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;"'
variants=[("Ultralight-S",560.0,696,0.8),("Regular-S",1390.0,696,0.8),("Black-S",2220.0,696,0.8),
          ("Regular-M",1390.0,1126,1.0)]
guides=""; symbols=""
for name,L,base,k in variants:
    R=L+(width+2*pad)*k
    guides+=(f'  <line id="left-margin-{name}" {MARGIN} x1="{L:.2f}" x2="{L:.2f}" y1="{base-95.21:.2f}" y2="{base+24.12:.2f}"/>\n'
             f'  <line id="right-margin-{name}" {MARGIN} x1="{R:.2f}" x2="{R:.2f}" y1="{base-95.21:.2f}" y2="{base+24.12:.2f}"/>\n')
    symbols+=(f'  <g id="{name}" transform="matrix({k} 0 0 {k} {L+pad*k:.2f} {base})">\n'
              f'   <path d="{d}"/>\n  </g>\n')
lines="".join(f'  <line id="{n}" {GUIDE} x1="263" x2="3036" y1="{y}" y2="{y}"/>\n' for n,y in
              [("Baseline-S",696),("Capline-S",625.541),("Baseline-M",1126),("Capline-M",1055.54),("Baseline-L",1556),("Capline-L",1485.54)])
tmpl=f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<!--Generator: design/control-symbol/make.py (outlined from NogWidgets Carton.imageset)-->
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
 <g id="Notes">
  <rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>
  <text style="stroke:none;fill:black;font-family:sans-serif;font-size:13;" transform="matrix(1 0 0 1 263 322)">Weight/Scale Variations</text>
  <text id="template-version" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1933)">Template v.3.0</text>
  <text style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1951)">Requires Xcode 13 or greater</text>
  <text id="descriptive-name" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1969)">Generated from nog.carton</text>
 </g>
 <g id="Guides">
{lines}{guides} </g>
 <g id="Symbols">
{symbols} </g>
</svg>
'''
open(sys.argv[1],'w').write(tmpl)
# plain preview svg in a 100x100 box
pv=f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{-pad} -85 {width+2*pad} 100"><path fill="currentColor" d="{d}"/></svg>'
open(sys.argv[2],'w').write(pv)
print(width, len(polys), [len(p.interiors) for p in polys])
