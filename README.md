# Nog

A capture-first iPhone app where **every item can nog you, repeatedly, until it's done.**

- **Everything is an Item.** To-dos, ideas, concepts and projects are all the same thing. Any item can have notes, `[[links]]` to other items, backlinks, tags, and sub-nogs (an item with sub-nogs *is* a project).
- **Capture is instant.** The app opens with the keyboard already up. Type, hit return, and keep typing.
- **Every capture gets a default nog** (out of the box: first nog 15 min after capture, then every 8 min until done). You can change that in Settings, or per item.
- **Nogs repeat forever.** They don't stop after one or two. Each nog has **Done ✓ / Snooze 1 hour / Tomorrow morning** buttons right on the notification. With quiet hours, a timed silence or alarms in play, iOS only lets Nog line up the next few hours of nogs at a time; if you don't open Nog before they run out, one last notification asks you to, so they never just stop.
- **"Hey Siri, take a Nog"** captures something hands-free (Siri asks what). Settings → Siri & Shortcuts lists every phrase.
- **Syncs through iCloud Drive.** Each item is a plain Markdown file in *iCloud Drive → Nog → Items*, readable on your Mac too. If iCloud isn't available, files stay on the phone and move to iCloud automatically once it is.

## Plain English

Type the way you'd say it and Nog works out the when:

| You type | Becomes |
|---|---|
| `lunch next Tues` | **Lunch**, Tuesday 12:00 |
| `call mom tomorrow at 3` | **Call mom**, tomorrow 3 PM |
| `dentist nov 12 at 2:30pm` | **Dentist**, Nov 12 2:30 PM |
| `dinner with Sam on sat` | **Dinner with Sam**, Saturday 6:30 PM |
| `standup tomorrow morning` | **Standup**, tomorrow 9 AM |
| `submit report by eod` | **Submit report**, today 5 PM |
| `stretch in 20 min` | **Stretch**, 20 minutes from now |
| `take pills every 4 hours` | **Take pills**, nogs every 4 hours |

As you type, a line above the capture field shows how Nog understood it. A day with no time defaults to 9 AM, and meal words set sensible times (lunch at noon, dinner at 6:30).

## Look & settings

- **Theme: "Dark Side".** A charcoal base with frosted glass panels and synthwave pink/blue accents. Blue means live, pink means nogging, violet sits in between. Buttons are outlined, never filled. Pick **Auto / Dark / Light** in the Control Panel.
- **Typography: fonts built into iOS**, so nothing to license or bundle. **Futura** for titles and labels (geometric, mid-century), SF Pro for text, **SF Mono** for timers and readouts.
- **Text size and contrast.** Every font follows the iPhone's text size (Settings → Accessibility → Display & Text Size → Larger Text), and rows, chips and buttons stack instead of cutting text off at the largest sizes. Text colours meet WCAG AA contrast (4.5:1) in Light and Dark. **Increase Contrast** switches to stronger colours and a plain background, and **Reduce Transparency** drops the haze and grid. `NogTests/AccessibilityTests.swift` checks the contrast ratios.
- **Calm** (Control Panel): **Low stimulation** turns off glows, the background haze and grid, motion and vibration in one switch, and **Vibration** turns off just the haptics. Nog also follows the iOS **Reduce Motion** setting: no springs or slides, and panels fade in instead of moving.
- **Two app icons**, both a nog carton with the light-and-spectrum motif: Comix (inked and cross-hatched on cream) and Neon (neon-hatched on charcoal), switchable in the Control Panel. Sources and the generator are in `design/carton/` (`python3 make4.py`, then `node render.js <name>`).
- **Nogs & alerts** (Control Panel): defaults for new captures, **quiet hours** (optionally all weekend), a **heads-up** before dated nogs, **ring as an alarm after N ignored nogs**, snooze length, what "morning" means, Time Sensitive, sound, **hide titles on the Lock Screen**, and an app icon badge. **Nogitivity**: default timebox, how often "time's up" repeats, the open-ended check-in, and the Live Activity on/off.
- **Control Panel** (gear icon): appearance, app icon, **storage (iCloud Drive or on this iPhone)**, nog defaults, Doing timebox, capture shortcuts, alerts & permissions, and Siri phrases.

