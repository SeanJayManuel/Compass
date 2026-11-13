# Compass — product specification

Current scope, refreshed Nov 10, 2026. [DECISIONS.md](DECISIONS.md) records the project's decisions and wins where the two differ. [HISTORY.md](HISTORY.md) holds milestones and measurements; it is not a backlog.

## Purpose and boundaries

A personal, local-first Mac app that replaces Monarch Money and answers: where do my money, week and quarter stand? One user; all USD. SwiftUI, SwiftData and Swift Charts on macOS 26 or later. `Core` owns the calculations and rules; views present them. `main` is the current version and supplies the Release app in `/Applications`.

Money, budgets, Life, Calendar, Pay, Playbook, Notes and Claude access are built. iPhone/iCloud, holdings-level investment performance, health records, journal imports, multi-user sharing and a hosted service are outside the current scope. A personal agent may later use the existing local endpoint. These are possibilities, not commitments.

Keep the app small: a feature must answer a recurring question or remove repeated work. Prefer an existing screen, model or native control. Preserve performance and existing behavior; the feature-work gate and caps are in [PERFORMANCE.md](PERFORMANCE.md). Design rules and visual checks are in [DESIGN.md](DESIGN.md).

## Screens and behavior

The Workbench frame has a folding sidebar, global search (⌘K), screen controls and a ⋯ menu. Review comes first; Life and Money have their own groups, Notes is under Context, and Settings sits at the bottom. The app opens on Money. ⌃⌘S folds the sidebar; narrow windows fold it automatically. Native menus, sheets and keyboard shortcuts remain.

| Screen | Job and content |
| --- | --- |
| Review | New transactions and this month's one-sided transfer suggestions. Current category evidence and budget treatment, individual/batch confirmation, five-second Undo, Decided list and visible saving errors |
| Money | Net worth and Asset allocation side by side when wide; expandable account classes and histories; Flexible left, Goals and Waiting on you tiles. Total/By class/Monthly charts, top-bar ranges, scrubbing and goal markers |
| Spending | Flexible amount left and pace; planned/actual/remaining income, fixed, flexible, irregular and savings lines; category charges and collapsed monthly transactions. Budget/Over time and month controls; editing, history fill and Categories in ⋯ |
| Transactions | Lazy day groups, merchant/statement search, category/month/flag filters and refiling. Details beside the list when wide, inline when narrow. A chosen month's figures/categories and six months of income/spending bars; summary is independent of list pagination |
| Goals | Attention-ordered list and selected goal's details, or a separate detail page when narrow; progress, pace, history, target/projection, funding, milestones, notes and rewards |
| Life | Quarter clock; Sunday–Saturday Calendar day tiles; two-week habit strips beside To do with Admin; This quarter with Coming up; Vision, yearly bets and Living List |
| Habits | Today's tally, aggregate day grid and each habit's streaks and history. Check-ins and earlier days are edited from Life |
| Playbook | Searchable list of Today, My sizes and entries grouped by area; selected pick, routine or note in full. Repeats, weekday steps, due/restock hints and linked reminders |
| Notes | Short standing rules and reasons grouped by topic. Full bodies, editing and deletion; refer to figures elsewhere instead of copying them |
| Settings | Profile, Appearance, Pay, How it works, Security and Data in the main canvas, behind the same lock. ⌘, opens Settings; ⓘ opens the guide for the current screen |

The menu bar panel shows today's reminders, flexible amount left and habits. It reveals no content while locked. With the menu bar enabled, closing the window keeps Compass running; modes that lock also lock on close.

## Money and data rules

- Money uses `Decimal` or integer cents. `Double` is only for chart coordinates. Debts are stored negative, so net worth is a sum; debt rows and histories display positive amounts owed.
- An account's latest balance carries forward. Excluded accounts do not count; archived accounts stop counting after their last balance. Synced balances are stale after 7 days, manual ones after 45.
- First balances are openings, not growth. Changes and goal pace exclude them, except money moved from another tracked account. Totals retain them.
- A manual balance on a synced account is a visible pin. Same-day sync never overwrites it; newer data takes over, and a sync within 1% clears the pin. Original synced values remain available.
- SimpleFIN Bridge supplies balances and posted transactions. Automatic sync is at most daily when connected; failures retry after an hour, with at most 12 automatic attempts a day. Manual Sync Now is available. Stay below the Bridge's 24-request daily limit and 90-day request window; later syncs reach 30 days before the newest synced transaction.
- Monarch balance and transaction CSVs preserve history. Import/sync is idempotent, account merges retain the old feed identity, and duplicate Monarch/SimpleFIN purchases are reconciled. See [DEVELOPING.md](DEVELOPING.md) for formats and service quirks.
- Merchant rules distinguish money in from money out. Imported history is reviewed; newly synced transactions await confirmation even when a rule or guess assigned a category. Transfers between tracked accounts are neither spending nor income. One-sided transfer wording is a suggestion to confirm, not an automatic transfer.
- Spending is net of refunds and reimbursements; splits count by category. Goal-funded spending stays visible in history but is excluded from budget expenses, flexible pace and daily spent. Transaction summaries include it in spending. A one-off mark does not exclude spending.
- Planned income funds fixed and irregular bills, savings and the flexible remainder, never below zero. A typed flexible amount is used only without planned income. Plan changes apply to one month or onward; category roles apply across months. Savings transfers are separate from expenses.

