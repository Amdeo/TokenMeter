# Changelog

All notable changes are documented here.

## Unreleased

### Changed

- Requested notification authorization once at launch instead of prompting in the overview panel, and only when alerts are enabled and the system has not decided yet; the settings panel still reports status and refusal reasons.
- Clarified installation paths, including the published unsigned v0.1.0 archive and the distinction between that release and `main`.
- Corrected the public clone URL and documented the Xcode 26+ source-build requirement.
- Documented the current notification scope, Chinese-only UI, local persistence, plaintext credential storage, persistent WebKit site data, and public issue workflow.
- Added security-reporting guidance, contribution guidance, and public issue/pull-request templates that prohibit sharing credentials.
- Added pinned CI dependencies, verified Gitleaks scanning, universal release packaging, and an original application icon.
- Clarified used-quota percentages, actual synchronization state, notification permission, and local plaintext storage in the UI; added app version and issue links.

### Fixed

- Surfaced the system's reason when notification authorization is refused (unsigned builds), instead of leaving the allow-notifications button apparently inert.
- Prevented the test host from initializing production stores, windows, or background refreshes.
- Derived OAuth form state from authorization data rather than status-message wording and cleared stale state when switching methods.
- Prevented cancelled refresh completions from overwriting newer state or clearing a newer refresh task.
- Preserved corrupt subscription metadata, blocked configuration mutations until recovery, and exposed persistence errors with a reload action.
- Refused to repackage an existing release version and printed the source revision at package time, so unreleased `main` content cannot be shipped under a released version number.
- Corrected stale `PONYTAIL-DEBT.md` line references after the editor and store refactors.
- Documented the concrete first-launch steps for the unsigned build, including quarantine removal after checksum verification.

## [v0.1.0](https://github.com/Amdeo/TokenMeter/releases/tag/v0.1.0) — 2026-09-08

First public release. See the linked GitHub release for its published notes and assets.
