# Repository Guidelines

## Project Structure & Module Organization

This is a macOS SwiftUI menu-bar app built by the `TokenMeter` target in
`TokenMeter.xcodeproj` (Swift 6, macOS 14+).

- `TokenMeter/TokenMeterApp.swift` defines app and window entry points.
- `Models/` contains Codable domain types such as subscriptions and quotas.
- `Providers/` contains the provider protocol, demo data, and live API clients.
- `Services/` owns local credential-file access and Kimi OAuth flows.
- `Store/` contains `UsageStore`, the shared app state and refresh orchestration.
- `Views/` contains SwiftUI screens and reusable view components.
- `Resources/PlatformIcons/` contains bundled provider PNG assets.

Keep new files in the directory matching their responsibility and add them to
the Xcode project target when needed.

## Build, Test, and Development Commands

Open the project in Xcode with `open TokenMeter.xcodeproj`, or build from the
repository root:

```bash
xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

Use `-configuration Release` for an optimized build. `xcodebuild -list` shows
the available target and scheme names. Run the configured Swift Testing target
with:

```bash
xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter \
  -configuration Debug test CODE_SIGNING_ALLOWED=NO
```

## Coding Style & Naming Conventions

Follow existing Swift style: four-space indentation, one type per logical
responsibility, `UpperCamelCase` for types, and `lowerCamelCase` for properties
and methods. Prefer SwiftUI composition, `async`/`await`, value types, and
guard clauses. Match the concise switch-expression style already used in the
models. No formatter or linter configuration is checked in; keep formatting
Xcode-standard and make the smallest focused diff.

## Testing Guidelines

Tests use Swift Testing in the `TokenMeterTests` target. Keep files named
`*Tests.swift` under `TokenMeter/Tests/` and cover provider parsing, malformed
responses, and authentication failures. The existing suite exercises quota
kind compatibility, Kimi window mapping, deduplication, and missing data.
Run it with the `xcodebuild ... test` command above.

## Commits & Pull Requests

No Git history is present in this checkout, so no repository-specific commit
convention can be inferred. Use short imperative subjects (for example,
`Add Kimi usage parsing`) and keep unrelated changes separate. Pull requests
should explain behavior changes, identify affected providers or views, include
verification commands, and attach screenshots for visible UI changes. Never
commit API keys, OAuth tokens, or other credentials; credentials belong in the
private `Application Support/TokenMeter/credentials.json` file managed by the app.
