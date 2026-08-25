# LayoutSwitcher Development Context

## Project Overview

**LayoutSwitcher** (MacKeySwitch) — automatic keyboard layout switcher for macOS, targeting Ukrainian/English bilingual users.

### What it does
- Detects when you type a word in the wrong keyboard layout
- On space/return/tab, analyzes the input using a confidence scoring system
- If confident, erases the word, switches the input source, and retypes it correctly
- Allows undo (⌃⇧Z) to reject a correction and remember not to touch that word again

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
- Confidence-weighted detection (14 signals, 50k-word bundled dictionaries + macOS spelling dicts)
- Ad-hoc code signing (pin identity via `MACKEYSWITCH_CODESIGN_IDENTITY` env var for stable permissions)

## Project Structure

```
LayoutSwitcher/
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
│   │   ├── CarbonHotkey.swift
│   │   ├── Localization.swift
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

### What It Does NOT Touch
- Passwords (heuristic: mixed case + digit/symbol, ≥6 chars)
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
- `DictionaryCoverageTests` documents bundled dictionary gaps
- `LocalizationTests` prevents runtime crashes from missing keys/format mismatches
- Password heuristic is extensively tested (edge cases matter)

## Known Constraints

1. **Ad-hoc signing ≠ stable permissions**: Every rebuild = new signature → macOS re-adds to Accessibility list as "new app" → re-grant needed (or pin identity)
2. **Corrections only on space**: Return/Tab too late; keystrokes already sent / focus already moved
3. **Async detection**: Correction applies after keystroke already displayed; rare out-of-order scenarios possible
4. **Bundled dicts + macOS dicts**: Coverage is good but not perfect (DictionaryCoverageTests documents misses)
5. **No Cmd+Z undo inside app**: Revert is via the shortcut (⌃⇧Z), not native undo (each correction is async)

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

- [ ] Unit tests in `run-tests.sh` all pass (116+ tests)
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
- **Repo**: https://github.com/OleksandrK-Automat-IT/dba_work/tree/main/LayoutSwitcher
