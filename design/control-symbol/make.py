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
L=1391.3; R=L+width+2*pad
tmpl=f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<!--Generator: design/control-symbol/make.py (outlined from NogWidgets Carton.imageset)-->
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
 <g id="Notes">
  <text style="stroke:none;fill:black;font-family:sans-serif;font-size:13" x="18" y="98">Template v.3.0</text>
 </g>
 <g id="Guides">
  <line id="Baseline-S" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="696" y2="696"/>
  <line id="Capline-S" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="625.541" y2="625.541"/>
  <line id="Baseline-M" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1126" y2="1126"/>
  <line id="Capline-M" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1055.54" y2="1055.54"/>
  <line id="Baseline-L" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1556" y2="1556"/>
  <line id="Capline-L" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1485.54" y2="1485.54"/>
  <line id="left-margin-Regular-M" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" x1="{L:.2f}" x2="{L:.2f}" y1="1030.79" y2="1150.12"/>
  <line id="right-margin-Regular-M" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" x1="{R:.2f}" x2="{R:.2f}" y1="1030.79" y2="1150.12"/>
 </g>
 <g id="Symbols">
  <g id="Regular-M" transform="matrix(1 0 0 1 {L+pad:.2f} 1126)">
   <path d="{d}"/>
  </g>
 </g>
</svg>
'''
open(sys.argv[1],'w').write(tmpl)
# plain preview svg in a 100x100 box
pv=f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{-pad} -85 {width+2*pad} 100"><path fill="currentColor" d="{d}"/></svg>'
open(sys.argv[2],'w').write(pv)
print(width, len(polys), [len(p.interiors) for p in polys])
