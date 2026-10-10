# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

(Closest bare value. The product is a native macOS 26 Tahoe menu bar app; Apple HIG for macOS governs.)

## Stack

Swift 6 + SwiftUI hosted in a borderless panel under an `NSStatusItem` (so the panel's surface is ours), AppKit `NSMenu` for the context and ··· menus, libproc/sysctl for process data. Built with SwiftPM from Command Line Tools (no Xcode on this Mac), bundled as `Loco Loco.app`, ad-hoc signed.

## Users

Rakshit, a designer-engineer who runs many local dev servers at once (Next.js, Vite, uv/Python APIs, static deck servers), mostly started from Cursor terminals and Copilot CLI sessions, across several projects and git worktrees.

## Product Purpose

Loco Loco is a menu bar extra that shows every local dev server that is running, stops any of them in one click, and keeps a history so a stopped server restarts with the same command in the same folder. Success: he never opens a terminal or `lsof` to find, free, or bring back a port.

## Positioning

It records how each server was started (folder + command), so Restart works even for servers it did not launch, including ones stopped with Ctrl+C elsewhere.

## Operating Context

- 10+ listeners at a time; ports collide (3000 is used by two projects).
- Servers are often launched by agents through `bash -c 'cd … && …'` wrappers, so the listening process is several levels below the command a person would re-run.
- Wrappers rewrite their titles (`pnpm dev`, `next-server (v16.3.3)`, `npm exec vite preview …`).
- Other apps also listen on ports (Figma, OneDrive, GitHub Copilot, AirPlay); these are not dev servers.

## Capabilities and Constraints

- Shows dev servers only by default; "Show app and macOS servers" in the ··· menu includes the rest.
- Stop is one click (graceful, then Force stop if needed).
- Restart runs in the background; output goes to a log he can open from the app.
- History is local only; stores folder, command and PATH, never other environment variables.
- Menu bar only (no Dock icon), launch at login.
- Can only see and stop processes owned by the current user.
- Settings live in the ··· menu; there is no Settings window.
- Decided: name Loco Loco; count next to the icon (can be turned off); Stop all… with one confirmation; 20 servers of history (10, 20 or 50); Open in Terminal and Open in Cursor.

## Brand Commitments

Apple HIG for behaviour: system font, SF Symbols for actions, Light and Dark appearance, real NSMenus with the system glass and accent highlight. The look of the panel follows Notion and Linear (researched on Mobbin): a solid surface, groups with a count in the header, quiet 28pt rows, sentence case.

Identity: an octopus, so it feels friendly rather than technical. Deep sea: a white line octopus on navy (#16465A to #0D2B3B) for the app icon, a solid octopus in the menu bar that closes its eyes when nothing runs, and a small sleeping line octopus in the empty panel.

## Evidence on Hand

Real servers running on 2026-10-09 (ports 3000, 3001, 4193, 4211, 4322, 4323, 8000, 8090, 8103, 8741) and their launch chains; project registry at `~/.copilot/skills/run-on-localhost/references/projects.md`.

## Product Principles

- The port and the project name are the content; nothing else earns space.
- One click for the common action, a menu for the rest.
- Never lose how a server was started.
- Never stop something that is not a dev server without being asked.

## Accessibility & Inclusion

VoiceOver labels for every row and action, full keyboard navigation in the panel, Reduce Motion and Increase Contrast respected.
