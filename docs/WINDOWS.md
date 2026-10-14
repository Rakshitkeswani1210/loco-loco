# Loco Loco for Windows

The same app for Windows 11. The octopus sits in the notification area, at the bottom right of the taskbar. Click it to see your local servers, stop one, or restart one from Stopped. The features, rules and brand are the Mac's; the controls, type, icons and words are Windows'.

Flow images: `docs/flow/windows/flow.png` (the board) and `docs/flow/windows/01…11.png`. They are screenshots of the real app, taken by CI on Windows Server 2025 at 100% scale.

## Decided

- The flyout is solid, to match the Mac panel and the Linear and Notion direction. The menus are Windows' own.
- The count is an accent badge on the octopus, up to 99. At 16 px it shows 9+ for 10 or more. "Show count on icon" in the ··· menu turns it off; the tooltip still gives the count.
- The flyout opens above the octopus, 12 px from the taskbar and the screen edge.
- On first launch only, one Windows notification says how to drag the octopus out from under ^.
- Servers in WSL or Docker show only with "Show app and Windows servers", with Stop but no Restart.
- Windows 11 only. It may run on Windows 10, but it isn't tested there.
- Install: a zip for x64 and one for Arm64 on a GitHub release. The app isn't signed, so SmartScreen asks once.
- The repo has `app/macos` and `app/windows`. No code is shared; the two apps share the rules written here and in `docs/PLAN.md`.

## Mac to Windows

| Mac | Windows |
|---|---|
| Menu bar, top right | Notification area, bottom right of the taskbar |
| Count beside the icon | Count badge on the icon, plus the tooltip |
| Panel 320 pt, 28 pt rows | Flyout 360 px, 32 px rows, 8 px corners, 4 px on rows and buttons |
| SF Pro 13 / 12 pt, SF Symbols | Segoe UI Variable 14 / 12 px, Segoe Fluent Icons |
| NSMenu | WinUI MenuFlyout |
| NSAlert | A WinUI dialog inside the flyout |
| Show in Finder | Show in File Explorer |
| Launch at login | Start with Windows, also listed in Settings > Apps > Startup |
| Show app and macOS servers | Show app and Windows servers |
| ⌘⌫ stop, ⌘R restart, Esc | Delete stop, Ctrl+R restart, Shift+F10 menu, Esc |
| VoiceOver | Narrator: "ops-validation-api, port 8000, running since 11:09 AM" |
| Quit signal, then kill | Ctrl+C, the way a terminal stops it, then end the process tree |
| `~/Library/Application Support/Loco Loco` | `%LOCALAPPDATA%\Loco Loco\history.json`, and logs in `…\Logs` |

Windows only: right-click the octopus for Open Loco Loco, Stop all… and Quit Loco Loco.

## How it's built

`app/windows` is a C# solution, `LocoLoco.slnx`, on .NET 10 and the Windows App SDK (WinUI 3). It's unpackaged and self-contained, so the PC needs nothing installed.

- `src/LocoCore`: the scanner (listening ports from the IP Helper API, then each process's path, command line, folder and parents), naming, history, the launcher and the stopper. It has no UI, so it also builds and tests on a Mac.
- `src/LocoLoco`: the tray app. The tray icon uses H.NotifyIcon (MIT). The octopus in `Art/` draws the app icon, the tray icons and the empty-state octopus from one geometry.
- `src/loco-scan`: prints what the app would list. `loco-scan --all` includes app and Windows servers.
- `tests/LocoCore.Tests`: xUnit. 5 run on Windows only. They start real servers on spare ports and check reading a process's command and folder, scan and stop, restart with a log, a bad command, and a server that needs Force stop.
- `scripts/`: `test.ps1`, `build.ps1` (the two zips in `dist/`), `check.ps1` (runs the app on demo servers and takes the screenshots) and `make-icon.ps1`.

`.github/workflows/windows.yml` runs the tests, builds both zips, runs `check.ps1` and keeps the screenshots and zips as artifacts.

## How it was checked

- On GitHub's Windows Server 2025 machines: all 176 tests pass, both zips build, and `check.ps1` runs the app through open, hover, row menu, ··· menu, dark, stop, Stop all, empty and restart, then checks the result.
- On the Mac: the whole solution builds, and the 171 tests that don't need Windows pass.

## Differences from the plan

- The UI is built in C#, with no XAML files, so it also compiles on a Mac.
- The flow images are screenshots of the real app, not frames drawn in `mockups/`. `mockups/windows.html` only lays them out.
- The tray icon uses the core H.NotifyIcon package, not its WinUI package.
- The build turns on the MSIX tooling (`EnableMsixTooling`), which an unpackaged WinUI app needs for its resources. The app is still unpackaged.
- The first-run notice is a tray balloon, which Windows shows as a notification.
- When the octopus is under ^, the flyout opens above ^, because that's where Windows says the icon is.
- The flyout's content slides in, not the window.
- Ctrl+C is sent by a helper: the app starts itself again with `--ctrl-c`, so it never receives the Ctrl+C itself.
- Stop all stops dev servers only, even when app servers are shown. Stop in a row's menu also works on app servers.
- The badge digits are drawn as pixels on the accent colour, not in Segoe, so they stay sharp at 16 px.
- Names end with an ellipsis, not a cut in the middle.
- The icon buttons use 12 px glyphs. Focus rings are WinUI's own.
- `scripts/check.ps1` is new: it runs the app on CI and takes the screenshots.

## Not checked yet

A real Windows 11 PC: rounded corners and menu acrylic (the CI machines draw neither), the octopus on the taskbar after you drag it out, 125% to 200% scale, Narrator, an Arm64 PC, and 32-bit servers.

## Check it on a Windows 11 PC

1. Download `LocoLoco-1.0.0-windows-x64.zip` from the latest release (`-arm64` on an Arm PC), unzip it, and run `Loco Loco.exe`. If SmartScreen asks, click More info, then Run anyway.
2. Start any local server from a terminal, for example `python -m http.server 8000` in a folder in your user folder.
3. Drag the octopus from ^ onto the taskbar, then click it.
4. Send 3 screenshots: the open flyout, the menu when you right-click a row, and the flyout in dark mode (Settings > Personalization > Colors > Choose your mode).
