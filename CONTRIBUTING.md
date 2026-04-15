# Contributing to Notch Pilot

Thanks for wanting to help. This is a small project with a light contribution bar — just try to match the existing code style and keep PRs focused.

## Setup

```sh
git clone https://github.com/YOUR_USERNAME/notch-pilot.git
cd notch-pilot
swift build
open ".build/debug/NotchPilot"   # or: swift run
```

macOS 14+ and Swift 5.9+ required. No external dependencies — all standard library + system frameworks.

## Project layout

```
Sources/NotchPilot/
├── NotchPilotApp.swift          # @main entry point
├── AppDelegate.swift            # App startup, services wiring
├── NotchWindow.swift            # NSPanel subclass sized to content
├── NotchContentView.swift       # Main SwiftUI view — collapsed pill + expanded panel
├── BuddyFace.swift              # All 6 buddy styles + modes / colors
├── BuddyPreferences.swift       # UserDefaults-backed appearance + sound prefs
│
├── ClaudeMonitor.swift          # Polls ~/.claude/projects/*.jsonl → ClaudeSession list
├── HeatmapAggregator.swift      # Daily activity heatmap data source
├── MouseMonitor.swift           # Polls cursor position for hover-summon
│
├── SocketServer.swift           # POSIX Unix domain socket listener
├── HookBridge.swift             # Routes hook events into published UI state
├── HookInstaller.swift          # First-launch install of hook.js + settings.json
├── VoiceAnnouncer.swift         # AVSpeechSynthesizer wrapper
└── TerminalJumper.swift         # libproc-based claude-PID → terminal app jump
```

No frameworks. No package dependencies. It should `swift build` on a fresh checkout with no setup.

## Adding a new buddy style

All six buddies live in `BuddyFace.swift`. To add a seventh:

1. **Add a case to `BuddyStyle`:**
   ```swift
   enum BuddyStyle: String, CaseIterable, Identifiable {
       case eyes, orb, bars, ghost, cat, bunny
       case mynewbuddy                       // ← add here
       // ...
       var label: String {
           switch self {
           // ...
           case .mynewbuddy: return "My New Buddy"
           }
       }
   }
   ```

2. **Create a `private struct MyNewBuddyBuddy: View`** inside `BuddyFace.swift`, taking `mode: BuddyFace.Mode`, `size: CGFloat`, `color: BuddyColor`. Model it on `EyesBuddy` or `GhostBuddy`. Handle all 7 modes (`sleeping`, `idle`, `active`, `curious`, `content`, `focused`, `shocked`). Use the shared `runBlinkLoop` helper for blinks if you have eyes.

3. **Dispatch to it in `BuddyFace.body`:**
   ```swift
   case .mynewbuddy: MyNewBuddyBuddy(mode: mode, size: size, color: prefs.color)
   ```

4. **Add a preview in `NotchContentView.stylePreview(_:)`** — a tiny static rendering used in the picker chips.

5. Run `swift build` and test by selecting your buddy from the appearance picker.

Mode semantics (what each one should feel like):

| Mode | When it fires | Should feel like |
|---|---|---|
| `sleeping` | Claude not running, no recent activity | Eyes closed, still, low opacity |
| `idle` | Hover-summoned, no activity | Calm, alive, slow blinks |
| `active` | Claude running a tool (non-edit, non-danger) | Energetic, pulsing, breathing |
| `curious` | Permission request pending | Alert, wider, darting |
| `focused` | Claude editing files | Concentrated, narrow, steady |
| `content` | 10-second fadeout after activity ends | Happy, slow, relaxed blinks |
| `shocked` | Dangerous command detected | Frozen, wide-eyed, red |

## Adding a new color

1. Add a case to `BuddyColor`.
2. Fill in `label` and `base` (hex → `Color(red: ..., green: ..., blue: ...)`).
3. The `glow` variant is derived automatically.

That's it — every buddy uses the shared color palette.

## Adding a new voice event

1. Add a case to `VoiceEvent` in `BuddyPreferences.swift` with a label + SF Symbol icon name.
2. At the site where the event happens, call `VoiceAnnouncer.shared.speak("...", event: .yourNew, prefs: prefs)`.
3. The toggle row will automatically appear in the appearance picker.

## Code style

- **No force unwraps** except in `NotchWindow.init` where `NSScreen.main` is genuinely fatal.
- **No force-try.** Use `try?` + graceful fallback everywhere.
- **No external dependencies.** If you need a library, raise it as an issue first.
- **Comment the `why`, not the `what`.** The `what` should be clear from well-named variables.
- **`@MainActor`** on any class that owns `@Published` UI state.
- **Background work** goes in `Task.detached(priority: .utility)` and hops back to main with `await MainActor.run { ... }`.
- **Keep files small where it makes sense.** ~500 lines is a good rough ceiling for logic files. The two exceptions are `NotchContentView.swift` (the top-level SwiftUI panel) and `BuddyFace.swift` (the character catalog) — both are intentionally large because breaking the panel into sub-views churns state, and the buddies are each a small View struct next to their siblings. Don't add a new section to the panel or a new buddy style inline if the file is already huge; extract into a new file instead.

## Running tests

There aren't any yet. Contributions of unit tests for the parsers (`ClaudeMonitor.parseLastEntry`, `HeatmapAggregator.scanToday`) would be very welcome — they're the parts most likely to regress.

## Questions

Open an issue — it's the best place for design discussion before you sink time into a PR.
