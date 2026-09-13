# Changelog

All notable changes are documented here.

## [v0.2.0](https://github.com/Amdeo/TokenMeter/releases/tag/v0.2.0) — 2026-09-13

### Added

- Added Claude (OAuth authorization code, Pro/Max plan quota windows) and OpenAI Codex (device OAuth, Codex quota windows) providers.
- Added the Siyu API relay provider with balance and daily/weekly/monthly plan windows.
- Made providers a folder-based extension point: each provider owns its stable IDs, login site, authorization handlers, card renderer, and icon under `Providers/Extensions/<id>/`, so adding one takes a new folder plus a single line in `ProviderCatalog`; shipped a copy-ready template, the provider development guide, and an add-relay skill.
- Published releases from a tag-driven GitHub Actions workflow (`Release`) that runs the test suite, builds the universal unsigned archive, writes the SHA-256 checksum, and attaches both to the GitHub Release; signed/notarized packages are still built locally.

### Changed

- Merged the relay providers into one site-driven implementation; the shared machinery now lives in `Providers/Common/` instead of the app-level `Services/` layer.
- Restored subscription drag-to-reorder with animated drop placement, and balanced the overview header icon spacing and card insets.
- **Release archives are now named `TokenMeter-<version>-macos-universal.zip` and published with a matching `.sha256` file.**
- Moved add-subscription, settings, and quit into a right-click menu on the menu-bar icon; the overview's bottom action row is gone and the synchronization status now sits next to the service count in the header.
- Showed Siyu API plans as daily, weekly, and monthly quota windows with reset hints instead of a single monthly row, and listed Siyu in the README provider tables.
- Added an opt-in frosted-glass panel background for light appearance; the light panel is plain white by default.
- Requested notification authorization once at launch instead of prompting in the overview panel, and only when alerts are enabled and the system has not decided yet; the settings panel still reports status and refusal reasons.
- Clarified installation paths, including the published unsigned v0.1.0 archive and the distinction between that release and `main`.
- Corrected the public clone URL and documented the Xcode 26+ source-build requirement.
- Documented the current notification scope, Chinese-only UI, local persistence, plaintext credential storage, persistent WebKit site data, and public issue workflow.
- Added security-reporting guidance, contribution guidance, and public issue/pull-request templates that prohibit sharing credentials.
- Added pinned CI dependencies, verified Gitleaks scanning, universal release packaging, and an original application icon.
- Clarified used-quota percentages, actual synchronization state, notification permission, and local plaintext storage in the UI; added app version and issue links.

### Fixed

- Grouped Siyu API plan windows by an explicit key instead of the displayed plan name, so two plans with the same name (or no name) stay separate sections, and omitted windows the API does not cap instead of rendering them as exhausted `$0.00 / $0.00` rows.
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
