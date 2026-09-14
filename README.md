# MacKeySwitch

A macOS menu bar utility that fixes keyboard layout mistakes. Type `ghbdsn` when you meant
`привіт`, press space, and it erases the word, switches the input source, and retypes it —
like Punto Switcher, but native, small, and open source.

## Features

- **Automatic correction** — checks each word on space and corrects it if the other layout
  makes a real word out of it and the confidence and safety checks pass.
- **Shortcut mode** — turn the automatic pass off and correct only when you ask.
- **Correct on demand** — `⌃⇧Space` fixes the last word even when the app was not confident
  enough to touch it on its own.
- **Selection correction** — select any text, press `⌃⇧X`, and it is re-read in the other
  layout. Works on text you never typed. A single converted word — a name or a brand no
  dictionary would recognise — can be learned after a verified conversion. Later automatic
  corrections still depend on the confidence and filtering rules below.
- **Undo** — `⌃⇧Z` reverts a recent correction. Rejecting an automatic correction teaches
  an exception; reverting a manually requested conversion does not. When there is nothing
  to revert, the same key converts the last word,
  so one shortcut toggles the word either way.
- **Three layouts, switched in pairs** — English (US, ABC, British and other Latin
  variants) with Ukrainian, and English with Russian. A Cyrillic word typed in English is
  retyped in the pinned Cyrillic layout, or the last-used one in Automatic pairing mode;
  a Cyrillic layout only ever goes back
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

For subsequent rebuilds, preserve existing privacy grants:

```sh
./install.sh --skip-permissions
```

This still builds, installs and relaunches the app. The default permission walkthrough
resets its Accessibility grant, so do not repeat it when the existing grant works.

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

> **Note:** without a configured signing identity or a detected Developer ID, the app is
> signed ad-hoc, and that signature changes on
> every rebuild — macOS may require Accessibility permission again. If the grant stops
> working, run `installer/regrant-permissions.sh`, or pin an available signing identity:
> `export MACKEYSWITCH_CODESIGN_IDENTITY="Apple Development: you@example.com"`

## Menu bar

The icon is the flag of the current layout. The menu has:

- **Enabled** toggle
- **Undo Last Switch**
- Enabled input sources: click a layout to select it; the current one is checked
- Switching-pair submenu and a session correction counter
- **Settings...**
- **Quit**

## Settings

| Tab | What is there |
| --- | --- |
| General | Interface language, switching pair, correction mode, launch at login |
| Detection | Sensitivity, minimum word length |
| Per-App Rules | Which apps are excluded |
| Dictionary | Word counts per language, and importing extra word lists — drop a file in and it names its own language |
| Statistics | Corrections made |
| Shortcuts | The three shortcuts, re-recordable |
| About | Version and licence |

### Shortcuts via Terminal

Quit the app before editing its preferences, then relaunch it. These commands restore
all three default bindings; modifiers must be set as well as key codes:

