# Security

Compass holds financial data, so security reports are taken seriously.

## How Compass protects data

- Everything stays on the Mac: a SwiftData store inside the app's sandbox container, with no hosted service and no analytics.
- The SimpleFIN access URL and the Claude endpoint key live in the Keychain, never in the store or the repository.
- The app is sandboxed. Its network use is bank sync through SimpleFIN and optional merchant-logo fetching.
- Claude access is off by default. When it's on, Compass serves MCP on `127.0.0.1` only, and every request must carry a random key from Settings.
- The window can lock on launch or after sleep and idle, unlocking with Touch ID or the Mac password.

## Reporting a vulnerability

Use GitHub's private reporting: the **Security** tab, then **Report a vulnerability**. Please don't open a public issue.

In scope: anything that could expose the store, the backups, the Keychain entries or the localhost endpoint to another process, another user or the network, or that lets Claude's tools change data they shouldn't.

Never include real financial data in a report. Reproduce with the sandbox (`--sandbox --seed-demo`).
