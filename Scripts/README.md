# Frequency dictionary builder

The bundled English, Ukrainian and Russian dictionaries follow `wordfreq` frequency
order (most frequent first), with reviewed seeds always included. Seeds absent from
the frequency data are placed at the end. `wordfreq==3.1.1` supplies the ranking, while
the larger input lists and reviewed seed files supply the accepted spellings.

From the repository root, using Python 3.10 or later:

```sh
python3 -m venv /tmp/mackeyswitch-dictionaries
/tmp/mackeyswitch-dictionaries/bin/pip install -r Scripts/requirements-dictionaries.txt
/tmp/mackeyswitch-dictionaries/bin/python Scripts/build_frequency_dictionaries.py \
  --english-source dictionaries/english-words-alpha.txt \
  --ukrainian-source dictionaries/ukrainian-words-v10.txt \
  --russian-source dictionaries/russian-words-ru-spelling-1.0.8.txt
```

The input lists are checked in under [`dictionaries/`](../dictionaries/). The default
command overwrites `en_words.txt`, `ua_words.txt` and `ru_words.txt` in
`Sources/LayoutSwitcher/Resources`, with exactly 100,000 entries per language. Seed words
replace the lowest-ranked non-seed entries; they do not increase that count. Installing
the Python requirements needs access to a package index or an existing package cache.

To inspect a rebuild without changing the bundled files, append
`--output-directory /tmp/mackeyswitch-dictionaries-output`. `--limit` changes the count for
each language; the bundled dictionary tests expect the default 100,000.

The Ukrainian build also uses the checked-in `ua_words.txt` as a legacy
allowlist. This is intentional: the morphology source omits some valid forms
from the previous reviewed corpus. The generated file is a stable input to the
next build, so regeneration from a clean checkout is deterministic — verified
by running the build twice and comparing checksums.

Russian has no legacy allowlist: its accepted spellings come from the Russian input list
plus `Scripts/dictionary-seeds/ru.txt`. English likewise uses its input list plus its seeds.
Override the additional Ukrainian allowlist with `--ukrainian-legacy-source PATH`.

The generator normalizes words to NFC and lowercase, deduplicates them, and filters by
language alphabet. Hyphenated words and rows containing counts or affix flags are rejected.
See [dictionary notices](../Sources/LayoutSwitcher/Resources/DICTIONARY-NOTICES.md) for
frequency-data attribution and licensing.

Run `./run-tests.sh` after regeneration.
