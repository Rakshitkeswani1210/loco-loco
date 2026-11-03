# Loco Loco: plan

A native macOS menu bar app. The icon shows how many local dev servers are running. Click it to see them, stop them, and bring back ones you stopped.

Flow images: `docs/flow/iteration-2/flow.png` (the board) and `docs/flow/iteration-2/01…15.png` (one per state). Iteration 1, the native menu look, is in `docs/flow/iteration-1/`.

## Decided

- Name: Loco Loco.
- The count shows next to the icon. "Show count in menu bar" in Settings turns it off.
- Stop all… stays, with one confirmation: "Stop all 2 servers?", or "Stop 1 server?" for one.
- History keeps 20 servers. "Keep history" offers 10, 20 or 50.
- The context menu has both Open in Terminal and Open in Cursor.
- Iteration 2 is built as drawn: the history group is called Stopped, and the panel is solid, with glass only on the menus. The UI can be tweaked later.
- Later, on Oct 13: the settings moved from the ··· menu to a Settings window, which adds Appearance (System, Light or Dark) and a Transparent background switch that puts the panel on Liquid Glass.

## Direction (Iteration 2)

Cleaner, after Notion and Linear. The references, from Mobbin:
- Linear, grouped list (a header with a count over quiet rows): https://mobbin.com/screens/610d34b6-6ad8-45ab-80fb-2107b31ed01e
- Linear, filter dropdown (a solid surface, small type, no dividers): https://mobbin.com/screens/ed670cda-0527-4716-a1a6-0159f12c4f42
- Linear, ··· menu: https://mobbin.com/screens/f71cec1e-a119-485b-9164-969169030e1a
- Linear, preferences: https://mobbin.com/screens/8720abc2-c855-44ee-911d-bc15fc1707eb
- Notion, page ··· menu (settings as toggles in a menu, not a window): https://mobbin.com/screens/ce8877c5-606b-43fd-80c4-d8f6286aaee4
- Notion, sidebar "··· More" (the rest, collapsed): https://mobbin.com/screens/0159ba7f-b03b-4b57-b6fe-d44d8ade6ac7

