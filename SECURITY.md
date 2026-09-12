# Security policy

## Reporting a vulnerability

This repository does not advertise a private security-reporting channel. Do **not** include exploit details, API keys, OAuth tokens, cookies, credential files, account identifiers, or screenshots containing them in a public issue.

To request a private reporting route, open a minimal public GitHub issue titled `Security contact request`. State only that you have a potential security report and provide a way for maintainers to contact you; wait for a maintainer response before sharing details. If the report involves active credential exposure, revoke or rotate the affected credentials first when possible.

For non-sensitive defects, use the normal public issue workflow.

## Scope and threat model

TokenMeter runs locally as the signed-in macOS user and sends configured credentials to the corresponding provider endpoints to retrieve usage or balance data. It is not a credential vault, network isolation layer, or account-security product.

Important boundaries:

- Credentials are stored as plaintext JSON in `~/Library/Application Support/TokenMeter/credentials.json`. The app sets its containing directory to `0700` and the file to `0600`, but malware, another process acting as the same user, backups, or anyone who obtains the file can potentially use those credentials.
- Subscription metadata is stored separately in `subscriptions.json`; preferences and notification state use `UserDefaults`.
- Embedded web sign-in uses WebKit's persistent default website-data store. Cookies and local storage may remain there between sessions.
- Notifications can reveal that a configured account has a low balance, needs reauthentication, or has repeated service errors to anyone able to view macOS notifications.
- Provider responses, account permissions, endpoints, and authentication behavior are outside this repository's control. Use accounts and credentials that you are authorized to use.

Protect your local macOS account, use provider credentials with the minimum privileges available, and revoke or rotate a credential if it may have been exposed. Do not send credentials in issues, pull requests, logs, screenshots, or browser exports.

## Experimental OAuth providers

Claude, OpenAI Codex and Kimi Code integrations use OAuth clients associated with their respective first-party CLIs. Claude requests scopes including API-key creation, inference, MCP servers and file upload, broader than TokenMeter's usage-reading purpose. These integrations are experimental. Web-session integrations extract tokens from local storage or session cookies from the app's embedded WebKit browser, not from an external Chrome profile. Their APIs may be unsupported, change, fail, or be subject to provider restrictions. Review authorization screens and provider terms before continuing; cancel if you do not accept the requested access. This document makes no conclusion about whether a provider permits a particular use.

## Version scope

This policy describes the current `main` branch. The published v0.1.0 release is an unsigned snapshot and may not contain changes present on `main`.

TokenMeter is an independent project, not affiliated with or endorsed by the
listed providers. Provider names and logos identify compatible services and
remain the property of their respective owners. An official domain does not
imply that its endpoint is a supported public third-party API.
