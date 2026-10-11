# Changelog

## [1.11.4] - 2026-10-12

### Features
- A menu-bar app that cannot be read stays visible without preventing known apps from collapsing.

### Design Rationale
- Verified on macOS 27.0.1: `com.apple.UIKitSystemApp` returns AX error -25204, previously aborting the entire inventory. Retain that bundle in the visible allow-list instead of guessing its position or blocking all hiding.

### Notes & Caveats
- A visible fallback wins over readable hidden siblings from the same bundle. Cancelled walks and failures without an identifiable bundle still leave the whole bar expanded.

## [1.11.3] - 2026-10-12

### Features
- Show actionable permission help at startup and after an explicit arrow click, including an Open System Settings button and the macOS 27 permission-page name.

### Design Rationale
- Automatic retries stay quiet; explicit failed toggles explain why the menu bar stays expanded. Handle mouse-up toggles on the next run-loop turn so a released button is not mistaken for a drag.

### Notes & Caveats
- The user must grant the system privacy permission. A newly signed local build may require the permission entry to be re-added.
- Other hiding failures show a retry explanation; logs retain technical diagnostics.

## [1.11.2] - 2026-10-11

### Features
- Added `scripts/build-local-direct.sh` to build and ad-hoc sign a local Direct app, with checks for App Sandbox and the native macOS 27 engine.
- Restored the draggable `|` boundary on macOS 27, with localized accessibility labels and tooltips.

### Fixed
- Pause hiding and cancel Accessibility walks during Command-drag; discard late activations that would interfere with dragging.
- Read the divider position after asynchronous inventory delivery, and rebuild sections when always-hidden settings change.
- Cancel an in-flight collapse by clicking the arrow again. Avoid duplicate visibility requests and cancel disabled auto-hide timers.
- Initialize preferences and layout direction before creating menu-bar items.
- Fail open on uncertain AX reads. Reveal the always-hidden area for rearrangement and re-read positions after a short settling delay.
- Preserve Command-based global shortcuts: expand immediately, and defer collapse until key-up.

### Design Rationale
- Reuse the upstream native engine. A sandboxed v1.11 install on macOS 27.0.1 cannot use it; explicitly selecting `Release-Direct` avoids reproducing that build configuration mistake.
- Keep a fixed-width divider so the tutorial and arrangement gestures stay consistent across macOS versions. Interrupted inventories fail open rather than applying a partial allow-list.

### Notes & Caveats
- Local builds are not notarized. Run from `/Applications` and allow Accessibility. Native hiding uses a private framework and applies per app.
- The legacy installed app can be retained for rollback. Sandboxed preferences may need to be reconfigured in the Direct app.
- On macOS 27 the arrow may sit on either side of the divider, since this app's bundle stays visible. Older macOS versions retain the legacy arrangement requirement. Drag responsiveness still depends on the macOS menu-bar implementation; automated tests cover cancellation races, not frame-time performance.

## v1.11.1 (2026-09-18)

### Fixed
- macOS 27: the Preferences window showed a "Custom View" placeholder instead of the General/About tabs, and the label overlapped the window once clicked (#406).

## v1.11 (2026-09-18)

Requires macOS 13 Ventura or later. (Pre-Ventura users: stay on
[v1.10](https://github.com/dwarvesf/hidden/releases/tag/v1.10).)

### Added
- Opt-in hover-to-expand: set `defaults write com.dwarvesv.minimalbar hoverToExpand -bool true` to expand the bar when the pointer dwells in the menu bar.
- Right-clicking the expand/collapse arrow now opens the same context menu as the separator, so Preferences is reachable from the control you already click.

### Fixed
- macOS 27 (direct download build): hiding works again (#360) using macOS 27's native menu-bar visibility instead of widening the separator, which macOS 27 ejects from the bar. The arrow is the boundary: icons ⌘-dragged to its left hide when collapsed. Needs the Accessibility permission, and Hidden Bar must run from /Applications. Hiding is per app, and macOS's own items always stay visible. The App Store build is unchanged for now.
- Enabling the always-hidden section at runtime no longer creates an invisible (0pt) separator.
- Multi-display: the collapse width is now sized for the widest attached screen, so icons no longer leak on wider external monitors; the width re-applies on display hot-plug.
- Auto-collapse no longer fires while you are interacting with the menu bar (the timer defers and re-arms while the pointer is in the bar).
- The Preferences window no longer closes when auto-collapse fires with "use full menu bar on expanding" enabled (#170, #66, #151).
- Status items that were dragged off the bar are restored at launch instead of leaving the app unreachable.
- Fixed constraint and observer leaks in the tutorial view rebuild.
- Tutorial strings and F-key shortcut labels now render correctly (no more private-use glyphs).

### Changed
- Start-at-login now uses `SMAppService` (macOS 13+); the legacy launcher helper was removed and any leftover login item is deauthorized automatically on first launch.
- Pinned the HotKey dependency to an exact version and removed an unused file-access entitlement and dead code (no behavior change).

### Known / in progress
- macOS 27, App Store build: hiding still does not work (#360). Native hiding needs Accessibility reads that the App Sandbox blocks; an App Store approach is tracked separately.
- New menu-bar icons can appear in the hidden zone because macOS inserts them at the far left; ⌘-drag them to the right of the separator (see the manual). A built-in pin is part of the planned redesign.
