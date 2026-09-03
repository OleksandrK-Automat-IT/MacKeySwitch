# Optional word lists

The full source lists the bundled dictionaries are generated from. They are kept here as
files rather than compiled in: together they are ~11 MB, against the 100k frequency-ranked
lists in `Sources/LayoutSwitcher/Resources` that cover ordinary vocabulary at a fraction of
the size. Nothing here is loaded unless you import it.

Two uses. `Scripts/build_frequency_dictionaries.py` reads them to regenerate the bundled
lists — see `Scripts/README.md`. And you can import one into the app directly, to trade
size for coverage: every inflected form the frequency ranking left out.

**To use one:** Settings → Dictionary → *Add Dictionary File…*, or drag the file onto the
window. The app reads it, names its language, and says how many words it found. Imported
files are remembered and reloaded at every launch.

## What is here

| File | Words | Language |
| --- | --- | --- |
| `english-words-alpha.txt` | 370,105 | English |
| `ukrainian-words-v10.txt` | 256,499 | Ukrainian |
| `russian-words-ru-spelling-1.0.8.txt` | 150,014 | Russian |

`BundledOptionalDictionariesTests` holds each file to its language and format: a list
replaced by markup, by frequencies, or by the wrong language fails the test rather than
being discovered on import.

The Ukrainian list contains 445 hyphenated forms that the importer drops. That is by
design — a hyphen ends a word as the app buffers it, so "будь-який" never reaches the
dictionary as one word and could not be matched anyway.

## Sources and licences

Each file keeps the licence of the project it came from. None of them is covered by this
repository's GPL-3.0.

### English — `english-words-alpha.txt`
- Source: https://github.com/dwyl/english-words, file `words_alpha.txt`
- Licence: Unlicense (public domain dedication)
- Processing: CRLF line endings converted to LF; words otherwise unchanged
- SHA-256: `643c7f71d5caee9806be56f5ed83ba36e2246a06a04bcf4aaa0576790bb90d66`

### Ukrainian — `ukrainian-words-v10.txt`
- Source: https://github.com/slavkaa/ukraine_dictionary, v.10
- Licence: MIT
- Processing: unique word forms extracted, lowercased, and limited to Ukrainian letters,
  apostrophes and hyphens
- SHA-256: `c42cc8cb6d0a0061ff34bca5c7b890daad8f140089a6d59c41e9b3e06aa4d6e2`

### Russian — `russian-words-ru-spelling-1.0.8.txt`
- Source: https://github.com/Goudron/ru-spelling-dictionary, v1.0.8,
  commit `69a18ae079084f11569f5190ac2080289055ef5e`
- Upstream artifact: `cspell/dictionaries/ru_RU.txt.gz`
- Licence: Mozilla Public License 2.0
- Processing: decompressed, lowercased, limited to Russian letters and apostrophes,
  deduplicated, sorted by UTF-8 byte order. Hyphenated forms were excluded for the reason
  given above
- SHA-256: `7443375c2b016984a3f708d466c0933ac4065b6cf243e08a581c2b854a9455c3`
