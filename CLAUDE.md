# LayoutSwitcher Development Context

## Project Overview

**LayoutSwitcher** (MacKeySwitch) — automatic keyboard layout switcher for macOS, targeting Ukrainian/English and Russian/English bilingual users.

### What it does
- Detects when you type a word in the wrong keyboard layout
- On space/return/tab, analyzes the input using a confidence scoring system
- If confident, erases the word, switches the input source, and retypes it correctly
- Allows undo (⌃⇧Z) to reject a correction and remember not to touch that word again

### Shortcuts (all rebindable in Settings → Shortcuts, all registered through Carbon)
| Default | Action |
| --- | --- |
| ⌃⇧Space | Correct the last word on demand, ignoring the confidence score |
| ⌃⇧Z | Undo the last correction; with nothing to undo, convert the last word |
| ⌃⇧X | Convert the current selection to the other layout |

The undo key is a **toggle on the last word**, not only an undo. Pressed on a word the app
never touched it converts it, because every report about that key described it that way.
Undo teaches an exception only for the app's own corrections — reverting a conversion the
user asked for says nothing about the word, and learning from it would have silenced the
automatic pass on that word for good.

A conversion asked for by shortcut always ends in a space, whether or not one was erased;
an automatic correction puts back exactly the space it erased.

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
- Confidence-weighted detection (6 signals, 100k-word frequency dictionaries + macOS spelling dicts)
- Two correction modes: automatic (on space) or only when asked via shortcut
- Exact geometry support for Apple `Ukrainian`, `Ukrainian-PC`, `Russian` and `RussianWin`
- Russian ships a bundled list like the other two, but no impossible-bigram list: those
  are corpus-validated by hand, and nobody has done that pass for Russian yet — the +3
  signal simply never fires for it
- The switching pair is a setting: Settings → General, and a submenu under the menu-bar
  icon. "Automatic" follows the last-used Cyrillic layout

### Layout pairing — read before touching `Language`
Switching happens in **pairs**: English ↔ Ukrainian, English ↔ Russian. A Cyrillic word
always goes back to English; an English-typed word goes to the Cyrillic layout the user
**last worked in**, unless a pair is pinned in Settings → General or the menu-bar
submenu (`SettingsModel.cyrillicPair` → `InputSourceManager.pinnedCyrillic`; a pin naming
a layout that is not enabled is ignored). The automatic rule is
`InputSourceManager.preferredCyrillicLanguage()`, fed by every
`currentLanguage()` read and by `switchTo`, **persisted in UserDefaults** as
`lastUsedCyrillicLanguage` because relaunches are far more frequent than language
changes). Never Cyrillic to Cyrillic — the two share too many keys to tell apart, and it
is not what the app is for. With no Cyrillic layout enabled, English words are left alone.

A fresh install has no memory yet and falls back to the first enabled Cyrillic layout in
the system's order — so "typed Привет in English and nothing happened" on a new machine
usually means Russian has never been the active layout. Once it has been, it is remembered.

`Language.opposite` is the *historical* pair (Cyrillic → English, English → Ukrainian) and
exists for tests and callers that predate Russian. Anything that decides a target must go
through `correctionTarget(cyrillic:)` with the preferred Cyrillic layout — the engine and
the selection converter do. `LanguageDetector.detectIntended` takes the target explicitly.

