#!/usr/bin/env bash
# Every Settings row anchor must name a registry entry and carry that entry's
# title.
#
# WHY THIS EXISTS
#
# `SettingsRegistry.registerAnchor` already asserts both invariants -- but only
# under `#if DEBUG`, and only when the pane in question is actually rendered.
# That combination has a bad failure mode: a mislabeled anchor is invisible to
# every headless check, invisible to a release build, and then traps inside a
# SwiftUI layout pass the first time a user opens that pane under `swift run`.
# It looks like the Settings window hanging and then crashing, and the crash
# report points at AppKit's layout machinery rather than at the typo.
#
# That happened: `engine.parity` was registered with its section and title the
# wrong way round, the release Qnet.app it was tested against compiled the
# assert out, and the bug surfaced only on the developer's own `swift run`.
#
# So the same two invariants are checked here, statically, before anything is
# built or run.
#
# WHAT IS AND IS NOT CHECKED
#
# Anchors whose id is a plain string literal are checked outright. Anchors
# whose id is an interpolation of `anchorPrefix` are checked against EVERY
# value that property is constructed with, because that pane is instantiated
# once per prefix and both instances register anchors. Anything else cannot be
# resolved from the source, so the count of such anchors is pinned: a new
# unresolvable one has to be a deliberate act.
set -euo pipefail

CHECK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE="$CHECK_ROOT/Sources/Qnet/SettingsView.swift"

python3 - "$SOURCE" <<'PY'
import re
import sys

source = open(sys.argv[1], encoding="utf-8").read()

# SettingsRegistry.entries: E("id", .pane, "section", "title", ...)
entries = {}
for match in re.finditer(
        r'E\(\s*"([^"]+)"\s*,\s*\.(\w+)\s*,\s*"((?:[^"\\]|\\.)*)"\s*,\s*"((?:[^"\\]|\\.)*)"',
        source):
    entries[match.group(1)] = match.group(4)
if not entries:
    sys.exit("settings anchor check: found no SettingsRegistry entries; the "
             "E(...) shape must have changed, and this check is now blind.")

# Values `anchorPrefix:` is constructed with, so an interpolated id can be
# resolved to the concrete ids that actually get registered.
prefixes = re.findall(r'anchorPrefix:\s*"([^"]+)"', source)

anchors = re.findall(
    r'\.settingsAnchor\(\s*(.+?)\s*,\s*label:\s*"((?:[^"\\]|\\.)*)"\s*\)', source)
if not anchors:
    sys.exit("settings anchor check: found no .settingsAnchor rows; the call "
             "shape must have changed, and this check is now blind.")

problems = []
unresolved = 0
checked = 0

def verify(anchor_id, label, note=""):
    global checked
    checked += 1
    if anchor_id not in entries:
        problems.append(
            'anchor "%s"%s has no SettingsRegistry entry, so no search can '
            'reach it and registerAnchor traps in a debug build.'
            % (anchor_id, note))
    elif entries[anchor_id] != label:
        problems.append(
            'anchor "%s"%s is labelled %r but the registry titles it %r. '
            'Search results show the registry title; make them the same.'
            % (anchor_id, note, label, entries[anchor_id]))

for raw_id, label in anchors:
    literal = re.fullmatch(r'"((?:[^"\\]|\\.)*)"', raw_id)
    if not literal:
        unresolved += 1
        continue
    text = literal.group(1)
    interpolation = re.fullmatch(r'\\\(anchorPrefix\)(.*)', text)
    if interpolation:
        if not prefixes:
            problems.append('anchor "%s" interpolates anchorPrefix, but no '
                            'anchorPrefix: "..." value was found to resolve it '
                            'against.' % text)
            continue
        for prefix in sorted(set(prefixes)):
            verify(prefix + interpolation.group(1), label,
                   ' (anchorPrefix = "%s")' % prefix)
    elif "\\(" in text:
        unresolved += 1
    else:
        verify(text, label)

# Pinned so a new anchor that this check cannot resolve is a deliberate act
# rather than a silent hole. Raise it only with a reason.
EXPECTED_UNRESOLVED = 1
if unresolved != EXPECTED_UNRESOLVED:
    problems.append(
        '%d anchor(s) have an id this check cannot resolve from the source; '
        '%d are expected. Either give the row a literal id, or raise '
        'EXPECTED_UNRESOLVED in validation/settings_anchor_check.sh and say '
        'why.' % (unresolved, EXPECTED_UNRESOLVED))

if problems:
    print("Settings anchor check failed:", file=sys.stderr)
    for problem in problems:
        print("  - " + problem, file=sys.stderr)
    sys.exit(1)

print("Settings anchor check passed: %d anchors resolved against %d registry "
      "entries (%d unresolvable id%s, as expected)."
      % (checked, len(entries), unresolved, "" if unresolved == 1 else "s"))
PY
