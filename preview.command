#!/bin/bash
# Double-click this file to preview the site properly.
#
# Opening index.html straight from Finder uses a file:// address, and YouTube
# refuses to play embedded video from file:// — that's the "Error 153" you saw.
# This serves the folder over http instead, which is how it will behave live.
#
# Leave this Terminal window open while you're looking at the site.
# Press Ctrl-C, or just close the window, when you're done.

cd "$(dirname "$0")" || exit 1

PORT=8000
while lsof -i :$PORT >/dev/null 2>&1; do PORT=$((PORT+1)); done

echo ""
echo "  470 Lipton — local preview"
echo "  http://localhost:$PORT"
echo ""
echo "  Press Ctrl-C to stop."
echo ""

(sleep 1 && open "http://localhost:$PORT") &
exec python3 -m http.server "$PORT"
