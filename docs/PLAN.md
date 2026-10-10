# Loco Loco: plan

A native macOS menu bar app. The icon shows how many local dev servers are running. Click it to see them, stop them, and bring back ones you stopped.

Flow images: `docs/flow/iteration-2/flow.png` (the board) and `docs/flow/iteration-2/01…15.png` (one per state). Iteration 1, the native menu look, is in `docs/flow/iteration-1/`.

## Decided

- Name: Loco Loco.
- The count shows next to the icon. "Show count in menu bar" in the ··· menu turns it off.
- Stop all… stays, with one confirmation: "Stop all 2 servers?", or "Stop 1 server?" for one.
- History keeps 20 servers. "Keep history" offers 10, 20 or 50.
- The context menu has both Open in Terminal and Open in Cursor.
- Iteration 2 is built as drawn: settings live in the ··· menu (no Settings window), the history group is called Stopped, and the panel is solid, with glass only on the menus. The UI can be tweaked later.

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
- A ··· button on the Running header opens a menu with Stop all, the settings and Quit. There is no Settings window.
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
| 11 | Right-click: Open in browser, Copy URL, Restart, Stop, Show in Finder, Open in Terminal, Open in Cursor, Show log. |
| 12 | Still running after 5 seconds: Force stop. |
| 13 | After Stop all: "Nothing running". Stopped shows the 5 latest, and the rest sit under More. |
| 14 | The ··· menu: Stop all…, Launch at login, Show count in menu bar, Show app and macOS servers, Keep history (10, 20 or 50 servers), Clear history…, Quit Loco Loco. |
| 15 | Dark appearance. |

**Rules every frame follows**
- The count is the number of servers with an open port. A stopping server still counts. A starting one counts once its port opens.
- A busy row (stopping or starting) is dimmed and shows a spinner.
- Long names are cut in the middle, the way Finder cuts file names, so they end before whatever is on the right: the time, a reason or the buttons. The help tag shows the full name and folder.
- A row moves to its new section as soon as its server stops or starts. A row that slides under a still pointer shows no buttons until the pointer moves, so a second click can't stop the next server.

## How it works

