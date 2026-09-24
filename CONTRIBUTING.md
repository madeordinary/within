# Contributing

Within is a Dictation engineering preview. Keep changes focused and preserve explicit choices around microphone access, model downloads, insertion, clipboard use, and retention.

For code changes, explain the user-visible problem and resulting behavior. Include relevant automated checks and distinguish simulated checks from observed behavior on a real target app. Read [architecture](docs/ARCHITECTURE.md), [privacy](docs/PRIVACY.md), and [validation](docs/VALIDATION.md).

```sh
./scripts/test.sh
./scripts/build.sh
python3 -m unittest discover -s Tests/Tooling -p 'test_*.py'
```

After staging the intended files, review `git diff --cached` and run:

```sh
python3 scripts/publication_policy.py --all-history
```

The [publication policy](docs/PUBLICATION.md) applies to files, commit messages, issues, pull requests, and release attachments. New public paths need an explicit allowlist change. Avoid bulk staging from a checkout containing working notes. A passing automated check does not replace reading the proposed content.

Use synthetic text and minimal reproduction steps. Do not attach private dictation, credentials, raw diagnostics, personal paths, or unreviewed screenshots. Keep source and dependency license notices intact. Report security or privacy vulnerabilities through [private vulnerability reporting](https://github.com/madeordinary/within/security/advisories/new).
