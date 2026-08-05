# 470 Lipton Street

Single-property listing site for 470 Lipton Street, Winnipeg, Manitoba.

**Live at [470lipton.com](https://470lipton.com)**

Static HTML — no build step, no dependencies. `index.html` contains the markup, styles, and scripts; `photos/` holds the images; `floorplan.pdf` is the downloadable floor plan.

## Local preview

Double-click `preview.command`, or:

```bash
python3 -m http.server
```

Then open <http://localhost:8000>. Serve it over http rather than opening the file directly — YouTube won't play embedded video from a `file://` address.

## Deploying

Published with GitHub Pages from `main`. Push to update:

```bash
git add -A && git commit -m "what changed" && git push
```

---

Listing represented by Annika Pineau · [annikapineau.com](https://annikapineau.com)

Photographs marked *Virtually Staged* have been digitally furnished; those furnishings are not present in the home and are not included in the sale.
