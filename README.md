# MacKeySwitch

A macOS menu bar utility that fixes keyboard layout mistakes. Type `ghbdsn` when you meant
`привіт`, press space, and it erases the word, switches the input source, and retypes it —
like Punto Switcher, but native, small, and open source.

## Features

- **Automatic correction** — checks each word on space and corrects it if the other layout
  makes a real word out of it.
- **Shortcut mode** — turn the automatic pass off and correct only when you ask.
- **Correct on demand** — `⌃⇧Space` fixes the last word even when the app was not confident
  enough to touch it on its own.
- **Selection correction** — select any text, press `⌃⇧X`, and it is re-read in the other
  layout. Works on text you never typed.
- **Undo** — `⌃⇧Z` reverts the last correction, and the word is remembered so it is not
  touched again. When there is nothing to revert, the same key converts the last word,
  so one shortcut toggles the word either way.
- **Three layouts, switched in pairs** — English (US, ABC, British and other Latin
  variants) with Ukrainian, and English with Russian. A Cyrillic word typed in English is
  retyped in whichever Cyrillic layout you last used; a Cyrillic layout only ever goes back
  to English. Ukrainian and Russian are never swapped for each other.
- **Smart filtering** — skips password fields, URLs, emails and identifiers.
- **App blacklist** — off by default in terminals, IDEs and code editors; any of them can be
  switched back on.
- **Bilingual interface** — English and Ukrainian, switched at runtime with no relaunch.
- **Launch at login** — optional.

## Requirements

- macOS 13 (Ventura) or later, Apple silicon or Intel
- Accessibility permission

## Installation

```sh
git clone https://github.com/OleksandrK-Automat-IT/MacKeySwitch.git
cd MacKeySwitch
./install.sh
```

The script builds the app, installs it into `/Applications`, registers the login item and
walks you through the privacy permissions macOS requires. The permission step is necessarily
hands-on — no app can grant it to itself.

> **Note:** building needs a Swift toolchain — either Apple's Command Line Tools or a full
> Xcode. The script checks for `swift` and, if it is missing, offers to install the Command
> Line Tools, which are the smaller of the two; re-run `./install.sh` afterwards.
>
> If Xcode is installed but its licence has never been accepted, every build fails with a
> licence error until you run `sudo xcodebuild -license`.

Other entry points:

| Script | What it does |
| --- | --- |
| `installer/build_app.sh` | Just `dist/MacKeySwitch.app` — universal, signed, with an icon |
| `installer/build_installer.sh` | The above, plus a `.pkg` and a `.dmg` |
| `installer/regrant-permissions.sh` | Re-grant Accessibility after a rebuild |

> **Note:** without a Developer ID the app is signed ad-hoc, and that signature changes on
> every rebuild — macOS then treats each build as a new app and forgets the Accessibility
> grant. Either run `installer/regrant-permissions.sh` after a build, or pin an identity:
> `export MACKEYSWITCH_CODESIGN_IDENTITY="Apple Development: you@example.com"`

## Menu bar

The icon is the flag of the current layout. The menu has:

- **Enabled** toggle
- **Undo Last Switch**
- Current layout and a correction counter
- **Settings...**

## Settings

| Tab | What is there |
| --- | --- |
| General | Interface language, correction mode, the three shortcuts, launch at login |
| Detection | Sensitivity, minimum word length, correction delay |
| Per-App Rules | Which apps are excluded |
| Dictionary | Custom words and extra word-list files, per language (English, Ukrainian, Russian) |
| Statistics | Corrections made |
| About | Version and licence |

### Shortcuts via Terminal

```sh
# Correct the last word — default ⌃⇧Space
defaults write com.okuzmin.mackeyswitch correctWordHotkeyKeyCode -int 49
defaults write com.okuzmin.mackeyswitch correctWordHotkeyModifiers -int 393216

# Undo — default ⌃⇧Z
defaults write com.okuzmin.mackeyswitch undoHotkeyKeyCode -int 6

# Convert selection — default ⌃⇧X
defaults write com.okuzmin.mackeyswitch selectionHotkeyKeyCode -int 7
```

Settings has a recorder for all three, which is easier.

## How it works

1. Keystrokes are captured without being blocked, and buffered into the current word.
2. On space, the buffer is read in both layouts.
3. Each signal — is the other reading a real word, is what you typed a real word, are there
   letter pairs the language never uses — contributes to a confidence score, compared
   against the threshold your Sensitivity setting picks.
4. If the score clears it, the word is erased with counted backspaces, the input source is
   switched, and the correct text is retyped.

A correction requires the other-layout reading to be a real word, at every sensitivity.
Without that there is nothing to separate a wrong-layout word from a name, a brand or an
inflection the dictionaries do not list. Word lookup goes to the bundled 50k lists first,
then to the macOS spelling dictionaries. Russian has no bundled list: it relies on the
macOS dictionary plus whatever you add or import in the Dictionary tab.

Missing a correction is a nuisance; rewriting correct input destroys it. Where the evidence
cannot tell the two apart, the text is left alone.

## What it will not touch

- Password fields — detected through the system, not guessed from the characters
- URLs, emails and identifier-shaped text
- Words in excluded apps
- Words you have already rejected
- The first word after you switch layouts by hand
- Words with a dead key anywhere but the end (`--print-diagnostics` lists your layout's)

## Troubleshooting

**Corrections stopped after a rebuild.** The Accessibility grant is the first suspect —
an ad-hoc signature changes with every build. See *About signing* above.

**A shortcut does nothing.** Check Settings → General that it is still bound; Carbon
refuses a combination another app already owns, and does so silently.

**Which layouts and dead keys the app sees:**

```sh
MacKeySwitch.app/Contents/MacOS/LayoutSwitcher --print-diagnostics
```

Release builds keep no log. For a closer look, build debug and run the binary from a
terminal — it prints what it decides and why:

```sh
swift build && .build/debug/LayoutSwitcher
```

## Build and test

```sh
swift build
./run-tests.sh
```

Use `run-tests.sh` rather than `swift test`: with the Command Line Tools selected instead of
a full Xcode, SwiftPM cannot find `Testing.framework` and quietly builds a runner containing
**no tests**, then exits 0.

## Translating

Interface strings are in `Sources/LayoutSwitcher/Resources/<code>.lproj/Localizable.strings`.
Copy `en.lproj`, translate the values, add the code to `AppLanguage`, and list it in
`Package.swift` and `installer/build_app.sh`. `LocalizationTests` fails the build if a table
loses a key or changes a format specifier.

## Licence

GPL-3.0. See [LICENSE](LICENSE).

Created by Oleksandr Kuzmin, 2026.