The Russian key table is the Ukrainian column with four overrides (`ъ ы э ё` on the keys
that print `ї і є ґ`), measured with `UCKeyTranslate`, and `DeadKeyTests` holds every
recognised layout to the live one — including the Apple quirk that Shift+ё on RussianWin
prints Latin `Ë` (U+00CB). Reproduce what the screen shows; do not "fix" the layout.
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
│   │   │   ├── en_words.txt / ua_words.txt / ru_words.txt  # Frequency dictionaries (100k each)
│   │   │   ├── DICTIONARY-NOTICES.md         # Corpus provenance and licences
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
│       ├── CorrectionEngineTests.swift # The decision logic, on a scripted keyboard
│       ├── RussianLayoutTests.swift    # Key table, pairing, engine, transliteration
│       ├── RussianDictionaryCoverageTests.swift
│       ├── DictionaryCoverageTests.swift
│       ├── LanguageDetectorTests.swift
│       ├── PasswordHeuristicTests.swift
│       ├── PerAppRulesTests.swift
│       ├── LocalizationTests.swift
│       └── (others)
├── Scripts/                       # Reproducible frequency-dictionary generator and seeds
├── installer/
│   ├── build_app.sh           # Universal signed `.app` build
│   ├── build_installer.sh     # `.pkg` + `.dmg` for distribution
│   └── regrant-permissions.sh # Re-grant Accessibility after rebuild
├── dictionaries/              # Optional word lists (~11MB), imported by hand, not bundled
├── install.sh                 # End-user install; --skip-permissions for rebuilds
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
**The user installs; the agent does not.** Verify a change with `swift build` and
`./run-tests.sh`, commit, and say it is ready to install. Do not run `install.sh`,
`build_installer.sh`, or copy anything into `/Applications` — installing also relaunches
the app under the user, which is theirs to time.

```bash
./install.sh --skip-permissions   # Rebuild, install, relaunch — the way to iterate
./install.sh                      # First install only: also walks through the privacy grants
```

Never run the bare form for a rebuild: its permission step calls `regrant-permissions.sh`,
which does `tccutil reset Accessibility` and so **removes** a grant that was working. On
this machine ad-hoc rebuilds have kept the grant so far; the reset is what loses it.

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

### The seam: CorrectionEngine vs KeyboardMonitor
`CorrectionEngine` holds every decision — the key buffer, whether a word is worth
correcting, what undo and the on-demand shortcut should do — as plain main-thread code with
no locks and no system calls of its own. Everything it needs from the world arrives through
`CorrectionEnvironment` (layout, dead keys, secure input, the clock) and `CorrectionSettings`.
It answers with a `CorrectionPlan`: what to erase, what to type, which layout to switch to.

`KeyboardMonitor` is the machinery — event tap, threads, synthetic keystrokes — and executes
plans without deciding anything. A bug in behaviour belongs in the engine and gets a test;
a bug in delivery (ordering, modifiers, timing) belongs in the monitor and usually cannot be
unit-tested, so it gets a comment saying what was measured.

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
1. Bundled 100k-word frequency lists (en_words.txt, ua_words.txt, ru_words.txt) — fast,
   local, generated by `Scripts/build_frequency_dictionaries.py` from the source lists in
   `dictionaries/`. Regeneration is a fixed point: run it twice, get the same checksums
2. Imported files (Settings → Dictionary: choose or drop a file, and `DictionaryManager.survey`
   names its language from the alphabets before anything is added — a picker pre-filled
   with the answer, not a question asked first) plus custom words stored by earlier
   versions, still loaded but no longer addable in the UI

Detection asks two questions with different evidence. Latin against Cyrillic is settled by
the totals, which is decisive because the scripts share no letters. Ukrainian against
Russian cannot be: most Russian words are spellable with Ukrainian letters too, and the
real 150k list scores only 1.23:1 — inside any sane margin. That question is decided on
words *no* other alphabet can spell, of which that list has 28,307 and Ukrainian none.
`dictionaries/` holds the optional lists, and `BundledOptionalDictionariesTests` holds each
to its language and format — it is what caught the totals rule being wrong.
3. macOS spelling dictionaries (system-wide) — slow but comprehensive

The system spelling dictionaries extend the bounded bundled lists with names, rare forms,
and newer vocabulary.
`isRussianPrefix` still answers "could be" when its index is empty — with no corpus there
is no basis to call a prefix invalid, and saying so would hand every Russian word an
unearned +2. That stopped being the normal path when `ru_words.txt` started shipping, but a
build without it must still behave.

