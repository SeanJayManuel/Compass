# Compass

A personal, local-first Mac app for net worth, accounts, goals, spending and a Life section. One user, all USD, local data, macOS 26 or later.

## Docs (read when needed)

| File | Read it when |
| --- | --- |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Targets, data flow, where code belongs |
| [docs/SPEC.md](docs/SPEC.md) + [docs/DECISIONS.md](docs/DECISIONS.md) | Planning a feature. DECISIONS wins where they differ |
| [docs/PERFORMANCE.md](docs/PERFORMANCE.md) | Feature/query/cache/motion/dependency changes: caps and validation |
| [docs/DESIGN.md](docs/DESIGN.md) | Any UI change; open live checks |
| [docs/TESTING.md](docs/TESTING.md) | Writing tests: only approved seams |
| [docs/DEVELOPING.md](docs/DEVELOPING.md) | Launch options, formats, Claude's endpoint, signing, maintainer workflow |
| [docs/USING.md](docs/USING.md) | What each screen does; installing a Release build |
| [docs/HISTORY.md](docs/HISTORY.md) | Milestones, perf measurements, the M1 checklist |
| [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md) | Pull requests; the security model |

## Code map

- **`Core/Sources/Core/`** — all logic, one file per seam, tests in `Core/Tests/CoreTests/<Name>Tests.swift`.
  - Net worth: `NetWorthSeries`, `TimeRange`, `Staleness`, `BalanceSnapshot`, `Account`, `Day`, `Contributions`, `MonthlyReview`
  - Sync: `SimpleFINClient`, `SyncMerge`, `AutoSync`, `TransactionDedupe`, `TransferMatch`
  - Imports: `MonarchBalanceImport`, `MonarchTransactionImport`, `CSV`, `Backup`
  - Goals: `Goal`, `GoalProgress`, `GoalAttention`, `GoalLifecycle`, `GoalFunding`
  - Pay: `Pay`
  - Spending: `Transaction`, `Spending`, `Splits`, `FlexBudget`, `BudgetSchedule`, `CategoryRules`, `CategoryGuess`, `TransactionSearch`, `QuickSearch` (⌘K), `MerchantDomain` (logos), `PendingDecisions` (Review's undo)
  - Life: `LifeGoals`, `Habits`, `HabitTrends`, `HabitReminderLink`, `WeeklyReview`, `ReminderAgenda`, `ReminderListNames`, `ReminderRepeat`, `CalendarWeek`, `FreeTime`, `Playbook`, `PlaybookPurchases`, `PlaybookReminderLink`
  - Notes: `Notes`
  - Other: `StoreGuard`, `LockPolicy`, `ClaudeChanges` and `ClaudeUpkeep` (what Claude may change, and undo), `SyntheticData`
- **`App/`** — the SwiftUI app. `CompassApp.swift` is the entry point, with `RootView`, `Navigation` (screens) and `AppCommands` beside it; debug launch arguments are parsed in `Debug/DebugSupport.swift`.
  - `Store/` — SwiftData records (`*Record(s)`), `CompassStore` (and `+Transactions`), `NetWorthCache`, `PayCache` (paychecks) and `SearchCache` (what ⌘K searches), read off the main thread, `BackupExport`
  - `Claude/` — `ClaudeEndpoint` (MCP over localhost), `ClaudeTools` (the `ClaudeTool` registry), `ClaudeReadTools` and Money/Pay/Life (reads), `ClaudeChangeTools` and other `Claude*Tools` (writes, undo), `ClaudeAccess`. `Sync/` — `SyncService`, `Keychain`. `Lock/` — `AppLock`, `LockView`. `Reminders/` — `RemindersService`, `PlaybookReminders`, `CalendarService` (EventKit)
  - `Design/` — `Tokens`, `Theme` (palette, accents), `Components`, `MerchantLogos`, `HabitIcon`, and the icon, avatar and amount helpers
  - `Views/` — top-level screens: `MoneyOverview`, `GoalsView`, `SpendingView`, `TransactionsView` (and `TransactionFilters`), `NotesView`, `SettingsView`, plus `AppFrame` (sidebar and top bar), `TopBarActions` (screen controls, ⋯ menu), `QuickSearchPanel` (⌘K), `ReviewView` and `ReviewDetails`, `Sheets`, `GoalEditor`, `MilestoneRows`, `TransactionDays`, `TransactionPanels`
  - `Views/NetWorth/` — `NetWorthView` and its charts. `Views/Accounts/` — `AccountsBreakdown` (expandable class rows) and history panels. `Views/Goals/` — `GoalList`, `GoalDetailView`, `GoalHistoryChart`, `GoalReading`
  - `Views/Spending/` — budget sheet (`BudgetSheetView` and a file per part) and editor, categories, `MonthTransactions`, `SpendingOverTime`, `CategoryCharges`
  - `Views/Life/` — `LifeOverview`, `WeekBand` (This week), `RemindersGlance` (To do), `HabitViews`, `HabitTicker`, `HabitsView`, `PlaybookView` and `PlaybookEditor`, `VisionEditor`
  - `Views/MenuBar/` — `TodayPanel`
  - `Views/Settings/` — one file per tab (Appearance, Profile, Pay, Security, Data, `HowItWorksSettings`), `Guide` (How it works) and `BackupWriter`
  - `Debug/` — `DebugSupport`, `SelfCheck`, `Snapshots`, `Perf` (debug builds only)
- **`App/Fonts/`** — Geist, Spectral, Geist Serif and Public Sans (OFL; see `THIRD_PARTY.md`).
- **`Bridge/`** — `compass-mcp`, Claude desktop's bridge to the endpoint. **`DockTile/`** — the Dock tile plug-in. **`scripts/export-icon/`** — renders the bundled icon. **`project.yml`** — XcodeGen project (the `.xcodeproj` is generated, not committed); **`Config/`** — signing xcconfigs (ad hoc by default; a gitignored `Local.xcconfig` sets a team). **`.github/`** — CI (Core tests, app build, format check), issue and PR templates.

## Rules

- Money is `Decimal` or integer cents, never `Double`. Debts are stored as negative balances, so net worth is a plain sum. Except values handed to Swift Charts, which plots `Double` (no math on those).
- Logic lives in `Core` with unit tests. Views stay thin.
- Tests never call live SimpleFIN: use saved JSON fixtures, or the demo token (DEVELOPING) by hand. The Bridge expects 24 requests or fewer per day and can disable tokens that exceed it; `/accounts` covers at most 90 days per request.
- Never commit balances, access URLs, setup tokens, exports or stores, and never put real names, accounts or figures in code, tests, docs, commits or screenshots: this repository is public. Test against `--sandbox` and the demo data. For a real export, print only counts and value shapes (digits as 9, letters as a).

## Working agreement

- Before calling a task done: the `Core` tests (`cd Core && xcrun swift test`; the `swift` on PATH can't link the SDK), the app build, and swift-format (command in CONTRIBUTING).
- Work test-first with the `tdd` skill, and only at approved seams ([docs/TESTING.md](docs/TESTING.md)). Propose new seams (with what they catch and miss) and wait for the maintainer's OK before writing tests for them.
- Read PERFORMANCE before feature work: compare optimized before/after runs, keep correctness, record results in HISTORY, fix regressions. New service costs or raised caps need the maintainer.
- Keep building; stop only for what needs the maintainer (seams, passwords, licences, design sign-off), batched.
- Review with `code-review` before handoff and fix its findings.
- UI changes go through [docs/DESIGN.md](docs/DESIGN.md)'s quality check, scaled to the change: a small change renders its screen, a shared component every screen.
- Contributors use pull requests (CONTRIBUTING). The maintainer's own sessions follow "Maintainer workflow" in DEVELOPING: commit to `main`, push, install the Release build.

- Keep the docs current unasked: every change updates the docs it affects, in the same commit. Check:
  - files added, moved or renamed → the code map above
  - a decision the maintainer makes → `docs/DECISIONS.md` (dated)
  - a seam approved → `docs/TESTING.md`
  - a launch option, format or build/install step → `docs/DEVELOPING.md`
  - a theme, token or design-rule change → `docs/DESIGN.md`
  - a performance or scope rule → `docs/PERFORMANCE.md`
  - something finished or re-measured → `docs/HISTORY.md`
  - what a screen does → `docs/USING.md`; what a number means → `Guide.swift`
  - anything that makes a doc wrong → fix or remove that line
- Keep the docs lean: describe how things are now; a superseded decision replaces the old one. `docs/HISTORY.md` is the only log.
- Keep this under about 1,000 words; it loads every session. Keep rules, docs index and code map here; history, measurements and decisions go in `docs/`. If an update would push it over, move detail out to a doc instead.
