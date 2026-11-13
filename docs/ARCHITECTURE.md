# Architecture

How Compass is put together, where code belongs, and what it deliberately doesn't do. The file-by-file code map is in [CLAUDE.md](../CLAUDE.md).

## Targets

`project.yml` (XcodeGen) defines three targets plus one Swift package:

| Target | What it is |
| --- | --- |
| `Core` (Swift package in `Core/`) | All logic: net worth, sync merging, imports, budgets, goals, pay, habits, reminders' rules, what Claude may change. Plain value types, no SwiftUI or SwiftData, fully unit tested |
| `Compass` (`App/`) | The SwiftUI app: SwiftData storage, screens, EventKit, the Keychain, the lock, and the local MCP endpoint for Claude |
| `compass-mcp` (`Bridge/`) | A small command-line bridge that Claude desktop launches; it forwards JSON-RPC from stdin to the running app over `127.0.0.1` |
| `CompassDockTile` (`DockTile/`) | A Dock tile plug-in that draws the chosen icon (macOS only loads it for notarized apps, so the install step also bakes the icon) |

`Core` has no dependencies. The app links only Apple frameworks.

## Data flow

```
SimpleFIN Bridge ──► SimpleFINClient ──► SyncMerge ─┐
Monarch CSV exports ──► Monarch*Import ─────────────┼─► CompassStore (SwiftData records)
Manual entries, Claude's writes ────────────────────┘          │
                                                                ▼
                          NetWorthCache · PayCache · SearchCache (computed off the main thread)
                                                                │
                                               SwiftUI screens and ClaudeTools read these
```

- **Sync** (`App/Sync/SyncService`) asks `Core`'s `SimpleFINClient` for accounts and posted transactions, then `SyncMerge`, `TransactionDedupe`, `TransferMatch` and `CategoryRules` decide what to keep and how to file it. `AutoSync` limits automatic syncs to once a day.
- **Storage** (`App/Store/`) is SwiftData. Each `*Record` model converts to and from a `Core` value type (`AccountRecord.account`, `TransactionRecord.transaction`), and `CompassStore` offers typed reads and writes in `Core`'s terms. Views should ask `CompassStore` or a cache rather than build queries. `context.all(Record.self)` reads every record of a type; a failed fetch or background save is logged (subsystem `com.compass.store` in Console), and an edit that can't be saved goes through `SaveFailures.shared.attempt`, which shows one alert.
- **Caches** recompute derived figures (net worth series, paychecks, the ⌘K index) in the background after saves, so screens open without doing that work.
- **The store guard** (`Core/StoreGuard`, used by `CompassStore.container(at:)`) refuses to open a store with models or fields this build doesn't know, because SwiftData would silently drop them. A model or field removed on purpose must be listed in `CompassStore.retired`.
- **Backups**: the installed app writes a JSON bundle of everything once a day (two weeks kept); `Core/Backup` defines the format.

## Life and Apple services

Apple Reminders and Calendar own their data. `App/Reminders/` reads them live through EventKit; Compass stores only links and settings around them (a habit linked to a daily reminder, a quarter goal's money target, the Playbook's repeating entries). Lists get their jobs by name (`Core/ReminderListNames`: the standard names, or the ones typed in Settings › Data). Sandbox runs (`--sandbox`) use made-up reminders and events and never touch EventKit.

## Claude access

When enabled in Settings, `ClaudeEndpoint` listens on `127.0.0.1` only and requires a random key from the Keychain on every request. `MCPProtocol` handles `initialize`, `tools/list` and `tools/call`.

- Each tool is one `ClaudeTool` value holding its MCP schema and its handler, so a tool can't be listed without a handler or the reverse. `ClaudeTools.all` gathers them; `call` looks a tool up by name.
- Read tools (listed in `ClaudeReadTools`, answered in `ClaudeMoneyTools`, `ClaudePayTools` and `ClaudeLifeTools`) use the same `Core` functions the screens use.
- Write tools go through `Core`'s `ClaudeRules`, `ClaudeChanges` and `ClaudeUpkeep`, which decide what may change, and every write is logged (`ClaudeActivityRecord`) so it can be undone from Settings or by Claude.
- Synced balances, transaction amounts, dates and merchants, and sync itself are read-only to Claude. Nothing moves money.

To add a tool: write its rule in `Core` with tests, add a `tool(…, run:)` entry with its handler to the matching `App/Claude/*Tools.swift` list, and list it in [DEVELOPING.md](DEVELOPING.md).

## Where code belongs

- **A calculation, rule or parser** goes in `Core` with tests at a named seam ([TESTING.md](TESTING.md)). If you'd want to test it, it belongs there.
- **A query** goes in `App/Store/` as a `CompassStore` method; **a figure several screens need** goes in a cache.
- **A view** arranges what `Core` and the store give it. Shared pieces live in `App/Design/` (`Components`, `Tokens`, `Theme`); the rules are in [DESIGN.md](DESIGN.md).
- **Debug-only tooling** (demo seeding, snapshots, self-checks, perf runs) lives in `App/Debug/` and is compiled out of Release builds.

## Non-goals

Compass is for one person on one Mac. Multiple users, a hosted service or sync between devices, currencies other than USD, platforms other than macOS, analytics and holdings-level investment performance are out of scope (see [DECISIONS.md](DECISIONS.md)). Money is always `Decimal` or integer cents, never `Double`, and debts are stored as negative balances so net worth is a plain sum.
