# Changelog

All notable changes are documented here.

## Unreleased

### Changed

- Clarified installation paths, including the published unsigned v0.1.0 archive and the distinction between that release and `main`.
- Corrected the public clone URL and documented the Xcode 26+ source-build requirement.
- Documented the current notification scope, Chinese-only UI, local persistence, plaintext credential storage, persistent WebKit site data, and public issue workflow.
- Added security-reporting guidance, contribution guidance, and public issue/pull-request templates that prohibit sharing credentials.
- Added pinned CI dependencies, verified Gitleaks scanning, universal release packaging, and an original application icon.
- Clarified used-quota percentages, actual synchronization state, notification permission, and local plaintext storage in the UI; added app version and issue links.

### Fixed

- Prevented the test host from initializing production stores, windows, or background refreshes.
- Derived OAuth form state from authorization data rather than status-message wording and cleared stale state when switching methods.
- Prevented cancelled refresh completions from overwriting newer state or clearing a newer refresh task.
- Preserved corrupt subscription metadata, blocked configuration mutations until recovery, and exposed persistence errors with a reload action.

## [v0.1.0](https://github.com/Amdeo/TokenMeter/releases/tag/v0.1.0) — 2026-09-08

First public release. See the linked GitHub release for its published notes and assets.
