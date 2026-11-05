# Nog

A capture-first iPhone app where **every item can nog you, repeatedly, until it's done.**

- **Everything is an Item.** To-dos, ideas, concepts and projects are all the same thing. Any item can have notes, `[[links]]` to other items, backlinks, tags, and sub-items (an item with sub-items *is* a project).
- **Capture is instant.** The app opens with the keyboard already up. Type, hit return, and keep typing.
- **Every capture gets a default nog** (out of the box: first nog 15 min after capture, then every 8 min until done). You can change that in Settings, or per item.
- **Nogs repeat forever.** They don't stop after one or two. Each nog has **Done ✓ / Snooze 1 hour / Tomorrow morning** buttons right on the notification.
- **"Hey Siri, Nog me"** captures something hands-free (Siri asks what).
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
- **Typography: Apple's own SF family**, so it matches iOS with no licensing or bundled font files. SF Pro for text, **SF Pro Expanded** for titles and section labels, **SF Mono** for timers and readouts.
- **Two app icons**, Synthwave and Spectrum, switchable in the Control Panel. The sources are in `design/`.
- **Nogs & alerts** (Control Panel): defaults for new captures, **quiet hours** (optionally all weekend), a **heads-up** before dated nogs, **ring as an alarm after N ignored nogs**, snooze length, what "morning" means, Time Sensitive, sound, **hide titles on the Lock Screen**, and an app icon badge. **Nogitivity**: default timebox, how often "time's up" repeats, the open-ended check-in, and the Live Activity on/off.
- **Control Panel** (gear icon): appearance, app icon, **storage (iCloud Drive or on this iPhone)**, nog defaults, Doing timebox, capture shortcuts, alerts & permissions, and Siri phrases.

## iOS 27 features

- **Siri speaks Nog natively.** Nog adopts iOS 27's new Reminders App Schemas (`createReminder`, `updateReminder`, `deleteReminders`, `createList`). Try *"Remind me in Nog to call mom tomorrow at 3"*, *"Add milk to my Groceries list in Nog"*, *"Mark this as done"* and *"Set the due date for this to Friday"*. Any item with sub-items works as a list.
- **"Siri, mark that done."** Nog notifications, list rows and item screens are tagged with their item (iOS 27 entity annotations), so Siri knows what "this" or "that" means.
- **Spotlight's semantic index.** Items are indexed so Siri and Spotlight can find them by meaning, not just exact words.
- **Ring like an alarm.** Flip it on per item, or type `!alarm`, and that item's nogs become real AlarmKit alarms. They break through Silent mode and Focus, take over the Lock Screen and your Watch, and have Done / Snooze buttons. Regular nogs take over again after the scheduled alarms run out.
- **Break it down.** On-device Apple Intelligence (Foundation Models) suggests 3–7 concrete first steps for any item, and you pick which ones become sub-items. It runs only on Apple Intelligence devices, and nothing leaves the phone.

## Three tabs

- **Capture** (where Nog opens): one text box. Below it, **Just caught** (your latest captures) and **Next nogs** (the soonest few). Nothing else.
- **Nogs**: the full overview, with the sections below.
- **Map**: see your data. The Map and the Outline are two views of the same structure.
  - **Map mode:** every item is a node. **Drop a node onto another to file it there.** A node with things connected under it *is* a folder, shown with a folder icon. Long-press a node to take it out of its folder, open it, or start it. Solid lines show what's filed where; dashed lines show `[[links]]`. Each #tag gets a coloured zone. Tap ✏︎ to scribble with finger or Pencil. Positions and scribbles are saved in `_nogmap.json` next to your items, so they sync too.
  - **Outline mode:** each folder is a collapsible section, sub-folders collapse inside it, and anything not connected sits under **Unfiled**. What you've collapsed is remembered.

## The list

| Section | What's in it |
|---|---|
| **Nogitivity** | what you've hit ▶︎ on, with its live timer |
| **Nogging now** | reminders firing right now |
| **Later today** | nogs that start later today |
| **Nogs next** | tomorrow and beyond |
| **Loose nogs** | no reminder: ideas, concepts, notes |
| **Dream nogs** | someday / maybe |
| **Nogged** | finished, kept for reference |

## ▶︎ Doing a nog (Nogitivity)

Every nog has a play button. Tap it and the nog becomes **Doing**, the thing you're working on right now:

- **A live timer on your Lock Screen and in the Dynamic Island** (plus StandBy, Apple Watch and CarPlay), with **Done / +10 min / Stop** buttons.
- **A timebox Nog picks for you**, in this order: your estimate for the item (`~30m` when capturing, or set it on the item), how long similar items took you before (same #tag, or other steps in the same project), a short start if it's urgent (15 min) or has been waiting over a day (10 min), and otherwise your default (25 min). Hold the button to choose another length or no timer (counts up).
- **While you're doing it, the usual nogs pause.** When the timebox ends, Nog nogs "Time's up. Done, or 10 more minutes?" every 5 minutes. Alarm items ring. Open-ended sessions get an hourly "Still on it?".
- **Finishing keeps the item.** Done items stay with their notes, sub-items and the time you spent ("took 40 min"). That history makes future timeboxes smarter. **Stop** puts it back to Open and keeps the time.
- **Siri:** *"Start write report in Nog."*

## Nog profiles

A nagging style in one tap. Pick your default in Control Panel → Nogs & alerts, switch any item on its page, or type the token when capturing.

| Profile | Token | First nog | Then | Rings as an alarm |
|---|---|---|---|---|
| **Whisper** | `!whisper` | after 1 hr | hourly, easing off to daily | never |
| **Steady** | (default) | after 15 min | every 8 min | per global setting |
| **Easing** | `!easing` | after 8 min | 8 → 16 → 32 min… up to daily | per global setting |
| **Relentless** | `!relentless` | after 2 min | every 7 min, no let-up | after 3 ignored nogs |

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
| `!whisper` `!easing` `!relentless` | use a nog profile |
| `~30m` `~2h` | how long it'll take (the ▶︎ timebox) |
| `!off` or `!idea` | no reminder |
| `@30m` `@2h` `@1d` `@now` | when to start nogging |
| `#tag` | add a tag |

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
   If it complains the bundle identifier is taken, change it to something like `com.yourname.nog`.
   To avoid re-picking the team after each `xcodegen`, paste your Team ID into `DEVELOPMENT_TEAM` in `project.yml`.
2. Plug in your iPhone (or use Wi-Fi pairing) and select it as the run destination.
3. On the iPhone, the first time: **Settings → Privacy & Security → Developer Mode → On** (it restarts).
4. Press **⌘R**. Allow notifications when asked.

Run the tests with **⌘U**.

**iCloud needs the paid Apple Developer Program.** With automatic signing, Xcode registers the iCloud container `iCloud.io.nogapp.nog` for you. If you change the bundle identifier, change the container ID in `project.yml` to match (`iCloud.<your bundle id>`). On a free account, delete the `entitlements:` block in `project.yml`, re-run `xcodegen`, and Nog stores items on the phone only.

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
NogWidgets                  Live Activity for ▶︎ Doing (widget extension)
Shared                      Code compiled into both the app and NogWidgets
NogTests                    Unit tests for the model and planner
design/AppIcon.svg          Source for the app icon
```

## History

This repository used to host the 470 Lipton Street listing site. That site is archived, untouched, on the `archive/470lipton-site` branch.