```sh
# Correct the last word — default ⌃⇧Space
defaults write com.okuzmin.mackeyswitch correctWordHotkeyKeyCode -int 49
defaults write com.okuzmin.mackeyswitch correctWordHotkeyModifiers -int 393216

# Undo — default ⌃⇧Z
defaults write com.okuzmin.mackeyswitch undoHotkeyKeyCode -int 6
defaults write com.okuzmin.mackeyswitch undoHotkeyModifiers -int 393216

# Convert selection — default ⌃⇧X
defaults write com.okuzmin.mackeyswitch selectionHotkeyKeyCode -int 7
defaults write com.okuzmin.mackeyswitch selectionHotkeyModifiers -int 393216
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
inflection the dictionaries do not list. Word lookup goes to the bundled 100k
frequency-ranked lists first — English, Ukrainian and Russian — then to whatever you have
imported, then to the macOS spelling dictionaries.

### Adding your own words

The Dictionary tab takes any UTF-8 text file with one word per line. Choose it with **Add
Dictionary File…** or drag it onto the window; the app reads it first and tells you what it
found — how many words, in which language, and how many lines it could not use. The
language is estimated from the alphabets and shown in a menu you can correct. Check that
choice before importing, especially for ambiguous Cyrillic lists. Imported files are remembered and reloaded
at every launch, and the tab shows what each language currently knows.

Larger input lists for all three languages are in [`dictionaries/`](dictionaries/) —
spelling lists and a curated Russian frequency list used to build the bundled dictionaries.
They are not compiled into the app; import one if you want the coverage.

### Selection conversion and the clipboard

Accessibility replacement is preferred and must be verified against the expected text.
An accepted but unverified write is not followed by another paste, because it may already
have changed the text. Explicitly unsupported writes fall back to Paste.

The selection itself must be readable through Accessibility: either selected text or the
field value plus its selected UTF-16 range. Cmd+C is not used to obtain it, because a
clipboard change could come from another app or clipboard synchronization. Editors that
expose neither form of selection cannot be converted safely and are left untouched.
The conversion uses the selected source variants, including Ukrainian versus Ukrainian-PC
and Russian versus RussianWin; punctuation does not determine the language of the text.

During a fallback paste, another selection conversion is blocked until confirmation or
failure. The original clipboard is restored only after the target text is verified, and
only if no newer clipboard data has arrived. Clipboard-history readers are not proof that
the target app pasted.

If verification times out after two seconds or the operation is cancelled, the converted
text stays on the clipboard unless newer data replaced it. This prevents a delayed Paste
from inserting the old clipboard. Editors without readable Accessibility text may complete
the paste without allowing verification; those attempts do not teach words or increment
statistics.

Missing a correction is a nuisance; rewriting correct input destroys it. Where the evidence
cannot tell the two apart, the text is left alone.

## Automatic-correction exclusions

Manual conversion deliberately bypasses confidence scoring; these are the automatic
pass's exclusions, not a promise that explicit selection conversion applies every filter.

- Password fields — detected through the system, not guessed from the characters
- URLs, emails and identifier-shaped text
- Words in excluded apps
- Words you have already rejected
- The first word started within two seconds after you switch layouts by hand
- Words with a dead key anywhere but the end (`--print-diagnostics` lists your layout's)

## Troubleshooting

**Corrections stopped after a rebuild.** The Accessibility grant is the first suspect —
an ad-hoc signature changes with every build. See the signing note under Installation.

**A shortcut does nothing.** Check Settings → Shortcuts for its binding and registration
error. Release the shortcut's modifiers within one second; a held chord cancels the
operation. A combination owned by another app may fail to register.

**Which layouts and dead keys the app sees:**

```sh
/Applications/MacKeySwitch.app/Contents/MacOS/LayoutSwitcher --print-diagnostics
```

Release builds have no persistent diagnostic log. For a closer look, quit the installed
copy first, then build debug and run the binary from a terminal — it prints what it
decides and why. A second instance exits without starting another monitor:

```sh
swift build && .build/debug/LayoutSwitcher
```

## Build and test

```sh
swift build
./run-tests.sh
swift build -c release
./run-tests.sh -c release
```

Use `run-tests.sh` rather than `swift test`: with the Command Line Tools selected instead of
a full Xcode, SwiftPM cannot find `Testing.framework` and quietly builds a runner containing
**no tests**, then exits 0.

## Translating

Interface strings are in `Sources/LayoutSwitcher/Resources/<code>.lproj/Localizable.strings`.
Copy `en.lproj`, translate the values, add the code to `AppLanguage`, and list it in
`Package.swift` and `installer/build_app.sh`. `LocalizationTests` fails the test run if a table
loses a key or changes a format specifier.

## Licence

GPL-3.0. See [LICENSE](LICENSE).

Created by Oleksandr Kuzmin, 2026.
