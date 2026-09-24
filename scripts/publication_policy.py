#!/usr/bin/env python3
"""Validate reviewed Git objects before publishing them; never print their contents."""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import re
import subprocess
import sys


# New public paths require deliberate review, even when .gitignore permits them.
PUBLIC_PATHS = frozenset("""
.gitattributes
.gitignore
.github/workflows/publication.yml
CODE_OF_CONDUCT.md
CONTRIBUTING.md
Entitlements.plist
Info.plist
LICENSE
Package.swift
Patches/fluidaudio-privacy-and-bounded-ingress.patch
README.md
Sources/WithinApp/AccessibilityTarget.swift
Sources/WithinApp/AppDelegate.swift
Sources/WithinApp/AppModel.swift
Sources/WithinApp/CaptureEngine.swift
Sources/WithinApp/CompatibilityPaste.swift
Sources/WithinApp/LocalSpeech.swift
Sources/WithinApp/ModelStore.swift
Sources/WithinApp/ModelStoreCheck.swift
Sources/WithinApp/NativeChecks.swift
Sources/WithinApp/OfflineProbe.swift
Sources/WithinApp/PreviewRenderer.swift
Sources/WithinApp/Resources/model-manifest.json
Sources/WithinApp/ShortcutManager.swift
Sources/WithinApp/SpeechSafetyCheck.swift
Sources/WithinApp/StreamBenchmark.swift
Sources/WithinApp/Views.swift
Sources/WithinApp/main.swift
Sources/WithinAudioBuffer/WithinAudioBuffer.c
Sources/WithinAudioBuffer/include/WithinAudioBuffer.h
Sources/WithinCore/AudioRing.swift
Sources/WithinCore/ClipboardLease.swift
Sources/WithinCore/Diagnostics.swift
Sources/WithinCore/InsertionTrial.swift
Sources/WithinCore/ModelManifest.swift
Sources/WithinCore/NetworkBoundary.swift
Sources/WithinCore/SessionState.swift
Sources/WithinCore/ShortcutGesture.swift
THIRD_PARTY_NOTICES.md
Tests/AudioBufferStress/main.c
Tests/Tooling/test_publication.py
Tests/WithinCoreTests/ClipboardLeaseTests.swift
Tests/WithinCoreTests/InsertionTrialTests.swift
Tests/WithinCoreTests/IntegrityTests.swift
Tests/WithinCoreTests/NetworkBoundaryTests.swift
Tests/WithinCoreTests/ShortcutTests.swift
Tests/WithinCoreTests/SystemBoundaryTests.swift
Tests/WithinCoreTests/WorkflowTests.swift
docs/ARCHITECTURE.md
docs/PRIVACY.md
docs/PUBLICATION.md
docs/VALIDATION.md
docs/brand/within-logo.png
scripts/build.sh
scripts/download-development-model.py
scripts/make-icon.swift
scripts/package-source.py
scripts/prepare-fluidaudio.sh
scripts/prepare-model-manifest.py
scripts/publication_policy.py
scripts/test.sh
""".split())

# Deliberately bounded checks, not a complete secret or privacy detector.
PATTERNS = (
    ("private key", re.compile(rb"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----")),
    ("GitHub token", re.compile(rb"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})\b")),
    ("provider key", re.compile(rb"\bsk-(?:proj-|ant-)?[A-Za-z0-9_-]{32,}\b")),
    ("AWS access key", re.compile(rb"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b")),
    ("Slack token", re.compile(rb"\bxox[baprs]-[A-Za-z0-9-]{20,}\b")),
    ("JWT", re.compile(rb"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b")),
    ("personal home path", re.compile(rb"(?:/(?:Users|home)/[A-Za-z0-9_.-]+|[A-Za-z]:\\Users\\[A-Za-z0-9_.-]+)")),
)


class PolicyError(Exception):
    """Content is outside the public boundary or cannot be checked safely."""


@dataclass(frozen=True)
class Entry:
    path: str
    mode: str
    oid: str


def git(root: Path, *args: str) -> bytes:
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True)
    if result.returncode:
        # Git errors can contain filesystem paths or untrusted repository data.
        raise PolicyError("Git inspection failed; use a full, conflict-free checkout.")
    return result.stdout


def repository_root() -> Path:
    return Path(git(Path.cwd(), "rev-parse", "--show-toplevel").decode().strip())


def index_entries(root: Path) -> list[Entry]:
    entries = []
    for record in git(root, "ls-files", "--stage", "-z").split(b"\0"):
        if not record:
            continue
        metadata, path = record.split(b"\t", 1)
        mode, oid, stage = metadata.decode("ascii").split()
        if stage != "0":
            raise PolicyError("Unmerged index entries cannot be published.")
        entries.append(Entry(path.decode("utf-8", "surrogateescape"), mode, oid))
    if not entries:
        raise PolicyError("No staged/tracked files to publish.")
    return entries


def tree_entries(root: Path, revision: str) -> list[Entry]:
    entries = []
    for record in git(root, "ls-tree", "-r", "-z", revision).split(b"\0"):
        if not record:
            continue
        metadata, path = record.split(b"\t", 1)
        mode, _kind, oid = metadata.decode("ascii").split()
        entries.append(Entry(path.decode("utf-8", "surrogateescape"), mode, oid))
    return entries


def inspect_content(label: str, data: bytes) -> None:
    for category, pattern in PATTERNS:
        match = pattern.search(data)
        if match:
            line = data[:match.start()].count(b"\n") + 1
            raise PolicyError(f"{label}:{line}: possible {category}; inspect privately.")


def validated_blobs(root: Path, entries: list[Entry]) -> list[tuple[Entry, bytes]]:
    checked = []
    for entry in entries:
        if entry.path not in PUBLIC_PATHS:
            # Never echo a private filename into a public CI log.
            raise PolicyError("A tracked path is outside the public allowlist; inspect git status locally.")
        if entry.mode not in {"100644", "100755"}:
            raise PolicyError(f"{entry.path}: only regular files may be published.")
        data = git(root, "cat-file", "blob", entry.oid)
        if entry.path == "docs/brand/within-logo.png":
            if not data.startswith(b"\x89PNG\r\n\x1a\n"):
                raise PolicyError(f"{entry.path}: expected the reviewed PNG asset.")
        else:
            try:
                data.decode("utf-8")
            except UnicodeDecodeError as error:
                raise PolicyError(f"{entry.path}: unexpected binary content.") from error
            if b"\0" in data:
                raise PolicyError(f"{entry.path}: unexpected binary content.")
        inspect_content(entry.path, data)
        checked.append((entry, data))
    return checked


def check_history(root: Path) -> tuple[int, int]:
    if git(root, "rev-parse", "--is-shallow-repository").strip() != b"false":
        raise PolicyError("History checking requires a full checkout; fetch the complete history first.")
    revisions = git(root, "rev-list", "HEAD").decode().splitlines()
    seen = set()
    for revision in revisions:
        inspect_content(f"commit {revision[:12]}", git(root, "cat-file", "commit", revision))
        entries = [entry for entry in tree_entries(root, revision) if entry not in seen]
        validated_blobs(root, entries)
        seen.update(entries)
    return len(revisions), len(seen)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--all-history", action="store_true", help="also check every commit reachable from HEAD")
    args = parser.parse_args()
    try:
        root = repository_root()
        entries = index_entries(root)
        validated_blobs(root, entries)
        print(f"Publication policy passed for {len(entries)} Git-index files.")
        if args.all_history:
            commits, versions = check_history(root)
            print(f"Publication history passed for {commits} commits and {versions} file versions.")
    except PolicyError as error:
        print(f"Publication refused: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
