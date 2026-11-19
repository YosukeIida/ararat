import re
import sys
from pathlib import Path


QUOTED = r""""(?:[^"\\]|\\.)*"|'(?:[^']|'')*'"""
TOKENS = re.compile(
    rf'''(?:^[ \t]*(?:-[ \t]+)?|[{{,][ \t]*)(?P<uses>uses|"uses"|'uses')[ \t]*:'''
    rf'''|(?:[:\-][ \t]+)(?P<block>[|>](?:[1-9][+-]?|[+-][1-9]?)?)[ \t]*(?:#.*)?$'''
    rf'''|{QUOTED}|(?<!\S)#.*'''
)
PIN = r"[^@\s'\"{},\[\]#]+@[0-9a-fA-F]{40}"
PINNED = re.compile(rf'''[ \t]*(?:{PIN}|"{PIN}"|'{PIN}')(?=[ \t]*(?:$|[}},])|[ \t]+#)''')


def unpinned_uses(path):
    # shortcut: scans the workflow's block and flow mappings, use a YAML parser
    # if workflows adopt explicit keys or multiline quoted scalars.
    block_indent = None
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        indent = len(line) - len(line.lstrip())
        if block_indent is not None:
            if not line.strip() or indent > block_indent:
                continue
            block_indent = None
        for token in TOKENS.finditer(line):
            if token.group("block"):
                block_indent = indent
            if token.group("uses") and not PINNED.match(line, token.end()):
                yield number


workflows = Path(__file__).resolve().parent.parent / "workflows"
paths = list(map(Path, sys.argv[1:])) or sorted(
    path for path in workflows.iterdir() if path.suffix in {".yml", ".yaml"}
)
if not paths:
    sys.exit("No workflow files found")

ok = True
for path in paths:
    for line in unpinned_uses(path):
        print(f"{path}:{line}: uses must pin a full 40-hex commit SHA", file=sys.stderr)
        ok = False
sys.exit(0 if ok else 1)
