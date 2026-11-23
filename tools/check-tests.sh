#!/bin/sh
# Fails when a source file's tests would not run: every file under src/
# with a `test "..."` must be reached from the test root (src/main.zig's
# `test {}`) through the folder roots' explicit `test {}` / `comptime {}`
# blocks (`_ = @import("x.zig");`, or `_ = name;` for a `const name =
# @import("x.zig")`), never only because other code happens to import
# it. And main.zig's is the only `test {}` block: a folder reaches its
# files in a `comptime {}` block, which is not counted as a test. The
# scheme is described above main.zig's `test {}`. Run from the
# repository root (zig build check-tests does).
set -eu

exec python3 -I - src <<'EOF'
import os, re, sys

src = sys.argv[1]
root = os.path.join(src, "main.zig")
import_re = re.compile(r'@import\("([^"]+\.zig)"\)')
const_re = re.compile(r'^\s*(?:pub\s+)?const\s+(\w+)\s*(?::[^=]*)?=\s*(.*)$')
block_re = re.compile(r'^(test|comptime)\s*\{')
reach_re = re.compile(r'_\s*=\s*(.*);')

def imports(path, expr):
    return [os.path.normpath(os.path.join(os.path.dirname(path), x)) for x in import_re.findall(expr)]

def consts(lines):
    """name -> its initializer (up to six continuation lines)"""
    out = {}
    for i, line in enumerate(lines):
        m = const_re.match(line)
        if not m:
            continue
        e, j = m.group(2), i
        while not e.rstrip().endswith(";") and j + 1 < len(lines) and j < i + 6:
            j += 1
            e += lines[j]
        out[m.group(1)] = e
    return out

def reached(path, lines):
    """the files the top-level test {} / comptime {} blocks reach, and
    whether the file has a top-level test {} block"""
    names = consts(lines)
    out, has_test_block = set(), False
    depth, inside = 0, False
    for line in lines:
        s = line.strip()
        m = block_re.match(line)
        if not inside and m:
            inside, depth = True, 0
            has_test_block |= m.group(1) == "test"
        if not inside:
            continue
        depth += line.count("{") - line.count("}")
        r = reach_re.match(s)
        if r:
            e = r.group(1)
            targets = imports(path, e)
            if not targets:
                n = re.match(r'(\w+)', e)
                if n and n.group(1) in names:
                    targets = imports(path, names[n.group(1)])
            out.update(targets)
        if depth <= 0 and "}" in line:
            inside = False
    return out, has_test_block

edges, with_tests, test_blocks = {}, [], []
for d, _, files in os.walk(src):
    for f in files:
        if not f.endswith(".zig"):
            continue
        p = os.path.normpath(os.path.join(d, f))
        text = open(p, encoding="utf-8").read()
        edges[p], has_block = reached(p, text.split("\n"))
        if has_block and p != root:
            test_blocks.append(p)
        if re.search(r'^test "', text, re.M):
            with_tests.append(p)

seen, stack = set(), [root]
while stack:
    x = stack.pop()
    if x not in seen:
        seen.add(x)
        stack.extend(edges.get(x, ()))

bad = 0
for p in sorted(test_blocks):
    print(f"{p}: a test {{}} block outside {root}: reach the files in a comptime {{}} block of the folder's root", file=sys.stderr)
    bad = 1
for p in sorted(set(with_tests) - seen):
    print(f"{p}: has tests that no test root reaches: list it in its folder's root (see {root}'s test {{}})", file=sys.stderr)
    bad = 1
sys.exit(bad)
EOF
