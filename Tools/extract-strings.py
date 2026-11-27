#!/usr/bin/env python3
"""Extracts every LocalizedStringKey literal from Strings.swift.

Lives apart from the shell script because the parse has to be exact: a key that
this misses is a string that silently ships in English, which is the one
failure a translation file cannot show you.
"""
import re
import sys
from pathlib import Path


def escape_percent(text: str) -> str:
    """A literal % is %% in the key, which is what the lookup compares."""
    return text.replace("%", "%%")


def parameters(params: str) -> list[tuple[str, str]]:
    """The declared parameters, in order, as (name, type).

    Needed because one signature can mix types. `warnLowConfidence(_ passages:
    Int, _ lowest: String)` wants %lld then %@, and the previous version asked
    only whether *any* parameter was an Int and then used that answer for every
    interpolation in the string — which produced %lld for the String too. The
    translation is then present, looks right in the file, and is never found at
    runtime.
    """
    found: list[tuple[str, str]] = []
    for part in params.split(","):
        match = re.search(r"(\w+)\s*:\s*([\w.<>\[\]?]+)", part.strip())
        if match:
            found.append((match.group(1), match.group(2)))
    return found


def specifier_for_type(swift_type: str) -> str:
    """SwiftUI writes %lld for an Int and %@ for a String."""
    return "%lld" if swift_type == "Int" else "%@"


def interpolate(literal: str, params: str) -> str:
    """Turn a Swift literal into the key, escaping % and substituting \\(…)."""
    declared = parameters(params)
    by_name = {name: swift_type for name, swift_type in declared}
    out, i, position = "", 0, 0
    while i < len(literal):
        if literal.startswith("\\(", i):
            depth, j = 0, i + 1
            while j < len(literal):
                if literal[j] == "(":
                    depth += 1
                elif literal[j] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            expression = literal[i + 2:j].strip()
            # By name where the interpolation is a bare parameter, which is
            # every case in this project, and by position otherwise. Both beat
            # guessing one specifier for the whole string.
            if expression in by_name:
                out += specifier_for_type(by_name[expression])
            elif position < len(declared):
                out += specifier_for_type(declared[position][1])
            else:
                out += "%@"
            position += 1
            i = j + 1
        else:
            out += escape_percent(literal[i])
            i += 1
    return out


def extract(source: str) -> list[tuple[str, str]]:
    keys: list[tuple[str, str]] = []
    # Each declaration, up to the next one or the end.
    for match in re.finditer(
        r"static (?:var|let) (\w+): LocalizedStringKey\b(.*?)(?=\n    (?:static|// MARK|\})|\Z)"
        r"|static func (\w+)\((.*?)\) -> LocalizedStringKey\b(.*?)(?=\n    (?:static|// MARK|\})|\Z)",
        source,
        re.S,
    ):
        if match.group(1) is not None:
            name, body, params = match.group(1), match.group(2), ""
        else:
            name, params, body = match.group(3), match.group(4), match.group(5)
        # Every literal in the body, not only the first.
        #
        # A declaration that picks between two wordings — singular and plural —
        # is two keys, and taking `re.search` meant the second form was never
        # checked and silently shipped in English. That is precisely the failure
        # this file's docstring says a translation file cannot show you.
        # Comment lines first, because a declaration's body as matched here
        # runs into the doc comment of the one after it — the boundary pattern
        # stops at `static`, `// MARK` and `}`, not at `///`. Collecting every
        # literal then picked up prose: `recordHelp` gained a second key of
        # "your microphone is broken", quoted inside the next declaration's
        # explanation. Dropping whole comment lines is enough and cannot touch a
        # literal, since no string in this file begins a line with //.
        body = "\n".join(line for line in body.split("\n")
                          if not line.lstrip().startswith("//"))

        found_here: list[str] = []
        for triple in re.finditer(r'"""\n(.*?)\n\s*"""', body, re.S):
            joined = ""
            for line in (l.strip() for l in triple.group(1).split("\n")):
                joined += line[:-1].rstrip() + " " if line.endswith("\\") else line
            # Interpolated here too. The multiline branch used to skip this, so
            # a `"""` literal containing \(x) produced a key with the Swift
            # source in it — unfindable at runtime, and reported as present.
            found_here.append(interpolate(joined.strip(), params))

        # The triples are then removed before looking for single-line literals,
        # rather than the body being treated as one kind or the other. A
        # declaration can hold both — a short singular form and a wrapped
        # plural one — and taking only the first kind lost the other.
        remainder = re.sub(r'"""\n.*?\n\s*"""', "", body, flags=re.S)
        for simple in re.finditer(r'"((?:[^"\\]|\\.)*)"', remainder):
            found_here.append(interpolate(simple.group(1), params))

        if found_here:
            for key in found_here:
                keys.append((name, key))
        elif '"' not in body:
            # A body with no string literal at all cannot introduce a key: it
            # dispatches to other keys, each checked on its own. Silent on
            # purpose — warning here trains the reader to ignore the warning
            # that matters.
            continue
        else:
            print(f"warning: {name} has no literal this parser recognises", file=sys.stderr)
    return keys


def extract_localized_calls(source: str) -> list[tuple[str, str]]:
    """Keys generated by `String(localized: "…")`.

    Foundation replaces each interpolation with a format specifier when it
    builds the lookup key. Every interpolated value in this project is a
    String by construction — numbers go through formatted() first — so every
    specifier is %@ and the key is recoverable without running the compiler.
    """
    keys: list[tuple[str, str]] = []
    for match in re.finditer(r'String\(localized: "((?:[^"\\]|\\.|\\\()*?)"\)', source):
        literal = match.group(1)
        # Replace \(...) spans, which may themselves contain parentheses.
        out, i = "", 0
        while i < len(literal):
            if literal.startswith("\\(", i):
                depth, j = 0, i + 1
                while j < len(literal):
                    if literal[j] == "(":
                        depth += 1
                    elif literal[j] == ")":
                        depth -= 1
                        if depth == 0:
                            break
                    j += 1
                out += "%@"
                i = j + 1
            else:
                out += escape_percent(literal[i])
                i += 1
        keys.append((f"localized:{len(keys)}", out))
    return keys


if __name__ == "__main__":
    for path in sys.argv[1:]:
        source = Path(path).read_text()
        # A call this parser cannot read is a string that ships untranslated,
        # so a mismatch is an error rather than a silent omission.
        attempted = source.count('String(localized: "')
        parsed = len(extract_localized_calls(source))
        if attempted != parsed:
            print(
                f"error: {path} has {attempted} String(localized:) calls but "
                f"{parsed} parsed — a nested quote inside an interpolation will "
                f"do this",
                file=sys.stderr,
            )
            sys.exit(2)
        for name, key in extract(source):
            print(f"{name}\t{key}")
        for name, key in extract_localized_calls(source):
            print(f"{name}\t{key}")
