# LayoutSwitcher Development Context

## Project Overview

**LayoutSwitcher** (MacKeySwitch) — automatic keyboard layout switcher for macOS, targeting Ukrainian/English bilingual users.

### What it does
- Detects when you type a word in the wrong keyboard layout
- On space/return/tab, analyzes the input using a confidence scoring system
- If confident, erases the word, switches the input source, and retypes it correctly
- Allows undo (⌃⇧Z) to reject a correction and remember not to touch that word again

### Shortcuts (all rebindable in Settings, all registered through Carbon)
| Default | Action |
| --- | --- |
| ⌃⇧Space | Correct the last word on demand, ignoring the confidence score |
| ⌃⇧Z | Undo the last correction and add the word to the exception list |
| ⌃⇧X | Convert the current selection to the other layout |

`DefaultHotkeys` holds these, and a test asserts they are distinct: Carbon refuses a
duplicate combination silently, so a clash would ship as a shortcut that never fires.

### Tech Stack
- **Language**: Swift 5.9
- **Platform**: macOS 13+ (Ventura and later)
- **Frameworks**: Carbon, Cocoa
- **Build**: SwiftPM (not Xcode project)
- **Tests**: Swift Testing framework (via `run-tests.sh`)

### Key Features
- Menu-bar only (no Dock icon)
- Runtime UI language switching (English/Ukrainian)
- Per-app rules (exclude specific apps)
- Password heuristic (does not touch mixed-case + digit/symbol combos)
- Confidence-weighted detection (6 signals, 50k-word bundled dictionaries + macOS spelling dicts)
- Two correction modes: automatic (on space) or only when asked via shortcut
- Selection conversion: convert any selected text, not just the word being typed
- Password fields detected through the system, not guessed from the characters
- URLs, emails and identifiers left alone
- Terminals and code editors excluded by default
- Ad-hoc code signing (pin identity via `MACKEYSWITCH_CODESIGN_IDENTITY` env var for stable permissions)

## Project Structure

The package root *is* the repository root; there is no wrapping directory.

```
├── Sources/
│   ├── LayoutSwitcher/        # Main app target
│   │   ├── Resources/
│   │   │   ├── en_words.txt / ua_words.txt  # Dictionary files (50k words each)
│   │   │   ├── en.lproj / uk.lproj           # Localization strings (non-folded, `.copy` resources)
│   │   ├── DictionaryManager.swift
│   │   ├── InputSourceManager.swift
│   │   ├── PasswordHeuristic.swift
│   │   ├── LanguageDetector.swift
│   │   ├── SettingsView.swift
│   │   ├── Logging.swift
│   │   ├── CorrectionEngine.swift      # Every decision: buffer, when to correct, undo, on-demand
│   │   ├── KeyboardMonitor.swift       # The machinery: event tap, threads, synthetic keys
│   │   ├── CarbonHotkey.swift
│   │   ├── Localization.swift
│   │   ├── SecureInputDetector.swift   # Password fields, via AX subrole + secure input flag
│   │   ├── WordFilter.swift            # Skips URLs, emails, identifiers
│   │   ├── AppBlacklist.swift          # Default-excluded terminals and editors
│   │   ├── SelectionCorrector.swift    # ⌃⇧X: reads the selection, converts, pastes back
│   │   ├── LayoutTransliterator.swift  # Character-level mapping for text with no keycodes
│   │   ├── SystemSpellChecker.swift    # macOS dictionaries behind DictionaryManager
│   │   └── (other modules)
│   └── ObjCExceptionGuard/    # Objective-C exception bridging
├── Tests/
│   └── LayoutSwitcherTests/   # XCTest/Swift Testing suite
│       ├── DictionaryCoverageTests.swift
│       ├── LanguageDetectorTests.swift
│       ├── PasswordHeuristicTests.swift
│       ├── PerAppRulesTests.swift
│       ├── LocalizationTests.swift
│       └── (others)
├── installer/
│   ├── build_app.sh           # Universal signed `.app` build
│   ├── build_installer.sh     # `.pkg` + `.dmg` for distribution
│   └── regrant-permissions.sh # Re-grant Accessibility after rebuild
├── install.sh                 # End-user install script
├── run-tests.sh               # Test runner (needed: locates Testing.framework)
└── Package.swift              # SwiftPM manifest
```