What changed from Iteration 1:
- The panel is a solid surface (white, or #252527 in dark) instead of glass.
- Two groups, **Running** and **Stopped**, each with its count in the header. "Stopped" replaces "Recent" because it says what the rows are.
- The port comes first, in a fixed column, so the names line up.
- A ··· button on the Running header opens a menu with Stop all…, Clear history…, Settings… and Quit.
- The context menu and the ··· menu stay real macOS menus, with the system glass and the accent highlight.

## The flow

| Frame | What happens |
|---|---|
| 1 | The menu bar shows the server icon and the count (10). |
| 2 | Click: **Running** (port, project, start time), then **Stopped** (port, project, stop time). Each header shows its count. |
| 3 | Hover a running row: Stop takes the place of the time. Click a row anywhere else to open it in the browser. |
| 4 | Stopping: the row dims and shows a spinner. |
| 5 | Stopped: the row moves to the top of Stopped with the time it stopped, and the count drops to 9. |
| 6 | Hover a stopped row: Restart. |
| 7 | Starting: back in Running, dimmed, with a spinner. Same folder, same command, in the background. |
| 8 | Running again, with the new start time. |
| 9 | Didn't start: the row goes back to Stopped, and the reason takes the place of the time, in red. |
| 10 | Hover it: Show log and Restart. |
| 11 | Right-click: Open in browser, Copy URL, Restart, Stop, Show in Finder, Open in Terminal, Open in Cursor, Show log. A stopped server also gets Remove from history, last, after a separator. |
| 12 | Still running after 5 seconds: Force stop. |
| 13 | After Stop all: "Nothing running". Stopped shows the 5 latest, and the rest sit under More. |
| 14 | The ··· menu: Stop all…, Launch at login, Show count in menu bar, Show app and macOS servers, Group by project, Keyboard shortcut… (with the current keys on the right), Keep history (10, 20 or 50 servers), Clear history…, Quit Loco Loco. Since replaced: the ··· menu is Stop all…, Clear history…, Settings… and Quit, and the rest live in Settings (see Settings below). |
| 15 | Dark appearance. |

**Rules every frame follows**
- The count is the number of servers with an open port. A stopping server still counts. A starting one counts once its port opens.
- A busy row (stopping or starting) is dimmed and shows a spinner.
- Long names are cut in the middle, the way Finder cuts file names, so they end before whatever is on the right: the time, a reason or the buttons. The help tag shows the full name and folder.
- A row moves to its new section as soon as its server stops or starts. A row that slides under a still pointer shows no buttons until the pointer moves, so a second click can't stop the next server.

## Projects (Iteration 3, Mac only)

Each row shows which project it belongs to, so he knows where to look. Approved on Oct 14 from `projects-ui.png`: tinted labels, newest first, grouping as a toggle, rename allowed, panel 360pt.

- The label sits before the time, right-aligned: 11pt medium, 18pt tall, 6pt side padding, 5pt corners, up to 104pt wide with a tail ellipsis. The time keeps at least 60pt, so labels line up from row to row and stay put when hover shows the buttons.
- Five tints: blue, green, purple, orange and teal, with darker ink in light mode and lighter ink in dark mode so the text passes 4.5:1. Increase Contrast makes the tint 1.5 times stronger and pushes the inks further, so every label passes 6.5:1. A project gets the least-used tint the first time it shows up in history, and keeps it. From the sixth project on, tints repeat.
- The project folder: a git worktree belongs to its main repo. Then it is the first folder below Documents, Desktop, Downloads or another folder that holds projects, else the first folder in the home folder. Loose servers in Documents itself, or outside the home folder, have no label. Trailing spaces in folder names are dropped from the label.
- Running is sorted newest first. Stopped stays in the order servers stopped.
- Group by project (Settings, off by default): running servers sit under a 26pt header with the project's label, 4pt between groups. Rows inside a group drop their label. Groups follow their newest server. Servers with no project go last, under a grey "Other", which shows only when there is at least one project group. Arrow keys move through the rows and skip the headers.
- Rename project… (last in the context menu): an alert with a text field. The new name applies to every server in that folder and keeps the tint. An empty name, or the folder's own name, goes back to the folder name. Renaming two folders to the same name puts them in one group.

## Previews, needs and project lines (Iteration 4, Mac only)

Approved on Nov 2 with every proposed answer, from a plan page with mocks of eight states (hover card, a stopped deck's card, restart after a reboot, starting in order, a need that fails, project actions, the Needs menu, an API's card).

- **Preview card.** Half a second on a row opens a card 8pt to the left of the panel (right when there's no room), level with the row: a 288 × 180 snapshot of the page, its title and URL, then "Needed by" and "Needs" with Running or Stopped on each line. Moving to another row swaps it at once. Space opens it for the row picked with the arrow keys. The card uses the panel's own surface, so it follows Light, Dark and Transparent background. "Show previews" in Settings turns it off, and no snapshots are taken.
- **Snapshots.** An offscreen web view loads the page 5 seconds after a server comes up, waits until its requests go quiet (2 to 10 seconds), and saves a 640 × 400 PNG to `~/Library/Caches/Loco Loco/Snapshots/`. A script lets the page read only: fetch, XHR, beacons and forms can't POST, PUT, PATCH or DELETE, so a snapshot never writes data. When the root answers with JSON, `/docs` is shown if it's a page (FastAPI), else the title is "JSON API". On opening the panel, snapshots older than an hour are taken again. A stopped static server that never had one (`http.server`, `serve`, `http-server`, or a server handed a folder) is read straight from its folder's index.html, with nothing started. Never for app and macOS servers. Remove from history and Clear history delete them.
- **Needs.** Found in the start command, the shell script it runs (`bash x.sh`, one level), the `.env`, `.env.local`, `.env.development` and `.env.development.local` of its folder and project, and the running server's environment (only the ports are kept, never the values). Local URLs on localhost, 127.0.0.1, 0.0.0.0 and [::1] count; variables named *CORS* or *ORIGIN* don't, since they list who calls the server. On a real project this found two chains of three servers. The Needs submenu (right-click, after Stop) ticks what was found and lists the rest of the project; a tick by hand wins. History keeps a server that a kept one needs, past the limit.
- **Restart in order.** Restart starts what a server needs first, depth first, one at a time, each once the one before listens (up to 60 seconds). The others show "Queued" where the time goes. A need that's already listening is skipped. When one doesn't come up, it goes to Stopped with its reason and the rest say "Needs 8002" in red. The Restart button's help tag says what comes with it: "Restart with 8002 and 8090".
- **Project lines in Stopped.** Always grouped, whatever Group by project says. A project with two or more stopped servers is one line, drawn like a Running project header: its label at the row inset, the count, a chevron. Click, Return or → opens it to its 5 latest and a More; ← closes it. A line whose newest server didn't start opens by itself. Single servers stay rows with their label. The 5-line limit and More apply to lines and rows together.
- **Project actions.** Hovering a project label in Running shows Stop ("Stop 6 in Acme"), with no confirmation, like a row's Stop. Hovering a project line in Stopped shows Restart, which starts them in needs order and asks first when it's more than 5. Both are in the label's right-click menu, with Rename project….
- **Names.** A static server is named after the folder it serves: `--directory X` or `-d X` for `http.server`, the folder argument of `serve` and `http-server`. Entries already in history are renamed on the next scan.

## How it works

**Finding servers**
- Reads the process table directly through the system's libproc (no `lsof`, so it's cheap): every 2 seconds while the panel is open, every 10 seconds otherwise.
- Keeps processes that listen on a TCP port and run from a folder inside your home folder. Apps and system processes run from `/`, so Figma, OneDrive and Control Center stay hidden. "Show app and macOS servers", in Settings, brings them back. (The folder is the test, not the file path: Homebrew's Python runs from inside an app bundle.)
- Jobs aren't servers (Mac). A test run, build, lint or typecheck, judged by the last step of its command (`npm test | tail`, `npx vitest`, `next build`; in `npm run build && npm start` the last step is the server), and anything on a random port (49152 and up) in its first 10 minutes, like a script that serves a site to a browser it's driving. They show only under "Show app and macOS servers", get no history and no snapshot. After 10 minutes on a random port, it's a server. What Loco Loco started or already lists stays a server, so restarting an old entry on a random port works. Stopped entries that were jobs are dropped from history on launch.
- One row per server. A port open on both IPv4 and IPv6 counts once. If a server listens on more than one port, the row shows the lowest and the context menu lists the rest.
- Name: the project folder (nearest folder with `package.json`, `pyproject.toml` or `.git`), skipping `dist`, `build`, `public`, `docs` and `out`. For `uv run name`, the name. If the folder isn't a project, the script's name (`auth-mock.py` → auth-mock).
- Start time is today's time ("10:37 AM") or the date ("Oct 7").

**Stopping**
- Sends a normal quit signal to the server and its child processes. If it's still running after 5 seconds, the row offers Force stop.
- No confirmation for one server, because Stopped can bring it back. Stop all… asks once, in a standard alert ("Stop all 10 servers?" with Stop all and Cancel).

**History and restart**
- Every server that stops is saved to Stopped, however it stopped: from the app, Ctrl+C in a terminal, or a crash. The app saves the folder, the command, the port and the PATH.
- Restart runs the same command in the same folder in the background, and writes its output to `~/Library/Logs/Loco Loco/<name>.log`.
- Python servers run with `PYTHONUNBUFFERED=1`, so their log fills while they run instead of when they quit.
- The row shows a spinner until the port opens. If the process quits first, or 60 seconds pass, the row shows why ("Exited with code 1", "Port in use", "Timed out") and offers Show log and Restart.
- Restarted servers keep running when you quit Loco Loco.
- History keeps 20 servers ("Keep history" in Settings: 10, 20 or 50), saved in `~/Library/Application Support/Loco Loco/history.json`. Stopped shows the 5 latest. The rest sit under "More", collapsed, the way Notion's sidebar collapses its pages. More shows only when it hides 2 or more servers; with 6 stopped, all 6 show, because a More row would take the sixth row's place. More opens in place: the panel grows to the height of the screen, then scrolls. "Clear history…" asks once.
- Remove from history, in a stopped server's context menu or with ⌘⌫, forgets that one server without asking, so short-lived runs like test suites can go without clearing the rest. Its log stays, as with Clear history. With ⌘⌫ the highlight moves to the next stopped row, and never to a running one, so pressing it again can't stop a server.
- Open in Terminal opens a Terminal window in the server's folder. Open in Cursor opens the folder in Cursor, and only shows when Cursor is installed.
- Limit: a server started with extra environment variables (from an IDE run profile, say) may need them. Restart uses the folder, the command and PATH. If that fails, the log says why.

**Keyboard shortcut**
- ⌃⌥L, from any app, opens the panel in the middle of the screen with the pointer, clear of the menu bar and the Dock. Pressed again, it closes. While the panel is open its top edge stays put, so rows don't jump; it moves up only when the panel grows past the bottom. The menu bar icon isn't highlighted, since the panel doesn't hang from it.
- In Settings, click the shortcut field (or focus it and press Space) and type the keys. Delete means none, and Esc, Return or a click elsewhere stops recording. The current shortcut is off while recording, so pressing it records it again.
- A shortcut needs ⌃, ⌥ or ⌘ (F1 to F20 can stand alone), so it can't fire while you type. Keys that macOS already uses, such as ⌘Space for Spotlight, are refused with a pointer to System Settings under the field, which keeps recording. Other apps' shortcuts can't be seen, so a clash with one isn't caught.
- Uses Carbon's `RegisterEventHotKey`, which needs no Accessibility permission. Saved as `shortcut` in the app's defaults; an empty value means none.

**Settings**
- A standard grouped form in a small window, opened with ⌘, or Settings… in the ··· menu: Launch at login, Show count in menu bar, Show app and macOS servers, Group by project; Appearance and Transparent background; Keyboard shortcut; Keep history. Changes apply at once. ⌘W closes it and focus goes back to the app you were in.
- Appearance is System, Light or Dark, for the panel, the menus, the alerts and Settings. The menu bar icon follows the menu bar. Increase Contrast still applies.
- Transparent background puts the panel on Liquid Glass (the menu blur before macOS 26) instead of the solid surface. The glass is clipped to the panel's corners: its own faint shadow otherwise fills the window's corners, and macOS then draws a square shadow and outline around the panel.
- Saved as `appearance` and `transparent` in the app's defaults.

## Apple HIG, applied

- A menu bar extra. Its panel is a solid surface, after Notion and Linear, instead of the system material, unless Transparent background is on. The context menu and the ··· menu are real NSMenus, so they keep Liquid Glass, the accent highlight, checkmarks, ⌘Q and the submenu chevron.
- Panel: 360pt wide (320pt before project labels), 6pt padding, 28pt rows and headers, 8pt between the groups. Corners are concentric: 6pt rows inside a 12pt panel. Times, row buttons, Force stop and the ··· button all end 16pt from the panel's edge.
- Menus, as measured on this Mac (macOS 26): 5pt padding, 24pt rows, 11pt separators, 8pt highlight corners. The context menu is 158pt wide, the ··· menu 269pt.
- Text: SF Pro 13pt in rows, 12pt in headers (the group name semibold, the count regular). AppKit label colours. The secondary colour is a little darker than the system's so it passes 4.5:1 on white, and the failure reason uses the darker system red (#d70015, #ff453a in dark) for the same reason.
- Sentence case everywhere ("Open in browser", "Force stop", "Stop all…"). The HIG asks for title case in menus and buttons; this follows Notion and Linear.
- SF Symbols for everything except the octopus (see Brand): `stop.fill`, `arrow.clockwise`, `doc.text`, `trash`, `ellipsis`, `globe`, `link`, `folder`, `terminal`, `chevron.left.forwardslash.chevron.right` (Cursor), `checkmark`, `chevron.right`.
- One symbol and one name per action, in the rows and the context menu: `stop.fill` for Stop, `arrow.clockwise` for Restart (also on a server that didn't start), `doc.text` for Show log, `trash` for Remove from history (context menu only). Row buttons are plain glyphs that darken under the pointer, with a help tag. Stop is 11.75pt and the others 11pt, so the ink matches the mockup, and every row button is 21.5pt wide, so the icons line up from row to row.
- Keyboard: ⌃⌥L opens the panel from any app (it can be changed or turned off). In the panel, arrow keys move through rows, Return opens, ⌘⌫ stops a running server and removes a stopped one from history, ⌘R restarts, ⌘, opens Settings, ⌘Q quits, Esc closes.
- VoiceOver reads each row as "ops-validation-api, port 8000, running since 11:09 AM", with Stop and Restart as actions, and Remove from history on stopped rows.
- Light and dark come from the system unless Appearance in Settings picks one. Increase Contrast, Reduce Motion and accent colour come from the system.
- No Dock icon. Launch at login uses the system's login items, so it shows up in System Settings like any other app.

## Brand

An octopus, so the app feels friendly rather than technical. Direction: Deep sea, a white line octopus on navy (#16465A to #0D2B3B). The board is `docs/brand/octopus-directions.png`, made by `docs/brand/src`.

- Menu bar: a solid octopus as a 16pt template image, so macOS tints it like the other icons. When nothing is running, its eyes close and the count hides.
- Panel: when nothing is running, a small line octopus with closed eyes sits under "Nothing running" (34pt tall, 1.5pt line, tertiary colour).
- App icon: the line octopus on the navy squircle, with a heavier line at 32px and below. Alerts and Finder show it. macOS 26 keeps it as is, with no grey frame.
- One geometry for all three: `app/macos/Sources/LocoLoco/Octopus.swift`, a port of the board's generator.

## Build

- SwiftUI with AppKit where needed, Swift 6, built with Swift Package Manager (no Xcode needed on this Mac).
- The panel is a borderless panel window under a status item, hosting SwiftUI, so its surface, corners and shadow are ours. The two menus are NSMenus.
- Four parts: Scanner (finds servers), Store (history file), Runner (starts and stops, writes logs), UI (panel, context menu, ··· menu, Settings).
- Packaged as `Loco Loco.app`, signed locally, installed to `~/Applications`, added to login items.
- Two things found while measuring real menus on macOS 26: an item that uses the system's quit action gets an automatic xmark icon, so Quit uses its own action; and menu item badges draw a grey capsule, so the menus don't use them.
- No network access, no telemetry, no admin rights. It can only stop processes you own.

**Building and testing** (from `app/macos/`)
- `scripts/build.sh` builds the release app, signs it locally, quits the running copy, installs it to `~/Applications` and opens it. `--no-install` stops after the build. It redraws the app icon with `scripts/make-icon.swift` when that file or `Octopus.swift` changes.
- `scripts/test.sh` runs the LocoCore tests. With only the Command Line Tools, it points SwiftPM at their Testing framework.
- `swift run loco-scan` prints the servers the app would list, from the same scanner, with each server's project. `swift run loco-scan project <folder>…` prints the project folder for any folder.
- `scripts/build.sh --test-hooks` adds `TestHooks.swift`, which lets `build/loco-test` open the panel, hover, click and dump its state for screenshots. Don't keep that build installed.
- Folder access: the first time Loco Loco restarts a server from Documents, Desktop or Downloads, macOS asks once. Click Allow. The restart waits for the answer, up to the 60 second limit. The app is signed locally, so macOS treats each rebuild as a new app and asks again.

**Checked already.** A test program built with only the Command Line Tools found all 12 servers running now (the mockups show the 10 from when I drew them). For each one it read the port, the folder and the command, using the same system calls the app will use. The flag that lets restarted servers outlive the app is available too. Paths are kept exactly as they are, even a folder name that ends in a space.

## How it was checked

Test servers ran from `/tmp/loco-site`, and a `--test-hooks` build drove the panel and took screenshots (Oct 9).

1. Start `python3 -m http.server 8765` in a test folder. It appears within 2 seconds with the folder's name. Passed.
2. Stop it from the panel. The port closes, the row moves to Stopped, the count drops. Passed.
3. Restart it. It's back on 8765 and the log file has its output. Passed, after adding `PYTHONUNBUFFERED`.
4. Stop a server outside the app. It shows up in Stopped. Passed, with `kill` from a shell.
5. Restart a command that fails. The reason shows, and Show log opens the log. Passed.
6. Open in Terminal and Open in Cursor open the server's folder. Not run, so no windows opened while you worked.
7. Quit Loco Loco. The servers it restarted keep running. Passed: a server restarted by one build kept running through the next install.
8. Compare with `lsof` on the servers running now. Passed: the same 9 dev ports, with Figma, Control Center, OneDrive, rapportd and GitHub hidden.
9. Light and dark, VoiceOver, keyboard only. Light, dark and keyboard passed. VoiceOver not run.

Also checked: Force stop after 5 seconds, Stop all… and Clear history… (both answered Cancel), focus going back to the previous app after an alert, More with 6 and 7 stopped, the empty state, and frames 2 to 15 side by side with the app.

Projects (Oct 14), checked the same way with test servers in a fake home folder, one process per server: labels in light and dark, labels holding still under hover, Stopped rows, grouping in light and dark with the right panel height, the grey Other group, Rename project… (typed name, tint kept, restart lands back in the renamed group), two folders renamed into one group and back, arrow keys skipping headers, and `loco-scan project` against the real Documents folder (worktrees, nested repos and loose folders). 19 unit tests pass.

Fixed on the way: in a full-screen space the menu bar hides once the pointer leaves it, and the open panel used to follow it up by about 62pt, off the top of the screen. The panel now keeps the top it opened at, and never sits higher than a menu bar below the top of the screen. Checked in a normal space (no change in position); the full-screen case was not run, so no space was taken over while he worked.

Remove from history, checked on Oct 13 with `python3 -m http.server` test servers and a `--test-hooks` build: from the context menu, the row leaves Stopped and `history.json`; with ⌘⌫, the highlight moves to the next stopped row, clears when none are left, and a further ⌘⌫ leaves the running server alone; ⌘⌫ on a running row still stops it.

The keyboard shortcut, checked on Oct 13 the same way: the panel opens centred on the pointer's screen to the point, without the menu bar highlight; the recorder alert takes focus, shows held modifiers, records ⌃⌥⇧K and saves it with Return, and the ··· menu then shows it; Delete sets none, Esc and Return reach Cancel and Save, an F-key alone records; ⌘Space and ⇧⌘3 read as taken by macOS and ⌃⌥L doesn't; a hot key event reaches the handler. Not run: pressing the real keys from another app, so no keystrokes went to the apps you were using.

The octopus, checked the same way: the menu bar glyph awake and asleep (3pt to the count, as on the board), the empty state in light and dark with and without history, row icon sizes against the mockup, both alerts with the new icon, and the Finder icon on macOS 26.

Previews, needs and project lines, checked on Nov 2 with a `--test-hooks` build pointed at a copy of history (`LOCO_HISTORY`) and three demo servers in a temp folder (web → api → mock, the API started by a script with a CORS list): needs found for every real server and the demo; the card on a running page, an API's `/docs`, a stopped deck read from its folder, and in dark; restart in order (mock starting, api and web Queued, all up in 1.5 seconds); the API's script removed, so it exits with 127 and web says "Needs 18002" while mock keeps running; the demo page's POST never reached its server; project Stop on hover (not clicked) and both help tags; the Needs submenu for 3102 (8002 ticked, the rest of the project below); the Settings switch. 43 unit tests pass. Not run: Restart all on a project, and the right-click menu's picture (its items were read instead).

Jobs, checked on Nov 3 with a `--test-hooks` build on a copy of the real history: 40 stopped rows went (57 to 17 entries, Stopped from 51 to 11), the 6 running servers stayed; a script on a random port stayed out of Running and history and showed under "Show app and macOS servers"; an old entry on a random port restarted and stayed up through 20 seconds of scans. One restart failed with "Address already in use" on a port that nothing was accepting on, most likely another app's outgoing connection. That can happen to any fixed choice in the random range. 49 unit tests pass.

## Open questions

None.
