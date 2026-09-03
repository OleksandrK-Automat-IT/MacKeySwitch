# Frequency dictionary builder

The bundled English, Ukrainian and Russian dictionaries are generated in
descending usage-frequency order. `wordfreq` supplies the ranking, while the larger source
lists and the reviewed seed files supply the accepted spellings.

From the repository root:

```sh
python3 -m venv /tmp/mackeyswitch-dictionaries
/tmp/mackeyswitch-dictionaries/bin/pip install -r Scripts/requirements-dictionaries.txt
/tmp/mackeyswitch-dictionaries/bin/python Scripts/build_frequency_dictionaries.py \
  --english-source dictionaries/english-words-alpha.txt \
  --ukrainian-source dictionaries/ukrainian-words-v10.txt \
  --russian-source dictionaries/russian-words-ru-spelling-1.0.8.txt
```

The source lists are checked in under `dictionaries/`, so the command above
runs as written from a clean checkout.

The Ukrainian build also uses the checked-in `ua_words.txt` as a legacy
allowlist. This is intentional: the morphology source omits some valid forms
from the previous reviewed corpus. The generated file is a stable input to the
next build, so regeneration from a clean checkout is deterministic — verified
by running the build twice and comparing checksums.

Russian has no legacy allowlist. Its list was generated for the first time
here, so the spelling source is the only authority on what counts as a word.

Run `./run-tests.sh` after regeneration.