## Development Workflow

### Building
```bash
swift build              # Debug build
swift build -c release   # Release build
```

### Testing
```bash
./run-tests.sh           # Must use this, not `swift test` directly
                         # (SwiftPM + Command Line Tools can't find Testing.framework without it)
```

### Installing locally
```bash
./install.sh             # Builds, installs to /Applications, sets login item, grants permissions
```

### Distributable build
```bash
installer/build_installer.sh  # Creates dist/MacKeySwitch.dmg + .pkg (needs Developer ID + notarization for external distribution)
```

### Re-granting Accessibility after rebuild
```bash
installer/regrant-permissions.sh  # Ad-hoc signatures differ per build; macOS forgets permissions
                                   # or pin identity via: export MACKEYSWITCH_CODESIGN_IDENTITY="Apple Development: ..."
```

## Core Architecture

### Detection Confidence Scoring (LanguageDetector)
Signal-weighted system:
- **+14**: Other-layout reading is a real word
- **−25**: What you typed is a real word (veto)
- **+3**: Typed word contains a letter pair the language never uses
- **+2**: Other-layout is in right script, no impossible pairs
- **+2**: Other-layout starts like some word in target dictionary
- **+2**: Typed word starts like no word in current dictionary

Threshold varies by Sensitivity (Medium = 10, default).

### Dictionary Lookup Chain
1. Bundled 50k-word lists (en_words.txt, ua_words.txt) — fast, local
2. macOS spelling dictionaries (system-wide) — slow but comprehensive

Bundled lists alone insufficient (e.g., Ukrainian list has no words starting "при").

### Localization (Runtime Language Switch)
- Strings live in `Sources/LayoutSwitcher/Resources/<code>.lproj/Localizable.strings`
- Non-folded `.copy` resources (app picks `.lproj` at runtime)
- `LocalizationTests` enforces consistency (keys, format specifiers)
- To add language: copy `en.lproj`, translate, add code to `AppLanguage`, update `Package.swift` and `build_app.sh`
- Verify: `LayoutSwitcher --print-diagnostics` shows loaded tables

### Logging — read this before debugging anything
There is no logging in release builds, by decision. A menu-bar agent launched from Finder
has **nowhere to send stdout**, NSLog from this ad-hoc-signed bundle was measured not to
reach the unified log, and the file log that once lived in `~/Library/Logs` was removed.

`debugLog` in `Logging.swift` prints to stdout in **debug builds only**. To observe a run:

```bash
swift build && .build/debug/LayoutSwitcher
```

(Quit the installed copy first — the single-instance guard exits the second one.)

Worth remembering: three separate faults here were only found once something could
report. If a release build silently does nothing, reproduce it with a debug build from a
terminal before theorising — two speculative fixes shipped here for lack of that.

### What It Does NOT Touch
- Password fields — `SecureInputDetector` asks the system (AX subrole, then the
  process-wide secure input flag). `PasswordHeuristic` still runs first as a cheap guess.
  Note the fallback direction: an app that exposes no subrole is an **ordinary** field.
  Treating silence as unsafe once disabled correction everywhere.
- URLs, emails and identifier-shaped text (`WordFilter`)
- Terminals and code editors (`AppBlacklist`, overridable per app in Settings)
- Words in excluded apps (Settings → Per-App Rules)
- Previously rejected words (user undo/backspace)
- First word after manual layout switch

### Permissions Model
- **Accessibility** (system keystroke capture + paste)
- **Input Monitoring** (implicit in Accessibility on recent macOS)
- **Login Item** (via SMAppService or `launchd`, set during install)
- No app-level grant; all permissions require macOS System Settings + user confirmation

## Code Conventions & Patterns