**Finding servers**
- Reads the process table directly through the system's libproc (no `lsof`, so it's cheap): every 2 seconds while the panel is open, every 10 seconds otherwise.
- Keeps processes that listen on a TCP port and run from a folder inside your home folder. Apps and system processes run from `/`, so Figma, OneDrive and Control Center stay hidden. "Show app and macOS servers", in the ··· menu, brings them back. (The folder is the test, not the file path: Homebrew's Python runs from inside an app bundle.)
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
- History keeps 20 servers ("Keep history" in the ··· menu: 10, 20 or 50), saved in `~/Library/Application Support/Loco Loco/history.json`. Stopped shows the 5 latest. The rest sit under "More", collapsed, the way Notion's sidebar collapses its pages. More shows only when it hides 2 or more servers; with 6 stopped, all 6 show, because a More row would take the sixth row's place. More opens in place: the panel grows to the height of the screen, then scrolls. "Clear history…" asks once.
- Open in Terminal opens a Terminal window in the server's folder. Open in Cursor opens the folder in Cursor, and only shows when Cursor is installed.
- Limit: a server started with extra environment variables (from an IDE run profile, say) may need them. Restart uses the folder, the command and PATH. If that fails, the log says why.

## Apple HIG, applied

- A menu bar extra. Its panel is a solid surface, after Notion and Linear, instead of the system material. The context menu and the ··· menu are real NSMenus, so they keep Liquid Glass, the accent highlight, checkmarks, ⌘Q and the submenu chevron.
- Panel: 320pt wide, 6pt padding, 28pt rows and headers, 8pt between the groups. Corners are concentric: 6pt rows inside a 12pt panel. Times, row buttons, Force stop and the ··· button all end 16pt from the panel's edge.
- Menus, as measured on this Mac (macOS 26): 5pt padding, 24pt rows, 11pt separators, 8pt highlight corners. The context menu is 158pt wide, the ··· menu 269pt.
- Text: SF Pro 13pt in rows, 12pt in headers (the group name semibold, the count regular). AppKit label colours. The secondary colour is a little darker than the system's so it passes 4.5:1 on white, and the failure reason uses the darker system red (#d70015, #ff453a in dark) for the same reason.
- Sentence case everywhere ("Open in browser", "Force stop", "Stop all…"). The HIG asks for title case in menus and buttons; this follows Notion and Linear.
- SF Symbols for everything except the octopus (see Brand): `stop.fill`, `arrow.clockwise`, `doc.text`, `ellipsis`, `globe`, `link`, `folder`, `terminal`, `chevron.left.forwardslash.chevron.right` (Cursor), `checkmark`, `chevron.right`.
- One symbol and one name per action, in the rows and the context menu: `stop.fill` for Stop, `arrow.clockwise` for Restart (also on a server that didn't start), `doc.text` for Show log. Row buttons are plain glyphs that darken under the pointer, with a help tag. Stop is 11.75pt and the others 11pt, so the ink matches the mockup, and every row button is 21.5pt wide, so the icons line up from row to row.
- Keyboard: arrow keys move through rows, Return opens, ⌘⌫ stops, ⌘R restarts, ⌘, opens the ··· menu, ⌘Q quits, Esc closes.
- VoiceOver reads each row as "ops-validation-api, port 8000, running since 11:09 AM", with Stop and Restart as actions.
- Light, dark, Increase Contrast, Reduce Motion and accent colour all come from the system.
- No Dock icon. Launch at login uses the system's login items, so it shows up in System Settings like any other app.

## Brand

An octopus, so the app feels friendly rather than technical. Direction: Deep sea, a white line octopus on navy (#16465A to #0D2B3B). The board is `docs/brand/octopus-directions.png`, made by `docs/brand/src`.

- Menu bar: a solid octopus as a 16pt template image, so macOS tints it like the other icons. When nothing is running, its eyes close and the count hides.
- Panel: when nothing is running, a small line octopus with closed eyes sits under "Nothing running" (34pt tall, 1.5pt line, tertiary colour).
- App icon: the line octopus on the navy squircle, with a heavier line at 32px and below. Alerts and Finder show it. macOS 26 keeps it as is, with no grey frame.
- One geometry for all three: `app/Sources/LocoLoco/Octopus.swift`, a port of the board's generator.

## Build

- SwiftUI with AppKit where needed, Swift 6, built with Swift Package Manager (no Xcode needed on this Mac).
- The panel is a borderless panel window under a status item, hosting SwiftUI, so its surface, corners and shadow are ours. The two menus are NSMenus.
- Four parts: Scanner (finds servers), Store (history file), Runner (starts and stops, writes logs), UI (panel, context menu, ··· menu).
- Packaged as `Loco Loco.app`, signed locally, installed to `~/Applications`, added to login items.
- Two things found while measuring real menus on macOS 26: an item that uses the system's quit action gets an automatic xmark icon, so Quit uses its own action; and menu item badges draw a grey capsule, so the menus don't use them.
- No network access, no telemetry, no admin rights. It can only stop processes you own.

**Building and testing** (from `app/`)
- `scripts/build.sh` builds the release app, signs it locally, quits the running copy, installs it to `~/Applications` and opens it. `--no-install` stops after the build. It redraws the app icon with `scripts/make-icon.swift` when that file or `Octopus.swift` changes.
- `scripts/test.sh` runs the LocoCore tests. With only the Command Line Tools, it points SwiftPM at their Testing framework.
- `swift run loco-scan` prints the servers the app would list, from the same scanner.
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

The octopus, checked the same way: the menu bar glyph awake and asleep (3pt to the count, as on the board), the empty state in light and dark with and without history, row icon sizes against the mockup, both alerts with the new icon, and the Finder icon on macOS 26.

## Open questions

None.
