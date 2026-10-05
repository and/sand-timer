# Changelog

Every release of Sand Timer, newest first. Each one can be downloaded from its
[release page](https://github.com/and/sand-timer/releases).

## 1.9.0 — unreleased
- **One Sound menu, and noise to work to.** Everything you hear is now under **Sound**: one choice of what plays while the sand runs — **Silence**, **Falling Sand**, or a steady noise to work to, **White** (a hiss), **Pink** (like rain) or **Brown** (a low rumble) — then the flip, fall and finish sounds and the minute chimes, each on or off. It fades in as the sand starts, out on a pause, an end or the sand running out, and crossfades when you change it. Settings has one volume for it, and a softness that muffles the noises' highs. The noise is made on your Mac as it plays, so there's nothing to download. If you had the falling sand turned up, it carries on as before.
- **No more crash with two projects of the same name.** Statistics crashed when two projects shared a name, or when several removed projects were shown as "Unknown project". Each now gets its own place in the project menu.
- **Export is tested end to end**, from pressing the button and choosing where to save to the file that lands there.

## 1.8.1 — 2026-09-28
- **A proper name for the app.** Sand Timer now has its own identifier (`io.github.and.SandTimer`) in place of a placeholder, which it needs for things like the App Store. Your settings, projects and every minute of your record come across on its first launch; nothing to do. If you use **Start at Login**, tick it again in Settings, and remove any older Sand Timer entry from System Settings → General → Login Items.

## 1.8.0 — 2026-09-28
- **Projects.** Make projects in **Settings…**, each with a name and any colour, and time is counted against whichever is on. The sand takes the project's colour, and its name is printed faintly on the top cap, brightening when you hover over the timer. Switch from **Project** in the right-click menu or the menu bar, or shake the timer side to side to move on to the next project ticked for Shake. Time is kept against the project itself, so renaming or recolouring one never disturbs its history, and removing one keeps its time in Statistics.
- **One Thing at a Time.** On to begin with: the project stays the same for the whole session. Mid-session the projects wait and shaking does nothing; choose **End Session** when you're ready, then pick the next one.
- **End Session.** Done early? End the session from the right-click menu, the menu bar, `sandtimer://end` or Claude. The time you ran is kept (it just isn't a finished timer), and the sand settles to the bottom, ready for the next one.
- **Hourly statistics, and projects in them.** Statistics gains an Hourly view of the last 24 hours. With projects, every bar is split by project colour, with a legend, a breakdown of the span you're looking at, and a menu to look at one project on its own. Export adds a column per project, and Claude can answer by project too.
- **The day's figure, printed on the base.** Rest the pointer on the base and the target line gives way to the figure, like `1:18:42/3:00:00`, printed into the plastic like the time above it.

## 1.7.0 — 2026-09-28
- **A daily target.** Set one in **Settings…**, in minutes or hours, and a groove along the timer's base fills with sand as the day's time runs, marked at round amounts of time and glowing softly once you reach it. Rest the pointer on the base to read it off, like `1:18:42/4:00:00`. Hidden in the menu bar, the figure shows there beside the time left.
- **Settings.** Start at Login, Float Anywhere, Control from Claude & Shortcuts and Check for Updates move out of the right-click menu into a small Settings window, alongside the target.
- **It picks up where it left off.** A run that was going or paused when the app closed carries on after it opens again, and the size you chose is remembered.
- **A cleaner chart.** The lines in Statistics no longer run through their labels.

## 1.6.3 — 2026-09-28
- **It stays on every desktop, properly this time.** 1.6.0 asked for the timer's place again as the desktop began to change, which was too early: macOS drops the window a moment after the switch settles. It now asks again once the switch is over, and whenever macOS reports the timer as no longer on screen, so it no longer goes missing on some desktops.

## 1.6.2 — 2026-09-27
- **The daily chart names each day twice.** Under every bar, the date and the initial of the weekday — so a fortnight shows its own shape at a glance, and a gap reads as a Sunday rather than as a day you skipped.
- **The chart is ruled.** Lines at round amounts of time, labelled down the left, so you can see that Tuesday was three hours without hovering over Tuesday.

## 1.6.1 — 2026-09-25
- **Commands are no longer lost mid-turn.** A pause or resume arriving while the glass was still turning fell through and went nowhere — rarely noticed by hand, but immediately by Claude or a Shortcut sending one command after another. A command now waits for the glass to settle and is then carried out.
- **The status says when a run began and when it ends.** `started_at` and `finishes_at` are given as they are, instead of leaving the start to be worked out from the sand left — which was right for an untouched run and wrong for one that had been paused.

## 1.6.0 — 2026-09-24
- **Ask Claude about your time.** The app now ships a small MCP server, so Claude can read the record and answer questions about it — "how much did I focus this week?", "put September's hours in my invoice". It makes no network calls, and nothing runs until Claude asks it something. Setting it up is described in the [README](README.md#ask-claude-about-your-time).
- **Claude can work the timer, once you allow it.** "Start a 20 minute timer", "pause it", "how long is left?" — after you turn on **Control from Claude & Shortcuts**, which is off to begin with. With it on, the timer also answers `sandtimer://` links, so Shortcuts, a script, or `open sandtimer://start?minutes=25` in a terminal can start, pause, resume and restart it.
- **It stays on every desktop.** A window that joins every Space should stay on all of them, but macOS can quietly lose its place on one: the timer would ride in on the switch animation, vanish a moment later, and go on running unseen. It now asks for its place again each time you change desktop.

## 1.5.0 and 1.5.1 — 2026-09-21
- **Statistics.** **Statistics…** in the right-click menu shows how long the sand has run and how many timers ran all the way out, by day, week, month or year, as a chart you can hover over to read any span off.
- **Export to CSV.** **Export…** in that window saves the whole record, grouped the way you are looking at it, as `sand_timer_report_YYYYMMDDHHMM.csv`.
- **It tells you when there's a new version**, once a day, and says which version you are running. **Check for Updates** turns that off, and with it off the app makes no network calls at all.
- **The falling sand starts silent** — **Sand Sounds** begins at Off — and is heard whether or not the timer is on screen once you turn it up.
- **More to hand in the menu bar**: pause, resume, restart and the sound settings, with the timer hidden away up there.
- **A shorter menu**: sand colour, base style and size gathered under **Appearance**.

## 1.4.1 — 2026-09-15
- A soft chime each minute (off by default), and the sound settings grouped together.

## 1.4.0 — 2026-09-15
- Tilt it by hand, lift a toppled timer back up, and pick it up by the top.

## 1.3.1 — 2026-09-15
- A natural shadow.

## 1.3.0 — 2026-09-15
- Float Anywhere, and smooth tipping over and standing up.

## 1.2.0 — 2026-09-15
- Gravity affects the flow (drop it and the stream stops mid-air), about 40% less CPU, and natural-looking sand.

## 1.1.1 — 2026-09-15
- A smooth, steady sand stream.

## 1.1.0 — 2026-09-15
- 6- and 12-minute timers for 0.1- and 0.2-hour billing blocks.

## 1.0.3 — 2026-09-15
- New installs start on the 25-minute 🍅 Pomodoro setting.

## 1.0.2 — 2026-09-15
- **Support Sand Timer…** in the right-click menu; open source under the MIT License.

## 1.0.0 — 2026-09-14
- The first release: a sand timer that sits on your desktop, above your other windows.
