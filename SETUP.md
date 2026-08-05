# 470 Lipton Street — listing site

Live-ready except for 17 blanks. Everything is in `index.html` plus the `photos/` folder — no build step, no dependencies.

```
site/
  index.html        the whole site
  floorplan.pdf     4 pages, linked from the Details section
  photos/           21 images, resized and named
```

## What's done

- **Photos.** 18 gallery images plus hero and quote band, all resized for web (5.9 MB total, lazy-loaded; the page paints in about 600 KB). Chosen and ordered as a walk-through: street → foyer → living → kitchen → stairs → bedrooms → baths → basement → deck → garage → aerial.
- **Stats.** 1912, 1,247 sq ft above grade + 378 finished basement (1,625 total), 3 bed, 2 bath, MLS® 202619473.
- **Room dimensions.** All 15 rooms pulled off the floorplan into a table under Details.
- **Floor plans.** The four dimensioned sheets combined into `floorplan.pdf`, linked from the download button.
- **Form.** Wired to `formspree.io/f/xjybvazp`. It submits in the background and swaps in a thank-you message without leaving the page, has a honeypot field for bots, and subjects every email "470 Lipton — website inquiry". Send yourself a test before launch — Formspree makes you confirm the first submission.
- **Copy.** Written from the photos and floorplan only. Every claim in it is something visible in an image.
- **Video.** The YouTube walkthrough sits between the gallery and the details, as a click-to-play poster. The player isn't downloaded until someone clicks it, so it costs nothing on load and sets no YouTube cookies before then — and it uses the `youtube-nocookie` domain when it does. To swap the video later, change `data-id` on the `#player` button and the "Watch on YouTube" link beside it.

## The 17 blanks

Open `index.html` in a browser — they're highlighted yellow, with a black bar at the bottom counting them down. The bar vanishes on its own when you hit zero.

**Facts I can't see in a photo:**

- Lot size, annual taxes and tax year, heating type, possession date
- Year of the renovation, and any furnace / roof / window / wiring / plumbing updates — there's a slot for this in the feature list. At this price point it's the first thing buyers look for, so it's worth filling in properly.

**Words to write:**

- Neighbourhood headline and paragraph under **Location** — name the area, give real walking distances
- A one-line quote from the sellers in the dark band (or delete that `.band` div)

**Annika's details:**

- Brokerage name (appears three times: agent block, footer, legal disclosure)
- Phone, email, and a two-or-three-sentence bio
- A headshot — save it over `photos/agent.jpg`, portrait crop, roughly 600 × 760

## Three things to check before publishing

**Virtual staging.** Four gallery images are staged — living room, dining, primary bedroom, deck — and they use the photographer's watermarked exports (source photos 08, 12, 28, 40).

One thing to flag: in all four of those originals the photographer's badge runs off the right edge of the frame. It reads "Virtually S…" and never completes the word, at full resolution, in the source files. So the page draws its own **Virtually Staged** label on each of those four photos, on the video poster, and in the lightbox when you enlarge one — plus the text disclosure under the gallery. The disclosure holds whether or not the badge is legible. Worth asking VicVision to re-export with the badge fully inside the frame; if they do, drop the new files in over `photos/04.jpg`, `06.jpg`, `10.jpg`, `16.jpg` and nothing else needs to change.

**Bed and bath count.** I read 3 bedrooms and 2 full baths off the floorplan, and described the small 7'1" × 7'9" room upstairs as a flex room rather than a fourth bedroom. Worth confirming that matches the MLS® listing so the two don't disagree.

**Disclosure wording.** The footer legal text is a reasonable starting point, not legal advice. Annika's brokerage will have its own required language and logo policy for single-property sites — paste theirs over it.

## Going live at 470lipton.com

1. Delete the `PLACEHOLDER GUARD` script block near the bottom of `index.html` (it's clearly marked), and confirm the yellow highlights are gone.
2. Drag the `site` folder onto [netlify.com/drop](https://app.netlify.com/drop). Live URL in about ten seconds, free.
3. **Domain settings → Add custom domain → `470lipton.com`**, then point the domain's nameservers at Netlify. HTTPS is automatic.

## Adjusting things

**Colours** — three lines at the top of the `<style>` block drive the whole palette:

```css
--ink:#14140f;    /* text and dark surfaces */
--bone:#f6f4ef;   /* background */
--brass:#9a8355;  /* accent */
```

**Gallery** — copy or delete a `<figure>` line. The classes set the mosaic rhythm: `g-wide` spans 4 of 6 columns at 16:9, `g-half` spans 3, `g-nar` and `g-third` span 2. The lightbox and its counter pick up new images automatically.

**More photos** — there are 48 originals in `470-Lipton-St`. To add one, resize to about 1600px on the long edge and drop it in `photos/`.

**Video poster** — `photos/video-poster.jpg`, cropped 16:9 from the staged living room shot. Replace the file to change it; no code change needed.
