# Publication policy

Publish what users and contributors need to understand, build, test, and safely use Within. Keep working context private by default.

## Public material

- Application source, focused tests, dependency patches, and reproducible build scripts.
- Required licenses, attribution, app metadata, and approved brand assets.
- Concise usage, architecture, privacy, contribution, and validation documentation.
- User-visible changes and scoped verification results needed to review a change.

Working memory, agent setup, prompts, internal plans, research, raw reports, personal notes, machine details, recordings, credentials, and session history do not belong in the public repository or its attachments. Summarize an essential fact into the appropriate public document after reviewing it; do not copy a working document wholesale.

## Before every push

1. Stage specific intended paths. Read `git diff --cached`, including every new file, and review commit messages and author identity. Prefer a GitHub noreply email.
2. Run `python3 scripts/publication_policy.py --all-history`. It checks the Git index and every commit reachable from HEAD against an explicit path allowlist, regular-file modes, and a limited set of secret/personal-path patterns. Use a full checkout, not a shallow clone.
3. Run relevant tests. Describe what was actually observed and what remains unverified.
4. Review any issue, pull request, screenshot, or attachment separately. Automated repository checks cannot assess every kind of private context.

New public files require an intentional allowlist change in `scripts/publication_policy.py`. Do not broaden it to admit working directories. `.gitignore` reduces accidental staging; it does not protect already tracked files or erase history. The CI publication job repeats the checks after upload and is a backstop, not a pre-publication privacy boundary. Local checks and human review must happen first.

## Source archives and releases

After staging and reviewing the source tree, run:

```sh
python3 scripts/package-source.py --output build/Within-source.zip
```

The packager validates and archives Git-index objects, excluding untracked files and unstaged edits. It refuses disallowed tracked content. It does not read an entire checkout recursively. Run the history check separately before publishing. Build and inspect a fresh archive for each release; never reuse an unreviewed development bundle or add raw test output.

Test builds are signed with a self-signed Made Ordinary certificate named "Within Signing", kept only in the maintainer's keychain. It is not an Apple-trusted identity, so macOS still asks people to confirm the first open. It gives every build the same designated requirement, pinned in `scripts/signing-requirement.txt`, so macOS permissions carry over between updates. `scripts/release.sh` refuses to build a release without that certificate or with a different one. Never commit, attach or upload its private key or an exported `.p12`; keep a backup outside the repository. A new certificate makes everyone allow permissions once more, so change the pinned requirement only on purpose.

Release notes are shown in the app's Settings → About. Write them for people using Within: what changed for them, in plain words, and how to update.

Publish essential release notes, checksums, required licenses, and honest validation limits. Keep internal work logs and raw measurements private. If restricted material is published, stop sharing it, rotate any exposed credentials, and assess history/cache cleanup; deleting a current file alone is insufficient.