### Localization (Runtime Language Switch)
- Strings live in `Sources/LayoutSwitcher/Resources/<code>.lproj/Localizable.strings`
- Non-folded `.copy` resources (app picks `.lproj` at runtime)
- `LocalizationTests` enforces consistency (keys, format specifiers)
- **Every view that calls `L(...)` needs `@ObservedObject private var l10n = Localization.shared`.**
  `L` is a plain function, so nothing else tells SwiftUI to re-render it. All tabs stay
  mounted (see the `ZStack` in `SettingsView`), so a view without the observer keeps the
  language it first rendered in — for the life of the window. Three tabs shipped that way.
  Nothing catches this but looking: the tables are complete, the keys resolve, the wrong
  language is simply never redrawn
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

To watch the *installed* app instead, drop the debug binary into the bundle and launch it
with stdout redirected — stdout is line-buffered from `main.swift`, so the log fills as it
goes rather than at exit:

```bash
cp .build/debug/LayoutSwitcher /Applications/MacKeySwitch.app/Contents/MacOS/LayoutSwitcher
codesign --force --deep --sign - /Applications/MacKeySwitch.app
nohup /Applications/MacKeySwitch.app/Contents/MacOS/LayoutSwitcher > "$TMPDIR/mks.log" 2>&1 &
```

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
- First word after a manual layout switch, for `manualSwitchWindow` (2 s). This is the
  usual reason a *quick test* fails: switch layout, switch back, type at once — the word
  lands inside the window and is skipped by design. Wait a couple of seconds or type
  something else first.

### Permissions Model
- **Accessibility** (system keystroke capture + paste)
- **Input Monitoring** (implicit in Accessibility on recent macOS)
- **Login Item** (via SMAppService or `launchd`, set during install)
- No app-level grant; all permissions require macOS System Settings + user confirmation

### Settings window
Tabs, in order: General, Detection, Per-App Rules, Dictionary, Statistics, Shortcuts,
About (`SettingsTab`). All are mounted at once inside a `ZStack` and hidden with
`settingsTabVisibility`, so local state survives switching — and so a missing `l10n`
observer freezes a tab's language (see Localization).

Anything with an ideal width wider than the window renders centred and clipped at both
edges: keep tab content inside the grouped `Form` rather than a bare `VStack`, which is
what the exceptions editor was until it was moved into one.

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
- A modifier chord reaches the tap **before** the Carbon hotkey fires, so the engine must
  keep the word alive across it — both the finished word and the one still being typed.
  Clearing it there is what made the on-demand shortcut find nothing, twice
- `CorrectionEngineTests` drives the whole decision logic with a scripted keyboard and a
  fake environment (layout, dead keys, secure input, clock). Anything the monitor decides
  is testable there; if a bug is found in KeyboardMonitor itself, it belongs in the engine
- `FrequencyDictionaryTests` verifies corpus size, uniqueness, ordering, validity, and core coverage
- `LocalizationTests` prevents runtime crashes from missing keys/format mismatches
- Password heuristic is extensively tested (edge cases matter)

## Known Constraints

1. **Ad-hoc signing ≠ stable permissions**: Every rebuild = new signature → macOS re-adds to Accessibility list as "new app" → re-grant needed (or pin identity)
2. **Corrections only on space**: Return/Tab too late; keystrokes already sent / focus already moved
3. **Async detection**: Correction applies after keystroke already displayed; rare out-of-order scenarios possible
4. **Bundled dicts + macOS dicts**: Coverage is good but not perfect (DictionaryCoverageTests documents misses)
   — the erase-to-retype gap is a fixed 10 ms (`KeyboardMonitor.eraseToRetypeGapMs`); it
   was a 10–200 ms slider that nobody ever needed above its floor
