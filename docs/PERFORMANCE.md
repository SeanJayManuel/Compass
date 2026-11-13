# Performance and scope budget

Read before planning or implementing a feature, changing a query/cache, or adding motion or dependencies. the maintainer's direction (Nov 10, 2026): document the caps, make future feature work read them, and "we don't want to bloat the software." Performance checks stay local; no new GitHub Action or runner. Core tests continue in CI.

## Caps

Use an optimized Debug build on one Mac with the existing synthetic store: 25 accounts, 10 years of daily balances (about 91,000 snapshots), 30,000 transactions and sample goals. The caps describe the complete visible result, including background reads and drawing, not merely starting a task.

| Moment | Cap | Measurement |
| --- | --- | --- |
| Process launch to net worth on screen | Under 1,000 ms | New process, existing seeded store/cache; Touch ID excluded |
| Opening a sidebar screen, including return visits | Under 150 ms | Required content loaded and main thread settled |
| Opening ⌘K after its index is ready | Under 150 ms | `open search` |
| Typing in ⌘K | Under 100 ms per query | Results published and main thread settled |
| Net worth chart view or range switch | Under 100 ms | `switch to` and `range` lines |
| Idle physical memory | Under 200 MB | Both before and after search; not just the lower reading |
| Sync Now for 10 accounts | Under 10 s target | Network-dependent, separate demo-only end-to-end check; not timed by `--perf-run` |
| Loading flashes on Spending/Transactions | None for reads completed within 300 ms | Initial visits, return visits, month steps and view switches; `showed loading` flags an indicator that appeared |

The runner prints budgets; it **does not enforce them or fail its exit code on a breach**. A successful process exit or passing Core suite is not a UI-performance pass. Read every metric and verify the run reached `idle memory after search`; missing output, a crash or a hung run is inconclusive.

Spending's intentional switch/month animation is measured through its end (roughly half a second in recent runs). Do not compare that total with the 100 ms net worth-switch cap or hide a stall inside an animation. Compare month-step total, main-thread busy time and longest stretch with the same baseline. The 100 ms cap does not prove smooth scrolling: use Instruments for hitches, scroll/hover changes or new motion.

## Feature-work gate

1. **Before coding:** name the question or repeated work the feature serves, what it replaces, its data/read scope and likely launch, interaction and memory costs. Reuse existing screens, Core rules and native controls. A new service, dependency, stored copy or whole-history read needs a concrete benefit and measured cost. Do not add background polling or an abstraction for a hypothetical future feature.
2. **Measure the baseline:** save the current commit and complete perf log before changing behavior. Use the same Mac, Xcode, optimization, synthetic store, appearance, text size, window size and power conditions for both builds. Do not measure during builds, indexing or other heavy work. Run sequentially: the apps share the Dev perf store and preferences.
3. **Compare after:** for changes affecting runtime behavior, make five measured runs per build, alternating old/new, with one uncounted warm-up each. Compare each metric's median and retain the individual results. Label the first post-build launch separately; do not quietly discard it or call warmed disk caches a cold-disk test. Re-run a suspected regression under matched conditions.
4. **Keep correctness:** run Core tests and the app build; run affected approved behavior tests, DESIGN's scaled render checks and the relevant sandbox interactions. Verify cached results after edits/sync/undo and a relaunch. A faster screen with stale, partial or missing content fails.
5. **Review the result:** investigate any repeatable regression. A repeated cap breach, a new loading flash for a fast read, or a slowdown above 10% and at least 10 ms (memory: above 10% and at least 10 MB) blocks handoff until fixed or explicitly accepted by the maintainer. These comparison thresholds filter small timing noise; they do not relax the absolute caps. Report all exceptions. Never raise a cap or choose a slower baseline to make a feature pass.
6. **Record and ship:** put before/after medians, run conditions, correctness checks and unresolved exceptions in HISTORY. Keep this file for the policy and current constraints. Pure documentation/copy changes need source review, tests/build and affected text renders; they do not need a new five-run benchmark unless runtime behavior changed.

## Run it locally

From the repository root:

```bash
xcodegen
xcodebuild -project Compass.xcodeproj -scheme "Compass Sandbox" \
  -configuration Debug -derivedDataPath build/perf.noindex \
  -allowProvisioningUpdates SWIFT_OPTIMIZATION_LEVEL=-O \
  SWIFT_COMPILATION_MODE=wholemodule build
APP="build/perf.noindex/Build/Products/Debug/Compass Dev.app/Contents/MacOS/Compass Dev"
"$APP" --sandbox --seed-perf --seed-only
"$APP" --sandbox --unlocked --seed-perf --perf-run 2>&1 | tee /private/tmp/compass-perf-after.txt
```

Keep baseline output at a different path. Repeat the last command with separate files for each run. Launch the matching baseline binary alternately; never run them together. Both must use `--sandbox --seed-perf`; never profile an old Release copy against the real store. `--seed-only` seeds only if the perf store is empty; it is not a reset. Use a current-schema baseline if a migration makes an older build unsafe, and report that limitation.

`App/Debug/Perf.swift` times Life, Habits, Goals, Spending (both views and return visits), Transactions (first/return visits), Review, Playbook, Notes, Money, Spending month/view changes, ⌘K, net worth views/ranges and memory. Screen loads wait for their marks, then main-thread idle. The window is resized to 1440×780 points where the display permits; record its printed size. Settings and the menu bar are not timed. The search benchmark opens late enough for the delayed index read; opening search immediately after launch or just after a save needs a separate check.

`Core/Tests/CoreTests/TimingTests.swift` provides coarse algorithm guards on synthetic data at approved seam 5. Those deliberately looser debug/CI limits exclude SwiftData fetches, SwiftUI, rendering and process memory. They complement the app run; they do not certify these caps. No new test seam is approved by this document.

## Keep these properties

- Heavy SwiftData reads and searches run off the main thread, using their own contexts. Fetch only needed fields/ranges; keep lists lazy and paginated. Do not move the work into `body` or repeat a whole-history scan on each keystroke.
- `NetWorthCache` saves derived balances/progress and refreshes on relevant data changes or a new day. `PayCache` reads paycheck deposits in the background. `SearchCache` preloads after five seconds, marks itself stale on saves and refreshes on the next opening. Changing one requires checking invalidation as well as speed.
- Spending retains at most six recent reads and prefetches the other view/previous month after a pause. Transactions retains its newest page/day groups. Relevant saves invalidate retained data; late reads must not republish an obsolete generation. Do not make caches unbounded to remove a loading state.
- Charts ignore hover while scrolling and update scrubbing only when the day changes. Amount blur is applied only when hidden; rolling digits do not run every scroll frame. Prefer drawing a chart once and masking it for a switch to rebuilding marks each animation frame. Respect Reduce Motion.
- Measure memory after visiting the affected feature and search, not only at startup. Moving work off the main thread can improve latency while retaining more memory.

## Current exceptions

The Nov 10 speed pass measured launch at 888 ms, Money 120 ms, Spending budget/over time 43/109 ms, Transactions 109 ms, opening search 61 ms and search queries 26–96 ms (five-run medians; full evidence in HISTORY). Those are observations, not replacement caps or a new measurement from this documentation pass.

Idle memory was about 195 MB before search and 202 MB after it: the **200 MB cap is already missed after search**, with little headroom before it. Keep that debt visible and do not grow it. Recent Spending month steps also had intermittent roughly one-second main-thread pauses present in both compared builds; the existing animation does not explain away those stalls. Neither is claimed fixed by the documentation refresh. New work touching these paths must compare against the current build, disclose the existing miss and fix any additional regression; accepting a new tradeoff needs the maintainer.
