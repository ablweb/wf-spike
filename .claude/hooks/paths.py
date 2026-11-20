#!/usr/bin/env python3
"""Risk class of a path, from the project's .claude/wf.json.

usage: paths.py classify [path...]   'CLASS path' per path, the highest class whose globs match ('-' when none)
       paths.py outside [--zone A,B] [path...]    the paths an agent may not change (their class is not in the zone: the agent classes of
                                     .claude/wf.json, or the classes of --zone)
Paths are read from stdin when none are given.
"""
import json
import pathlib
import re
import sys


def glob_to_regex(glob):
    """Globs as anchored regexes; Forgejo also reads CODEOWNERS lines as Go regexes of this shape."""
    out, i = "", 0
    while i < len(glob):
        if glob.startswith("**/", i):
            out += "(.*/)?"
            i += 3
        elif glob.startswith("**", i):
            out += ".*"
            i += 2
        elif glob[i] == "*":
            out += "[^/]*"
            i += 1
        elif glob[i] == "?":
            out += "[^/]"
            i += 1
        else:
            out += re.escape(glob[i])
            i += 1
    return "^" + out + "$"


def classify(paths, risk):
    """risk: {class: {"paths": [glob, ...], ...}}. One 'CLASS path' line per path."""
    rules = [(cls, re.compile(glob_to_regex(g))) for cls, spec in risk.items() for g in spec["paths"]]
    return [f"{max((c for c, rx in rules if rx.match(p)), default='-')} {p}" for p in paths]


def outside(paths, risk, zone):
    return [line.split(" ", 1)[1] for line in classify(paths, risk) if line.split(" ", 1)[0] not in zone]


def main(argv):
    cfg = json.loads((pathlib.Path(__file__).resolve().parent.parent / "wf.json").read_text())
    cmd = argv[1] if len(argv) > 1 else ""
    rest = argv[2:]
    zone = None
    if rest[:1] == ["--zone"] and len(rest) > 1:
        zone, rest = set(rest[1].split(",")), rest[2:]
    paths = rest or sys.stdin.read().splitlines()
    if cmd == "classify":
        out = classify(paths, cfg["risk"])
    elif cmd == "outside":
        out = outside(paths, cfg["risk"], zone or set(cfg["agents"]["classes"]))
    else:
        sys.exit(__doc__)
    for line in out:
        print(line)


if __name__ == "__main__":
    main(sys.argv)