## iOS 27 features

- **Siri speaks Nog natively.** Nog adopts iOS 27's new Reminders App Schemas (`createReminder`, `updateReminder`, `deleteReminders`, `createList`). Try *"Remind me in Nog to call mom tomorrow at 3"*, *"Add milk to my Groceries list in Nog"*, *"Mark this as done"* and *"Set the due date for this to Friday"*. Any item with sub-nogs works as a list.
- **"Siri, mark that done."** Nog notifications, list rows and item screens are tagged with their item (iOS 27 entity annotations), so Siri knows what "this" or "that" means.
- **Spotlight's semantic index.** Items are indexed so Siri and Spotlight can find them by meaning, not just exact words.
- **Ring like an alarm.** Flip it on per item, or type `!alarm`, and that item's nogs become real AlarmKit alarms. They break through Silent mode and Focus, take over the Lock Screen and your Watch, with **Stop** (silence this ring; nogs continue) and **Done** (finish the item). Regular nogs take over again after the scheduled alarms run out.
- **Break it down.** On-device Apple Intelligence (Foundation Models) suggests 3–7 concrete first steps for any item, and you pick which ones become sub-nogs. It runs only on Apple Intelligence devices, and nothing leaves the phone.

## Four tabs

Each tab has its own colour (New Nog pink, Agenda violet, List blue, Map teal), used for its title, its buttons and a soft haze in the background. The colour is only a hint: every tab is also named in its title and on the tab bar. Titles are Futura and grow with your text size.

- **New Nog** (where Nog opens): one text box for the thought, with its options in a tray on the keyboard.
- **Agenda**: only what has a time, from now through the coming week.
- **List**: everything, in two views you switch between at the top.
  - **By time:** the full overview, with the sections below.
  - **Outline:** each folder is a collapsible section, sub-folders collapse inside it, and anything not connected sits under **Unfiled**. What you've collapsed is remembered. The ✓ button shows or hides finished items.
- **Map**: see your data as a mind map.
  Every item is a node. **Tap a node to select it**: it lights up and its details slide up from the bottom; tap it again to open it. **Only a selected node can be dragged** (a drag anywhere else pans), so nothing moves by accident. To file it, hold it over another node until that one glows, then let go. Every move and filing shows an Undo, and VoiceOver users get Move, File into… and Take out actions on each node. A node with things connected under it *is* a folder, shown with a folder icon. Long-press a node to take it out of its folder, open it, or start it. Solid lines show what's filed where; dashed lines show `[[links]]`. Each #tag gets a coloured zone. Tap the wand to **tidy up**: overlaps go, stray sub-nogs come back to their folder, and anything you placed by hand stays put. Touch and hold the wand for whole-page layouts: Stars, Mind map, By tag or Web. Chips flock to their new spots (or simply appear there with Reduce Motion or Low stimulation), and Undo puts everything back. Tap ✏︎ to scribble with finger or Pencil. Positions and scribbles are saved in `_nogmap.json` next to your items, so they sync too.

## The list

| Section | What's in it |
|---|---|
| **Nogitivity** | what you've hit ▶︎ on, with its live timer |
| **Nogging now** | reminders firing right now |
| **Later today** | nogs that start later today |
| **Nogs next** | tomorrow and beyond |
| **Loose nogs** | no reminder: ideas, concepts, notes |
| **Dream nogs** | someday / maybe |
| **Done** | finished, kept for reference |

## ▶︎ Doing a nog (Nogitivity)

Every nog has a play button. Tap it and the nog becomes **Doing**, the thing you're working on right now:

