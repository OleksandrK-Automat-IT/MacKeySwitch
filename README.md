# MacKeySwitch

Automatic keyboard layout switcher for macOS, for people who type in both Ukrainian and
English and keep starting a word in the wrong one.

When you type `ghbdsn` and hit space, it notices that those keystrokes spell `привіт` on
the other layout, erases the word, switches the input source, and retypes it. Press the
undo shortcut (⌃⇧Z by default) if it guessed wrong — and it will remember not to touch
that word again.

If you would rather it never acted on its own, Settings → Correction mode → *Only on
shortcut* turns the automatic pass off and leaves the engine available on demand.

Menu-bar only; no Dock icon, no window unless you open Settings.

The interface itself speaks English and Ukrainian — Settings → General → Interface language,
applied immediately, no relaunch.

## Shortcuts

All three are global, rebindable in Settings, and enabled by default.

| Default | What it does |
| --- | --- |
| ⌃⇧Space | Correct the last word now |
| ⌃⇧Z | Undo the last correction, and remember not to touch that word again |
| ⌃⇧X | Convert the selected text to the other layout |

**⌃⇧Space works in both modes**, and that is most of its value. A correction needs a
confident score before it will act unasked, so a word the dictionaries are unsure of is
left alone — pressing the shortcut says "yes, that one" and converts it regardless. It
acts on the word you are typing, or on the one you just finished.

**⌃⇧X** works on any selection, including text you did not type: pasted, received, or
noticed long after the fact. It reads the selection, converts whichever script dominates,
and switches the layout to match. A selection with no clear majority is left alone, since
converting it would corrupt whichever half was already right.

## Requirements

- macOS 13 (Ventura) or later, Apple silicon or Intel
- Accessibility permission (System Settings → Privacy & Security → Accessibility)

## Install

```sh
./install.sh
```

Builds from source, installs into `/Applications`, registers the login item and walks you
through the two privacy permissions macOS requires. Nothing here can be granted by the app
itself, so the last step is necessarily hands-on.

Other entry points:

| Script | What it does |
| --- | --- |
| `installer/build_app.sh` | Just `dist/MacKeySwitch.app` — universal, signed, with an icon |
| `installer/build_installer.sh` | The above, plus a `.pkg` and a `.dmg` for distribution |
| `installer/regrant-permissions.sh` | Re-grant Accessibility after a rebuild |

### About signing

Without a Developer ID the app is signed ad-hoc. That is fine locally, but the signature is
**different on every rebuild**, so macOS files each build as a new app and forgets the
Accessibility grant — and re-ticking the stale checkbox in System Settings does nothing,
the entry has to be removed and the app re-added. Either re-run
`installer/regrant-permissions.sh` after each build, or pin a stable identity:

```sh
export MACKEYSWITCH_CODESIGN_IDENTITY="Apple Development: you@example.com"
```

An ad-hoc signature also will not pass Gatekeeper on anyone else's Mac; distribution needs
a Developer ID and notarisation, which `build_installer.sh` prints the commands for.

## Build and test

```sh
swift build            # debug build
./run-tests.sh         # test suite
```

Use `run-tests.sh` rather than `swift test` directly: with the Command Line Tools (rather
than a full Xcode) selected, SwiftPM cannot find `Testing.framework` and quietly builds a
runner containing **no tests**, then exits 0. The script points the compiler, linker and
runtime loader at it.

## How the detection works

Every signal contributes to a single confidence score, compared against the threshold
chosen by the Sensitivity setting:

| Signal | Weight |
| --- | --- |
| The other-layout reading is a real word | +14 |
| What you typed is a real word | −25 (a veto) |
| What you typed contains a letter pair the language never uses | +3 |
| The other-layout reading is in the right script, no impossible pairs | +2 |
| The other-layout reading starts like some word in the target dictionary | +2 |
| What you typed starts like no word in the current dictionary | +2 |

Two conditions gate the score, at every sensitivity:

- **The other-layout reading has to be a real word.** Without that there is nothing to
  tell a wrong-layout word from a name, a brand, slang or an inflection the dictionaries
  do not list — all of which are correct input. The supporting signals cannot stand in
  for it: "no dictionary knows this" is a fact about the dictionary, not about the typing.
