#!/usr/bin/env python3
"""Extracts every LocalizedStringKey literal from Strings.swift.

Lives apart from the shell script because the parse has to be exact: a key that
this misses is a string that silently ships in English, which is the one
failure a translation file cannot show you.
"""
import re
import sys
from pathlib import Path


def extract(source: str) -> list[tuple[str, str]]:
    keys: list[tuple[str, str]] = []
    # Each declaration, up to the next one or the end.
    for match in re.finditer(
        r"static (?:var|let) (\w+): LocalizedStringKey\b(.*?)(?=\n    (?:static|// MARK|\})|\Z)",
        source,
        re.S,
    ):
        name, body = match.group(1), match.group(2)
        triple = re.search(r'"""\n(.*?)\n\s*"""', body, re.S)
        if triple:
            joined = ""
            for line in (l.strip() for l in triple.group(1).split("\n")):
                joined += line[:-1].rstrip() + " " if line.endswith("\\") else line
            keys.append((name, joined.strip()))
            continue
        simple = re.search(r'"((?:[^"\\]|\\.)*)"', body)
        if simple:
            keys.append((name, simple.group(1)))
        else:
            print(f"warning: {name} has no literal this parser recognises", file=sys.stderr)
    return keys


if __name__ == "__main__":
    for name, key in extract(Path(sys.argv[1]).read_text()):
        print(f"{name}\t{key}")