## Goals and Pay

Money goals measure net worth, selected accounts, or FIRE (investable assets against annual spending × a multiplier). They may have a minimum, target and date. Goals behind a date need attention first. Undated goals read growing or not growing. Pace uses three months with opening balances excluded; investing-only goals use contributions with market change apart.

Crossing a target records an achievement. A newly reached goal fills its row's bar once; rewards can then be claimed with a date and optional photo. Rewards are spending, never assets. Successors are suggestions to accept or dismiss. Goals are achieved or retired with a reason, never deleted. Cash-account goals can fund transactions, tracking what remains to move from the fund.

Pay is settings plus synced paychecks: salary, schedule and a known payday, payroll contributions/match and stock-plan amounts, linked accounts, expected bonuses and vests. A paystub may fill settings but is not required every payday. The budget plans two biweekly paychecks (four weekly); extra checks, bonuses and stock stay out. Payroll buys provide actual 401(k) contributions where present; missing buys and stock contributions are estimated from settings. Savings rate uses net transfers to savings/investing plus payroll saving, with employer match counted in both saved and earned. Detailed formulas live in `Guide.swift` and `Core/Sources/Core/Pay.swift`.

## Life and context

Apple Reminders owns the task lists: This Week, Admin/Errands, This Quarter, Coming Up/Long Term and Living List. Hidden lists are excluded; shopping lists start hidden. Repeats join To do the day before due and remain while overdue. Daily repeats become linked seven-day habits; phone ticks carry back. Archived habits stop tracking. Weeks run Sunday–Saturday; stored weekday values remain Monday=0 through Sunday=6.

A quarter reminder may follow net worth or a money goal, with a target and reward. The progress bar does not automatically complete or reopen its reminder. Vision and yearly bets are editable locally; Living List stays in Reminders. The old Resolutions and separate Vision screens are retired; legacy records remain in backups.

Calendar is read through EventKit, with calendar visibility chosen in Settings. Day tiles show event chips, all-day first; events open Calendar. Playbook Today lives on Playbook. Its repeats use plain linked reminders in Repetitive Tasks, due from the last completion rather than a fixed repeating schedule. Notes store durable rules and reasons, not duplicated balances or budget figures.

## Privacy, storage and Claude

SwiftData, caches and local logo files live on the Mac. SimpleFIN access, the optional logo.dev key and the Claude endpoint key live in Keychain. FileVault, when enabled, supplies disk encryption; Security warns if it is off. The app does not add database encryption. The store guard refuses a store containing unknown models/fields. Daily JSON backups retain two weeks; manual export also writes CSVs. There is no in-app restore yet.

Lock modes are Off, When it opens (default), and After sleep or idle. Touch ID falls back to the Mac password. Hide Amounts (⌘⇧H) obscures dollar figures independently of the lock. Sandbox permissions cover selected files, network client connections, the localhost MCP server and EventKit. Bank sync and optional merchant-logo requests are the external data services; logo requests use domains rather than transaction details.

Claude access is separately enabled, off by default, loopback-only and keyed. The running app is the single writer. Claude reads through the same Core rules as the screens and can make authorized edits with a change log and undo. It confirms writes in chat. Synced balances, transaction amounts/dates/merchants and sync stay read-only; tools never move money. Event/reminder deletion and editing have specific undo/safety limits, recorded in [DECISIONS.md](DECISIONS.md); the tool inventory and connection setup are in [DEVELOPING.md](DEVELOPING.md). Turning on Claude access permits a connected client to read data independently of the visual lock.

## Validation and delivery

Use the `tdd` skill at approved [TESTING.md](TESTING.md) boundaries; propose new seams before writing tests. Core tests use saved fixtures, never live SimpleFIN. Run `xcrun swift test` in `Core` and the app build for every change. UI changes follow DESIGN's scaled render/interaction checks. Feature work follows PERFORMANCE's comparison procedure; correctness, freshness and undo must survive any optimization.

Review, update affected docs in the same change, and keep CI green. [USING.md](USING.md) has the Release install command. Live checks still open are listed in [DESIGN.md](DESIGN.md); finished implementation is not design sign-off.
