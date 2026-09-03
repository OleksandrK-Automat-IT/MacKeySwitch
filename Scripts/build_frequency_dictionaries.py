#!/usr/bin/env python3
"""Build deterministic, frequency-ranked dictionaries for MacKeySwitch.

The frequency order comes from wordfreq. Large spelling/morphology lists act as
allowlists so corpus artefacts do not silently become accepted words. A small,
reviewed seed list fills known gaps in those source lists.
"""

from __future__ import annotations

import argparse
import re
import unicodedata
from pathlib import Path

from wordfreq import iter_wordlist


ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Sources" / "LayoutSwitcher" / "Resources"
SEEDS = Path(__file__).resolve().parent / "dictionary-seeds"
ENGLISH_PATTERN = re.compile(r"[a-z]+", re.IGNORECASE)
UKRAINIAN_PATTERN = re.compile(r"[а-щьюяєіїґ'’ʼ]+", re.IGNORECASE)
RUSSIAN_PATTERN = re.compile(r"[а-яё'’ʼ]+", re.IGNORECASE)


def read_words(path: Path, pattern: re.Pattern[str]) -> set[str]:
    words: set[str] = set()
    for raw in path.read_text(encoding="utf-8-sig").splitlines():
        word = unicodedata.normalize("NFC", raw.strip().lower())
        if word and any(character.isalpha() for character in word) and pattern.fullmatch(word):
            words.add(word)
    return words


def build(
    language: str,
    sources: list[Path],
    seed_path: Path,
    pattern: re.Pattern[str],
    limit: int,
) -> list[str]:
    allowed: set[str] = set()
    for source in sources:
        allowed.update(read_words(source, pattern))
    seeds = read_words(seed_path, pattern)
    allowed.update(seeds)

    ranked: list[str] = []
    ranks: dict[str, int] = {}
    seen: set[str] = set()
    for rank, raw in enumerate(iter_wordlist(language)):
        word = unicodedata.normalize("NFC", raw.lower())
        if word in allowed and word not in seen and pattern.fullmatch(word):
            ranked.append(word)
            ranks[word] = rank
            seen.add(word)

    if len(ranked) < limit:
        raise SystemExit(
            f"{language}: only {len(ranked):,} validated frequency entries; "
            f"cannot produce {limit:,}"
        )

    selected = ranked[:limit]
    missing_seeds = seeds.difference(selected)
    if missing_seeds:
        removable = [word for word in reversed(selected) if word not in seeds]
        for word, removed in zip(sorted(missing_seeds), removable):
            selected.remove(removed)
            selected.append(word)
        selected.sort(key=lambda word: (ranks.get(word, len(ranks)), word))

    assert len(selected) == limit
    assert len(set(selected)) == limit
    assert seeds.issubset(selected)
    return selected


def write_words(path: Path, words: list[str]) -> None:
    path.write_text("\n".join(words) + "\n", encoding="utf-8")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--english-source", type=Path, required=True)
    parser.add_argument("--ukrainian-source", type=Path, required=True)
    parser.add_argument("--russian-source", type=Path, required=True)
    parser.add_argument(
        "--ukrainian-legacy-source",
        type=Path,
        default=RESOURCES / "ua_words.txt",
        help="Additional reviewed allowlist; defaults to the checked-in UA dictionary",
    )
    parser.add_argument("--output-directory", type=Path, default=RESOURCES)
    parser.add_argument("--limit", type=int, default=100_000)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.limit < 1:
        raise SystemExit("--limit must be positive")
    for source in (
        args.english_source,
        args.ukrainian_source,
        args.russian_source,
        args.ukrainian_legacy_source,
    ):
        if not source.is_file():
            raise SystemExit(f"source file not found: {source}")

    english = build(
        "en", [args.english_source], SEEDS / "en.txt", ENGLISH_PATTERN, args.limit
    )
    ukrainian = build(
        "uk",
        [args.ukrainian_source, args.ukrainian_legacy_source],
        SEEDS / "uk.txt",
        UKRAINIAN_PATTERN,
        args.limit,
    )
    # No legacy allowlist for Russian: this is its first bundled list, so the spelling
    # source is the only authority on what counts as a word.
    russian = build(
        "ru", [args.russian_source], SEEDS / "ru.txt", RUSSIAN_PATTERN, args.limit
    )
    args.output_directory.mkdir(parents=True, exist_ok=True)
    write_words(args.output_directory / "en_words.txt", english)
    write_words(args.output_directory / "ua_words.txt", ukrainian)
    write_words(args.output_directory / "ru_words.txt", russian)
    print(
        f"Wrote EN={len(english):,}, UA={len(ukrainian):,}, "
        f"RU={len(russian):,} frequency-ranked words"
    )


if __name__ == "__main__":
    main()