- **A live timer on your Lock Screen and in the Dynamic Island** (plus StandBy, Apple Watch and CarPlay), with **Done / +10 min / Stop** buttons.
- **A timebox Nog picks for you**, in this order: your estimate for the item (`~30m` when capturing, or set it on the item), how long similar items took you before (same #tag, or other steps in the same project), a short start if it's urgent (15 min) or has been waiting over a day (10 min), and otherwise your default (25 min). Hold the button to choose another length or no timer (counts up).
- **While you're doing it, the usual nogs pause.** When the timebox ends, Nog nogs "Time's up. Done, or 10 more minutes?" every 5 minutes. Alarm items ring. Open-ended sessions get an hourly "Still on it?".
- **Finishing keeps the item.** Done items stay with their notes, sub-nogs and the time you spent ("took 40 min"). That history makes future timeboxes smarter. **Stop** puts it back to Open and keeps the time.
- **Siri:** *"Start write report in Nog."*

### Nogitivity widgets

Add **Nogitivity** to your Home Screen (small, medium or large) or Lock Screen (circle, rectangle or the line above the clock).

- **Nothing on:** most of the widget is for acting. The nog that matters most right now sits up front with big **▶︎ Start** (showing the timebox Nog would pick) and **✓ Done** buttons, plus **Later** on the large size. **+ Take a Nog** opens New Nog. The rest of the widget lists what else is about now, each with a **▶︎** (and **✓** on the large size). Buttons work without opening the app; tap a title to open it. When nothing is due, it says you're clear and offers **Take a Nog**.
- **While you're doing something:** it turns into the timer, with **✓ Done / +10 min / Stop**. The medium size adds a timebox bar, and the large one shows the item's sub-nogs and what's up next.
- **Lock Screen:** a ring that fills as the timebox runs (or how many are nogging), the timer with "of 25", or the next nog. Titles hide when **Show titles on Lock Screen** is off.
- **Press and hold › Edit Widget** to choose what it offers: one or more **Lists** (**Now**, the default: nogging now plus the rest of today; or Nogging now, Today, Agenda, Loose nogs, Dream nogs), **Only #tag**, or **Pick nogs** one by one from everything outstanding. **Show the timer while I'm doing something** can be switched off for a pure list.

The widgets read a small summary the app writes to a shared App Group whenever your nogs change, so open Nog once after installing.

## Nog profiles

A nagging style in one tap. Pick your default in Control Panel → Nogs & alerts, switch any item on its page, or type the token when capturing.

| Profile | Token | First nog | Then | Rings as an alarm |
|---|---|---|---|---|
| **Whisper** | `!whisper` | after 1 hr | hourly, easing off to daily | never |
| **Steady** | (default) | after 15 min | every 8 min | per global setting |
| **Easing** | `!easing` | after 8 min | 8 → 16 → 32 min… up to daily | per global setting |
| **Unhinged** | `!unhinged` | after 2 min | every 7 min, no let-up | after 3 ignored nogs |

Fine-tune anything and the item becomes **Custom**.

## Steady or logarithmic

Each reminder has a style:

- **Steady**: the same gap every time, e.g. every 8 min until done.
- **Logarithmic**: urgent at first, then easing off. The gap doubles after each nog (8 min, 16, 32, 1 h, 2 h…) until it reaches a day, then Nog nogs daily until it's done. It never goes quiet.

Pick the default in Settings, change it per item, or type `!log` / `!steady` when capturing.

## Capture shortcuts

Type these anywhere in a capture line (all optional):

| Token | Meaning |
|---|---|
| `!8m` `!2h` `!1d` | repeat every 8 min / 2 hours / 1 day |
| `!once` | remind once, don't repeat |
| `!log` | logarithmic: the gap doubles after each nog |
| `!steady` | same gap every time |
| `!alarm` | ring like a real alarm |
| `!whisper` `!easing` `!unhinged` | use a nog profile; the first three letters are enough (`!unh`) |
| `~30m` `~2h` | how long it'll take (the ▶︎ timebox) |
| `!off` or `!idea` | no reminder |
| `@30m` `@2h` `@1d` `@now` | when to start nogging |
| `#tag` | add a tag |

Start typing a `!` word and the tray offers to finish it: tap a suggestion, or press Tab on a keyboard.

Example: `renew passport #admin !1h @2h`

## Running it on your iPhone

Nog targets **iOS 27**, so you need **Xcode 27** on your Mac, plus Homebrew. The iOS 27 features are below.

```bash
brew install xcodegen
git clone https://github.com/corposant/470lipton.github.io.git Nog
cd Nog
xcodegen            # generates Nog.xcodeproj from project.yml
open Nog.xcodeproj
```

In Xcode:

1. Click the **Nog** project → **Nog** target → **Signing & Capabilities** and pick your **Team**.
   If it says the bundle identifier is unavailable, change `NOG_BUNDLE_ID` at the top of `project.yml` (one line; the widget follows) and run `./update.sh`.
   To avoid re-picking the team after each `xcodegen`, paste your Team ID into `DEVELOPMENT_TEAM` in `project.yml`.
2. Plug in your iPhone (or use Wi-Fi pairing) and select it as the run destination.
3. On the iPhone, the first time: **Settings → Privacy & Security → Developer Mode → On** (it restarts).
4. Press **⌘R**. Allow notifications when asked.

Run the tests with **⌘U**.

**Getting updates:** run `./update.sh` in the Nog folder. It pulls the latest code and re-runs `xcodegen`, which you need whenever new files are added. If Xcode asks, choose **Read From Disk**.

**Free developer account (current setup):** iCloud sync is switched off in `project.yml`, so items live on the phone (Files → On My iPhone → Nog). Everything else works: notifications, AlarmKit alarms, Live Activities, Siri, widgets, and on-device Apple Intelligence. Two limits of a free account: the app stops opening after **7 days** (just press ⌘R again; your data stays), and you can have at most 3 sideloaded apps. **When you go paid**, uncomment the `entitlements:` block in `project.yml` and run `xcodegen`. Nog moves your items into iCloud Drive on its next launch. If you change the bundle identifier, change the container ID to match (`iCloud.<your bundle id>`).

**Widgets and the App Group:** the Nogitivity widgets share data with the app through an App Group (`group.<your bundle id>`), which `project.yml` adds to both targets. Xcode's automatic signing registers it on the first build with a paid account. If your team can't use App Groups, delete the two `com.apple.security.application-groups` entitlements in `project.yml` and re-run `xcodegen`: everything else still works, and the widgets just say "Open Nog once".

**Free vs paid developer account:** with a free (personal team) account the app stops opening after **7 days** and you have to press ⌘R again. With the paid program ($99/yr) it lasts a year and you can use TestFlight. To check which you have, go to developer.apple.com/account. If you see a **Membership** section with a renewal date, you're on the paid program.

### Optional: Time Sensitive notifications

These let nogs break through Focus modes. In **Signing & Capabilities → + Capability → Time Sensitive Notifications**. Then on the phone: **Settings → Notifications → Nog → Time Sensitive → On**. The code already marks nogs as time-sensitive.

## How the repeating nogs work

iOS lets an app have at most 64 notifications scheduled at once, so `NogPlanner` budgets them:

- An item that's **already nogging** gets one *repeating* trigger, which iOS fires every N minutes forever, even if the app is never opened again.
- An item whose nog **starts later** gets a one-shot at the start time plus follow-ups while there's room. Whenever the app gets a chance to run (you open it, tap a notification button, or iOS grants a background refresh), the plan is recomputed and started items switch to the forever-repeating trigger.

## Project layout

```
project.yml                 XcodeGen spec (the .xcodeproj is generated, not committed)
Nog/App                     App entry, notification delegate, background refresh
Nog/Model                   Item, Markdown file format, capture parser, nog planner
Nog/Store                   ItemStore (in-memory + Markdown files), Router
Nog/Notifications           Sync between the plan and iOS's notification center
Nog/Intents                 Siri / Shortcuts / Action Button capture
Nog/Views                   SwiftUI screens
NogWidgets                  Live Activity for ▶︎ Doing and the Nogitivity widgets (widget extension)
Shared                      Code compiled into both the app and NogWidgets
NogTests                    Unit tests for the model and planner
design/AppIcon.svg          Source for the app icon
```

## History

This repository used to host the 470 Lipton Street listing site. That site is archived, untouched, on the `archive/470lipton-site` branch.
