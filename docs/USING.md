# Using Compass

What each screen does, where the data comes from, and how to install a Release build for everyday use. What each number means is in the app: Settings > How it works, or ⓘ on any screen.

The Workbench frame keeps a floating sidebar and top bar around the main canvas screens. Review comes first, Notes sits under Context, and the bottom Settings row opens Settings. ⌃⌘S folds the sidebar; ⌘K searches across Compass.

## The screens

### Money

- **Review** holds new transactions and this month’s transfers to unseen accounts. Open a row for its full description, current category evidence and budget treatment. Confirm new transactions individually or from the top bar, and file or keep transfers from their rows. Click a row or tab to the list: ↑↓ moves, Space selects a categorized new transaction, Return opens/closes details and Esc closes them. Confirmation and transfer decisions wait five seconds with Undo before saving.
- **Overview** (Money) puts net worth beside Asset allocation when wide, then Accounts, then three tiles: Flexible left, Goals and Waiting on you. Total, By class and Monthly (⌘1–⌘3) share a top-bar range picker. The chart has reached-goal labels and a nearby unreached net worth target; the figure's tooltip holds the year-to-date change and amount outside retirement. The allocation donut labels positive class shares; what's owed is in Accounts' Debt row.
- **Accounts** sit in one card under the overview. Expand a class row to see its accounts and history; each row shows its share, balance and one-month change excluding opening balances. Debt reads as what's owed, a positive amount. Account history, manual balances, pins, editing, archiving, exclusion and merging remain available. Synced accounts are stale after 7 days and manual ones after 45.
- **Spending** has month navigation and Budget/Over time in the top bar; Edit budget, Fill in from history and Categories are in ⋯. It remembers its last view, in the Monarch flex style. Fixed bills each have an expected amount and show as paid or due. Everything flexible shares one monthly budget, and the page leads with how much of it is left for the month, beside a pace meter. The month's transactions sit under the budget, collapsed until you open them. Over time shows twelve months, and hovering a month shows its breakdown and charges. A starting budget can be built from your history.
- **Transactions** lists every transaction grouped by day, with search (⌘F, Esc), category and month filters, and refiling from any row. Choosing a merchant opens its details in the right panel (above the list in a narrow window), with notes, splits, one-off marks, reimbursement and goal funding. The summary shows a chosen month's income, spending and categories, with six months of bars ending this month or the filtered month, independent of how far you've scrolled.
- **Goals** keeps its list beside the selected goal in wide windows, and opens a goal as a page in narrow ones. New goal is in the top bar. Goals cover net worth, a group of accounts, or financial independence (yearly spending × a multiplier). The list puts the goals that need a look first. Each row names what it measures and shows a status in words, a progress bar (with a tick at a range's minimum), what it needs a month, the pace it is actually keeping and when it gets there. Click a goal for its own page: a history chart with the target line and a dashed projection, its figures, the goals it followed and its reward. Reaching a goal fills its bar, can unlock a reward you set, and suggests a next goal; reached goals then move to Reached.

### Life

- **Overview** (Life) keeps the quarter clock and Calendar's seven day tiles first, then two-week habit strips beside To do with Admin, This quarter with Coming up, and the Vision with yearly bets and Living List. Reminders can be ticked here; New habit is in the top bar. Weeks run Sunday–Saturday.
- **Habits** shows today's tally, the shared day grid and each habit's streaks and history. Life's habit rows hold check-ins, earlier days and reminder links.
- **Playbook** is a searchable list of Today, My sizes and entries grouped by area, beside the chosen item's details when wide. Picks, routines, repeats and notes retain their editors and actions; due/restock hints stay, while the old purchase-history block is gone. **Notes** keeps full notes grouped by topic. Their Add buttons are in the top bar (⌘N).

### Settings

Settings opens in the main canvas from the sidebar Settings row or ⌘,. The top bar's ⓘ opens How it works for the current screen. All six sections share a native selector, which becomes a menu in narrow windows.

- **Profile:** your name and avatar.
- **Appearance:** Workbench in light, dark or matching the Mac; heading/text fonts, text size, accent colour, the app icon's mark and colour, and the menu bar panel.
- **Pay:** salary, paydays, payroll contributions, bonuses and vests.
- **How it works:** the meaning of each screen's numbers.
- **Security:** three lock modes, Hide Amounts (⌘⇧H), Claude access, and the change log with undo.
- **Data:** connect or disconnect SimpleFIN, import Monarch history, choose which Reminders lists and calendars show, name the Reminders lists Compass uses, and back up everything.

## Where the data comes from

- **SimpleFIN Bridge** syncs balances and posted transactions from your banks. Compass syncs on its own at most once a day when you unlock it, and **Sync Now** in the money screens' ⋯ menu syncs right away. The Bridge refreshes from banks about once a day and allows 24 requests a day, so Compass stays far below that. Problems the Bridge reports (a bank needing you to sign in again, say) show on the Money overview.
- **Monarch exports** bring in history: the balances CSV and the transactions CSV from Monarch's export. Re-importing the same file adds nothing.
- **By hand:** manual accounts and balances, for anything SimpleFIN can't reach.

### How transactions get their categories

1. Imported Monarch transactions keep Monarch's category.
2. Compass learns one rule per merchant, separately for money out and money in. Your lunches at a store and a paycheck from the same company never share a category. A merchant's rule is the category it was filed under most often. Capitals, punctuation and store numbers are ignored, so "TRADER JOE'S #552" and "Trader Joes 118" are the same merchant.
3. New synced transactions from a merchant with a rule are filed by it.
4. When the same purchase arrives from Monarch and from SimpleFIN, one copy is kept.
5. Money out of one of your accounts and the same amount into another within three business days is filed as a Transfer, so it counts as neither spending nor income. Bank wording that reads like a transfer to an account Compass can't see ("AUTOPAY", "ONLINE TRANSFER TO SAV") is only suggested, and you confirm each one.
6. Anything left shows "Choose a category" in amber. Filing one by hand sets that merchant's rule, and Compass offers to move the merchant's other charges along.

Category kinds (spending, income or transfer) are guessed from the name and can be changed. "Paychecks", "Salary" and "Interest" are income. "Credit Card Payment", "Brokerage" and "Savings" are transfers.

## Privacy and security

- The data lives in a SwiftData store inside the app's sandbox container. The SimpleFIN access URL lives in the Keychain.
- Lock modes are Off, When it opens (default), and After sleep or idle; modes that lock also lock when the main window closes. Unlock with Touch ID or your Mac password. Hide Amounts works independently.
- The app is sandboxed, with network client access, a keyed localhost MCP server, EventKit permissions and access to files you pick, plus the Dock preferences domain. Bank sync and optional logo fetching make network requests; logos use website domains. Claude access is separately enabled and can read data independently of the window lock.
- Daily local JSON backups keep two weeks; Back Up Now also writes CSVs. A store guard refuses unknown models/fields. There is no in-app restore yet; FileVault supplies disk encryption when enabled; Security warns if it is off.

## Install a Release build

The everyday copy is a Release build installed in Applications. It uses your real data store and none of the debug options. Sign it with your own team first (`Config/Local.xcconfig`, see [DEVELOPING.md](DEVELOPING.md)), so the Keychain grant survives reinstalls. The first step draws the bundled icon from the mark and accent chosen in Settings, so the Dock keeps them after Compass quits; commit the icon PNGs if they changed:

```bash
mkdir -p build &&
xcrun swiftc App/Design/IconArt.swift App/Design/Theme.swift scripts/export-icon/main.swift -o build/export-icon &&
build/export-icon App/Assets.xcassets/AppIcon.appiconset com.seanjaymanuel.Compass &&
xcodegen &&
xcodebuild -project Compass.xcodeproj -scheme Compass -configuration Release -allowProvisioningUpdates -derivedDataPath build/release.noindex build &&
osascript -e 'if application "/Applications/Compass.app" is running then tell application "/Applications/Compass.app" to quit' &&
(
  for attempt in {1..50}; do
    if ! pgrep -f '^/Applications/Compass[.]app/Contents/MacOS/Compass( |$)' >/dev/null; then exit 0; fi
    sleep 0.2
  done
  echo "Compass is still closing; try the install again." >&2
  exit 1
) &&
ditto build/release.noindex/Build/Products/Release/Compass.app /Applications/Compass.app &&
touch /Applications/Compass.app &&
killall Dock &&
open -g -a /Applications/Compass.app --args --background
```

The command quits the installed copy and waits up to ten seconds for it to exit before replacing it, then reopens that exact path in the background (for Claude access). Open its window normally when needed. Never relaunch by bundle ID: LaunchServices can choose a different copy.

- `ditto` copies into the existing app without changing the bundle's date, and the Dock keys its cached icon on that date. `touch` and a Dock restart make the new icon show.
- The build is staged in `build/release.noindex` so Spotlight doesn't list a second Compass.
- Builds are ad hoc signed by default. To sign with your own team, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (gitignored) and fill in your team ID; a stable team signature keeps the Keychain grant to read the SimpleFIN access across rebuilds.
