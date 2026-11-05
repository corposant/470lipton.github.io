# Nag

A capture-first iPhone app where **every item can nag you, repeatedly, until it's done.**

- **Everything is an Item.** To-dos, ideas, concepts and projects are all the same thing. Any item can have notes, `[[links]]` to other items, backlinks, tags, and sub-items (an item with sub-items *is* a project).
- **Capture is instant.** The app opens with the keyboard already up. Type, hit return, and keep typing.
- **Every capture gets a default nag** (out of the box: first nag 15 min after capture, then every 8 min until done). You can change that in Settings, or per item.
- **Nags repeat forever.** They don't stop after one or two. Each nag has **Done ✓ / Snooze 1 hour / Tomorrow morning** buttons right on the notification.
- **Your data is plain Markdown**, one file per item, in *Files → On My iPhone → Nag → Items*.

## Capture shortcuts

Type these anywhere in a capture line (all optional):

| Token | Meaning |
|---|---|
| `!8m` `!2h` `!1d` | repeat every 8 min / 2 hours / 1 day |
| `!once` | remind once, don't repeat |
| `!off` or `!idea` | no reminder |
| `@30m` `@2h` `@1d` `@now` | when to start nagging |
| `#tag` | add a tag |

Example: `renew passport #admin !1h @2h`

## Running it on your iPhone

You need a Mac with Xcode (16 or newer) and Homebrew.

```bash
brew install xcodegen
git clone https://github.com/corposant/470lipton.github.io.git Nag
cd Nag
git checkout app
xcodegen            # generates Nag.xcodeproj from project.yml
open Nag.xcodeproj
```

In Xcode:

1. Click the **Nag** project → **Nag** target → **Signing & Capabilities** and pick your **Team**.
   If it complains the bundle identifier is taken, change it to something like `com.yourname.nag`.
   To avoid re-picking the team after each `xcodegen`, paste your Team ID into `DEVELOPMENT_TEAM` in `project.yml`.
2. Plug in your iPhone (or use Wi-Fi pairing) and select it as the run destination.
3. On the iPhone, the first time: **Settings → Privacy & Security → Developer Mode → On** (it restarts).
4. Press **⌘R**. Allow notifications when asked.

Run the tests with **⌘U**.

**Free vs paid developer account:** with a free (personal team) account the app stops opening after **7 days** and you have to press ⌘R again. With the paid program ($99/yr) it lasts a year and you can use TestFlight. To check which you have, go to developer.apple.com/account. If you see a **Membership** section with a renewal date, you're on the paid program.

### Optional: Time Sensitive notifications

These let nags break through Focus modes. In **Signing & Capabilities → + Capability → Time Sensitive Notifications**. Then on the phone: **Settings → Notifications → Nag → Time Sensitive → On**. The code already marks nags as time-sensitive.

## How the repeating nags work

iOS lets an app have at most 64 notifications scheduled at once, so `NagPlanner` budgets them:

- An item that's **already nagging** gets one *repeating* trigger, which iOS fires every N minutes forever, even if the app is never opened again.
- An item whose nag **starts later** gets a one-shot at the start time plus follow-ups while there's room. Whenever the app gets a chance to run (you open it, tap a notification button, or iOS grants a background refresh), the plan is recomputed and started items switch to the forever-repeating trigger.

## Project layout

```
project.yml                 XcodeGen spec (the .xcodeproj is generated, not committed)
Nag/App                     App entry, notification delegate, background refresh
Nag/Model                   Item, Markdown file format, capture parser, nag planner
Nag/Store                   ItemStore (in-memory + Markdown files), Router
Nag/Notifications           Sync between the plan and iOS's notification center
Nag/Intents                 Siri / Shortcuts / Action Button capture
Nag/Views                   SwiftUI screens
NagTests                    Unit tests for the model and planner
```