- **What you typed must not be a real word.**

The score then decides how much *supporting* evidence a dictionary hit needs, and that is
what the Sensitivity setting moves. Low is strict enough to require several signals
agreeing on top of the hit.

Missing a correction is a nuisance; rewriting correct input destroys it. Where the
evidence cannot tell the two apart, the text is left alone.

Word lookup goes to the bundled 50k lists first, then to the macOS spelling dictionaries.
The bundled lists alone are not enough — the Ukrainian one contains no word beginning
"при" at all — and `DictionaryCoverageTests` exists to keep that fact documented.

Corrections only ever trigger on space. Return and Tab end a word too, but by the time the
asynchronous correction runs, Return has already sent the message and Tab has already
moved focus.

## What it deliberately will not touch

- **Password fields.** Not guessed at: the app asks the accessibility API what the focused
  field is, and falls back to the system-wide secure input flag that password fields set.
  A shape heuristic — mixed case plus a digit or symbol, six characters or more — runs
  first as a cheap filter. Passwords are the worst possible thing to autocorrect, since
  you cannot see what was mangled.
- **URLs, emails and identifiers.** `ok.ua` reaches the buffer looking exactly like an
  ordinary word, because several US-layout punctuation keys are Ukrainian letters, and
  rewriting it would break a link you are about to follow.
- **Terminals and code editors**, by default — text there is usually code, and a
  wrong-layout word in it is usually deliberate. Any of them can be switched back on in
  Settings → Per-App Rules; only your own choices are stored, so defaults added in a later
  release still reach you.
- Words in apps you exclude in Settings → Per-App Rules.
- Words you have rejected before, by backspacing over a correction or pressing undo.
- The first word after you switch layouts by hand.
- Words with a **dead key** anywhere but the end. On US International `'` and `` ` `` type
  nothing until the next keystroke resolves them, and what the pair then produces is not
  something a static table can predict: `'` + `e` is one character (é), `'` + `'` is one
  (`'`), `'` + `.` is two (`'.`). The correction erases the old word by counting
  backspaces, so a keystroke that put a different number of characters on screen than the
  table claims shreds the text around it.

  A dead key **ending** a word is the one case that survives, and it is the common one —
  Ukrainian words ending in **є** or **ґ** (показує, працює) are typed on the `'` and
  `` ` `` keys. The boundary space resolves the dead key into exactly the character the
  table predicts, and is spent doing so, so the word on screen is intact and simply has no
  space after it. The correction accounts for that and those words are corrected normally.

  Which keys are dead, and which of them resolve cleanly, is a property of the layout, so
  the app asks the layout rather than hardcoding anything: `--print-diagnostics` lists them
  and says which are corrected. Plain US, ABC and British have no dead keys at all.

## When nothing happens

The app is a menu-bar agent, so it has nowhere to print. It keeps a log instead:

```sh
tail -20 ~/Library/Logs/MacKeySwitch.log
```

It records the few things worth knowing — launch, which shortcuts registered, and why a
correction was declined. A shortcut that never fired and one that fired and refused look
identical on screen; this is how to tell them apart.

If corrections stopped entirely after a rebuild, the Accessibility grant is the first
suspect — see *About signing* above.

## Translating

Interface strings live in `Sources/LayoutSwitcher/Resources/<code>.lproj/Localizable.strings`.
To add a language: copy `en.lproj`, translate the values, add the code to `AppLanguage`, and
list it in `Package.swift` and `installer/build_app.sh`. `LocalizationTests` fails the build
if a table loses a key, gains one English does not have, or changes a translation's format
specifiers — a translated `%d` that turned into `%@` would otherwise crash at runtime.

Run `MacKeySwitch.app/Contents/MacOS/LayoutSwitcher --print-diagnostics` to see which tables
the app actually found and how many strings each holds. A table it cannot find degrades
silently to English, so this is the way to tell the two apart.

## Licence

GPL-3.0. See [LICENSE](LICENSE).

Created by Oleksandr Kuzmin, 2026.
