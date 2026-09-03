# Dictionary data notices

`en_words.txt`, `ua_words.txt` and `ru_words.txt` are transformed,
frequency-ranked word lists.
They contain no frequency scores and are used only for local spelling lookup.

- Frequency ranking: `wordfreq` 3.1.1 by Luminoso Technologies and Robyn Speer.
  Code is Apache-2.0. These transformed dictionary files are distributed under
  CC BY-SA 4.0, the licence `wordfreq` specifies for redistributed language
  data. <https://github.com/rspeer/wordfreq>
- English spelling allowlist: `dwyl/english-words` (`words_alpha.txt`).
  <https://github.com/dwyl/english-words>
- Ukrainian morphology allowlist: `slavkaa/ukraine_dictionary`, version 10,
  MIT License. <https://github.com/slavkaa/ukraine_dictionary>
- Russian spelling allowlist: `Goudron/ru-spelling-dictionary`, version 1.0.8,
  Mozilla Public License 2.0.
  <https://github.com/Goudron/ru-spelling-dictionary>
- Reviewed project seed lists and the legacy Ukrainian allowlist are maintained
  in this repository.

Generation instructions and the exact tool version are in `Scripts/README.md`
and `Scripts/requirements-dictionaries.txt` in the source distribution.
