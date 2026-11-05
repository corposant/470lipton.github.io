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

## Capture shortcuts

Type these anywhere in a capture line (all optional):

| Token | Meaning |
|---|---|
| `!8m` `!2h` `!1d` | repeat every 8 min / 2 hours / 1 day |
| `!once` | remind once, don't repeat |
| `!off` or `!idea` | no reminder |
| `@30m` `@2h` `@1d` `@now` | when to start nogging |
| `#tag` | add a tag |

Example: `renew passport #admin !1h @2h`

## Running it on your iPhone

You need a Mac with Xcode (16 or newer) and Homebrew.

```bash
brew install xcodegen
git clone https://github.com/corposant/470lipton.github.io.git Nog
cd Nog
git checkout app
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
NogTests                    Unit tests for the model and planner
design/AppIcon.svg          Source for the app icon
```
