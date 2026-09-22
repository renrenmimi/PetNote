#!/bin/bash
#
# Lists the launch-argument / UserDefaults literals that live behind
# `#if PETNOTE_FAULT_INJECTION`, by reading the Swift sources.
#
#   scripts/fault-switches.sh            # one literal per line
#   scripts/fault-switches.sh --count
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

def gated_literals(path):
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
        for match in re.finditer(r'"(-?petnote[A-Za-z0-9._-]*)"', line):
            out.append(match.group(1))
    return out

found = set()
for root in ROOTS:
    for directory, _, files in os.walk(root):
        for name in files:
            if name.endswith(".swift"):
                found.update(gated_literals(os.path.join(directory, name)))

if "--count" in sys.argv:
    print(len(found))
else:
    for literal in sorted(found):
        print(literal)
PY
