#!/bin/bash
#
# Lists the launch-argument / UserDefaults literals that live behind
# `#if PETNOTE_FAULT_INJECTION`, by reading the Swift sources.
#
#   scripts/fault-switches.sh            # one literal per line
#   scripts/fault-switches.sh --count
#   scripts/fault-switches.sh --types    # the types declared behind the gate
#
# The types are what the package audit looks for in the compiled symbols: a
# literal can be absent from a binary for reasons of its own, a type's
# metadata cannot, if the type was compiled in.
#
# Why this exists rather than a naming convention: the audit has to prove that
# none of these strings is in the device package, and to do that it needs to
# know what they are. Asking everyone to prefix them `-petnote-fault-` works
# only for as long as everyone remembers. Reading the gate itself does not
# depend on anybody remembering.
#
# The gate is the condition, not the comment: a literal counts when it sits
# inside `#if PETNOTE_FAULT_INJECTION` (or a `#if … && PETNOTE_FAULT_INJECTION`
# form), at any nesting depth.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

python3 - "$@" <<'PY'
import os, re, sys

# Overridable so the control below can point it at a tree with known contents.
ROOTS = (os.environ.get("PETNOTE_SCAN_ROOTS")
         or "App Core Features DesignSystem Support").split()
GATE = "PETNOTE_FAULT_INJECTION"

TYPE_DECL = re.compile(
    r'^\s*(?:(?:public|internal|private|fileprivate|final|nonisolated|indirect)\s+)*'
    r'(?:struct|class|enum|actor)\s+([A-Za-z_][A-Za-z0-9_]*)')

def gated_literals(path, types=False):
    out = []
    stack = []            # one bool per open #if: is the fault gate active?
    for line in open(path, encoding="utf-8"):
        stripped = line.strip()
        if stripped.startswith("#if"):
            # `#if PETNOTE_FAULT_INJECTION`, `#if DEBUG && PETNOTE_FAULT_INJECTION`
            stack.append(GATE in stripped and "!" + GATE not in stripped)
            continue
        if stripped.startswith("#elseif"):
            if stack:
                stack[-1] = GATE in stripped and "!" + GATE not in stripped
            continue
        if stripped.startswith("#else"):
            if stack:
                stack[-1] = False       # the else-branch is the ungated one
            continue
        if stripped.startswith("#endif"):
            if stack:
                stack.pop()
            continue
        if not any(stack) or stripped.startswith("//"):
            continue
        if types:
            declared = TYPE_DECL.match(line)
            if declared:
                out.append(declared.group(1))
            continue
        for match in re.finditer(r'"(-?petnote[A-Za-z0-9._-]*)"', line):
            out.append(match.group(1))
    return out

found = set()
for root in ROOTS:
    for directory, _, files in os.walk(root):
        for name in files:
            if name.endswith(".swift"):
                found.update(gated_literals(os.path.join(directory, name), types="--types" in sys.argv))

if "--count" in sys.argv:
    print(len(found))
else:
    for literal in sorted(found):
        print(literal)
PY