### Threading & Main Thread
- Carbon/Cocoa APIs (keystroke capture, InputSourceManager) require main thread
- Use DispatchQueue.main for UI updates and OS callbacks
- Check: Async/await in Detection vs sync Main-thread calls

### Memory & Lifecycle
- Keep Carbon hot keys alive (strong reference in CarbonHotkey)
- Event tap callbacks: guard against deallocated owner
- Localization strings: cached at app launch to avoid repeated filesystem I/O

### Testing
- Use `TestSupport.swift` for common fixtures (mock dicts, test strings)
- `CorrectionEngineTests` drives the whole decision logic with a scripted keyboard and a
  fake environment (layout, dead keys, secure input, clock). Anything the monitor decides
  is testable there; if a bug is found in KeyboardMonitor itself, it belongs in the engine
- `DictionaryCoverageTests` documents bundled dictionary gaps
- `LocalizationTests` prevents runtime crashes from missing keys/format mismatches
- Password heuristic is extensively tested (edge cases matter)

## Known Constraints

1. **Ad-hoc signing ≠ stable permissions**: Every rebuild = new signature → macOS re-adds to Accessibility list as "new app" → re-grant needed (or pin identity)
2. **Corrections only on space**: Return/Tab too late; keystrokes already sent / focus already moved
3. **Async detection**: Correction applies after keystroke already displayed; rare out-of-order scenarios possible
4. **Bundled dicts + macOS dicts**: Coverage is good but not perfect (DictionaryCoverageTests documents misses)
5. **No Cmd+Z undo inside app**: Revert is via the shortcut (⌃⇧Z), not native undo (each correction is async)
6. **Layout is read live at word start**: the cached layout is fed by a distributed
   notification that arrives late — reliably so right after the app's own switch — and a word
   attributed to the previous layout "corrects" into the text already on screen
7. **Selection conversion borrows the pasteboard**: `AXSelectedText` is optional and most
   browsers and editors do not publish it, so the fallback is ⌘C. The original pasteboard is
   snapshotted and restored, but the converted text is briefly on it
8. **Synthetic ⌘C/⌘V wait for the shortcut's modifiers to be released**: the physical keys
   are still down when the hotkey fires, so an app would otherwise see ⌃⇧⌘V, not Paste

## Common Tasks & Commands

| Task | Command |
| --- | --- |
| Debug build | `swift build` |
| Run tests | `./run-tests.sh` |
| Install locally | `./install.sh` |
| Make `.dmg` for distribution | `installer/build_installer.sh` |
| Check localization coverage | `dist/MacKeySwitch.app/Contents/MacOS/LayoutSwitcher --print-diagnostics` |
| Add new language | Copy `en.lproj` → `new_code.lproj`, translate, update `AppLanguage` enum, `Package.swift`, `build_app.sh` |
| Re-grant Accessibility | `installer/regrant-permissions.sh` |
| Pin code-signing identity | `export MACKEYSWITCH_CODESIGN_IDENTITY="Apple Development: you@example.com"` |

## Testing Coverage Checklist

- [ ] Unit tests in `run-tests.sh` all pass (146 tests, 18 suites)
- [ ] Localization tests verify all tables complete and format-correct
- [ ] Dictionary coverage tests document any gaps
- [ ] Password heuristic tests cover edge cases
- [ ] Per-app rules tests verify app filtering works
- [ ] Hotkey binding tests ensure macro recorders work

## Debugging Tips

1. **Keystroke not triggering**: Check Accessibility grant (System Settings → Privacy & Security)
2. **Corrections not working**: Enable logging via `Logging` module, run `--print-diagnostics`
3. **Permission lost after rebuild**: Run `regrant-permissions.sh` or pin identity
4. **Wrong UI language**: Settings → General → Interface language + restart app (no full relaunch needed)
5. **Test framework not found**: Use `./run-tests.sh` instead of `swift test`

## Contact & License

- **Author**: Oleksandr Kuzmin, 2026
- **Licence**: GPL-3.0 (see LICENSE)
- **Repo**: https://github.com/OleksandrK-Automat-IT/MacKeySwitch