5. **No Cmd+Z undo inside app**: Revert is via the shortcut (⌃⇧Z), not native undo (each
   correction is async). Binding it to a bare ⌃Z works, but Carbon then takes that
   combination system-wide, and apps where it is the native undo lose it
6. **Layout is read live at word start**: the cached layout is fed by a distributed
   notification that arrives late — reliably so right after the app's own switch — and a word
   attributed to the previous layout "corrects" into the text already on screen. The exact
   source ID is retained too: Apple's `Ukrainian` layout swaps И/І compared with
   `Ukrainian-PC` and uses a different backtick key
7. **Selection conversion borrows the pasteboard**: `AXSelectedText` is optional and most
   browsers and editors do not publish it, so the fallback is ⌘C. The original pasteboard is
   snapshotted and restored, but the converted text is briefly on it
8. **Anything a shortcut posts waits for that shortcut's modifiers to be released**: the
   physical keys are still down when the hotkey fires, and the window server folds the
   hardware modifier state into every posted event. Without the wait the backspaces went out
   as ⌃Backspace and the replacement letters as control chords — the word vanished and
   nothing replaced it — and the paste arrived as ⌃⇧⌘V. Both the selection converter and
   the monitor's shortcut-driven plans wait, up to a second so a stuck key cannot stall
   them, and typed events are posted with empty flags. Automatic corrections do not wait:
   space carries no modifier, and the wait would cost them their speed

## Common Tasks & Commands

| Task | Command |
| --- | --- |
| Debug build | `swift build` |
| Run tests | `./run-tests.sh` |
| Rebuild and reinstall | `./install.sh --skip-permissions` — the user's to run, not the agent's |
| First install (with permission walkthrough) | `./install.sh` |
| Make `.dmg` for distribution | `installer/build_installer.sh` |
| Check localization coverage | `dist/MacKeySwitch.app/Contents/MacOS/LayoutSwitcher --print-diagnostics` |
| Add new language | Copy `en.lproj` → `new_code.lproj`, translate, update `AppLanguage` enum, `Package.swift`, `build_app.sh` |
| Re-grant Accessibility | `installer/regrant-permissions.sh` |
| Pin code-signing identity | `export MACKEYSWITCH_CODESIGN_IDENTITY="Apple Development: you@example.com"` |

## Testing Coverage Checklist

- [ ] Unit tests in `run-tests.sh` all pass (272 tests, 35 suites)
- [ ] Localization tests verify all tables complete and format-correct
- [ ] Frequency dictionary tests verify generated corpus invariants and core vocabulary
- [ ] Password heuristic tests cover edge cases
- [ ] Per-app rules tests verify app filtering works
- [ ] Hotkey binding tests ensure macro recorders work

## Debugging Tips

1. **Keystroke not triggering**: Check Accessibility grant (System Settings → Privacy & Security)
2. **Corrections not working**: run a debug build from a terminal and watch `debugLog`
   (see Logging above). Every branch that declines to act says so: `Nothing to undo`,
   `Nothing to convert`, `Aborted: editing context changed`, or the score line for the word
3. **Permission lost after rebuild**: Run `regrant-permissions.sh` or pin identity — and
   check it was not `./install.sh` without `--skip-permissions` that removed it
4. **English word not corrected into Russian**: the pair is pinned in Settings → General,
   or automatic — the *last-used* Cyrillic layout, which Russian must have been at least
   once. Either way the word must not be the first within 2 s of a manual layout switch
5. **A tab stuck in the old interface language**: it is missing the `l10n` observer — see
   Localization above
6. **Wrong UI language**: Settings → General → Interface language + restart app (no full relaunch needed)
7. **Test framework not found**: Use `./run-tests.sh` instead of `swift test`

## Contact & License

- **Author**: Oleksandr Kuzmin, 2026
- **Licence**: GPL-3.0 (see LICENSE)
- **Repo**: https://github.com/OleksandrK-Automat-IT/MacKeySwitch
