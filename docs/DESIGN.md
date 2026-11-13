# Compass design guide

How Compass should look, move and read, and how to check a change before it ships. Read it before any UI work, alongside [CLAUDE.md](../CLAUDE.md).

The guide has two layers:

- **Principles** hold whatever the theme is. They come from Apple's interface guidance (the `apple-design` skill) and from distinctive, intentional visual design (the `frontend-design` skill), applied to a personal finance app for one person.
- **The current theme** is the set of choices that can be swapped: the typefaces, the palette, the card style. Changing it is fine. Changing it without going through the checks at the end is not.

## What Compass is for

A calm, private place to see where your money and your year stand. Every screen answers one question quickly. Money asks "where am I?": net worth beside allocation, expandable account classes, then Flexible left, Goals and Waiting on you. Life asks "how is this week and quarter going?": Calendar day tiles, two-week habit strips beside To do/Admin, This quarter/Coming up, then Vision/bets/Living List. Habits asks "am I keeping them up?" with tally, grids and trends. Playbook asks "what works for me?" with a searchable list of Today, sizes and area-grouped entries, then selected details. Spending asks "how much flexible money is left?" and Goals asks "which goal needs a look?".

Review answers “what needs checking?”, Transactions answers “what came in and went out?”, Notes answers “what have I decided?”, and Settings holds the six forms behind the same lock as the rest of the app.

The tone is quiet confidence: plain words, real numbers, nothing shouting.

## Principles

### 1. One thing leads each screen

- Each screen has one figure or one answer that's clearly the most important thing on it. Examples are the net worth total and the flexible amount left. Everything else is quieter.
- Hierarchy comes from size, weight and position, not from colour or decoration.
- Spend boldness in one place. If two things compete for attention, make one of them quieter.

### 2. Structure carries information

- A border, a card, a divider, a swatch or a number marker must mean something. A card groups related content. A swatch identifies a series or class. Numbers mark a real sequence.
- Use the same mark for the same thing everywhere. An account class has one colour, shared by the allocation donut and legend, its round row mark and share bar, and its history chart.
- Don't add a decorative strip, gradient wash, eyebrow label or icon that tells you nothing.

### 3. Colour has jobs, and decoration isn't one of them

- **The accent** marks what's selected or interactive (a sidebar icon, a link, a primary control). Net worth and goal chart lines use ink; selected ranges use a grey ink tint. It's never decoration, so banners are plain cards (`.banner()`) and their buttons carry them. Text buttons take `.linkButton()`, which underlines them when the accent is within 2:1 of the ink (the Graphite accent), since colour alone can't mark them there. It never encodes data: progress is ink, done (habit days) and gains are green, losses red, and something waiting on you (the Review count) amber.
- **Status colours** (green, amber, red) mean on pace, needs a look, and failed or over; green and red also mean money in or a gain, and money out or a loss (Transactions' bars, monthly net worth changes), with a second cue (hollow, a label) so they never rely on colour alone. The accent never means gain or loss. Series palettes stay visibly apart from them.
- **Series colours** (account classes, spending categories) are checked for colourblind safety. A chart also tells series apart by position, shape or label, not by colour alone.
- Every colour works in light and dark mode. Text meets 4.5:1 contrast on the canvas and on cards in both.

### 4. Words are part of the design

- Write in plain sentence case, the way you'd say it out loud: "$420 left of $1,500 flexible for October", "Transfers only", "Not started".
- Name things by what they mean to you, not by how the code works.
- A button says what it does, and the result uses the same word. "Add $150K net worth" leads to that goal being added.
- An empty state says what to do next. An error says what happened and how to fix it, and never apologises or stays vague.
- Avoid all-caps labels and labels stacked above headings. Don't accent a single word in a heading.

### 5. Respond instantly, move only with purpose

Read [PERFORMANCE.md](PERFORMANCE.md) before adding interactions or motion. Its latency/memory caps and matched before/after runs are part of design acceptance. Keep data work off the main thread, avoid whole-history reads in views, and check cache freshness after edits. Fast reads on Spending/Transactions must not flash loading; their indicator waits 300 ms. Intentional animation is not permission for a main-thread stall.

- Motion answers something you did (opening, expanding, confirming) or a data change. Nothing moves on its own to get attention.
- Every animation goes through `Motion.change`: a critically damped spring with no bounce. Bounce is only for momentum, and Compass has no flick gestures.
- One exception: a chart coming in after a switch uses `Motion.switchIn` (0.4 s, linear) to uncover its plot column by column from the left (Spending's `GrowMask`), so everything stops together. The chart is drawn once and masked; animating its marks rebuilt the whole chart every frame. Only the headline total rolls (`numericText`, on `Motion.change`: a linear roll stalled the main thread), never a list of figures.
- Each frame of any animation costs a screen about 10 ms of main-thread work, whatever moves, so keep motion short and rare.
- A section that remembers whether it's open uses `@Remembered`, not `@AppStorage`: a change to `@AppStorage` skips `withAnimation`, so the section pops instead of sliding.
- Animations can be interrupted. A section you click twice reverses smoothly.
- There's one quiet celebration: a newly reached goal's bar fills once. Don't add confetti or a second celebration.

### 6. Accessible by default

- **Reduce Motion:** `Motion.change` turns into a short ease, and any new animation must check `Motion.reduced`.
- **Increase Contrast:** card edges use `Hairline`, which gets firmer. New borders use it too.
- **Text size:** every size, fixed frame and chart height scales with `TextSize.current.scale`. Layouts reflow at Larger text and never clip.
- **VoiceOver:**
  - Every control and every figure cell has a label that makes sense on its own ("Done: Run a 10K", not just "Done").
  - Decorative swatches are hidden from VoiceOver.
- **Hide Amounts:** every dollar figure gets `.privateAmount()`, including ones inside charts and tooltips.

### 7. It's a Mac app

- One prominent (`.borderedProminent`) button per screen at most, for what you do most there: Confirm All on Review, Add on a next-goal suggestion. The rest are plain.
- The top bar owns global search (⌘K, `TopBarSearch` → `QuickSearchPanel`). Transactions and Playbook also keep local `SearchField` filters; local search never replaces global search.
- Use native controls (menus, pickers, toggles, sheets) before custom ones, and follow macOS habits: ⌘ shortcuts, Esc to back out, right-click menus that match the visible `…` menu. The sidebar, top bar and shared rows follow the approved Workbench frame; menus, pickers, sheets and shortcuts remain native.
- Buttons on screen never end in "…" (it reads as unfinished): "Categories", "Edit budget", "Review". Right-click menu items keep the macOS "…" for one that opens a window.
- Content sits in a centred column (`Spacing.column`, 960 pt scaled). Goals and Transactions use two columns when their canvas reaches 940 pt scaled; narrow windows return to their list/page or inline flow.
- Layouts adapt to the window, not the device. Below `Spacing.compactBelow` rows switch to `RowDensity.compact` and stack. Rows of controls use `ViewThatFits` to wrap as a whole and never break letter by letter.

### 8. Craft and restraint

- Every spacing value comes from the 8 pt grid in `Spacing`.
- Lines between rows are `Rule`, never a fixed 0.5 pt: external displays often run at 1x, where half a point rounds to a full pixel or to nothing, so lines vanish at random. Lines at fractional positions snap to whole pixels first.
- Line things up: figures right-aligned with `.monospacedDigit()`, labels on a shared leading edge.
- Before finishing, take one thing away. If a change adds an element, ask what it replaces.
- Fix the cause, not the symptom. If Swift Charts misplaces something, attach the label to the mark itself rather than nudging offsets.

## The Workbench frame

`AppFrame` owns navigation, the screen name, global search and screen actions. The sidebar puts Review first, then Life and Money, with Notes under Context and a Settings row (sliders icon) at the bottom. The window's close, minimize and zoom buttons sit inside the panel's top, level with the top bar (`WindowButtonPlacement`); folded, the panel stays at least 78 pt wide to hold them. ⌃⌘S folds the sidebar; below 920 pt scaled it folds automatically. The 52 pt scaled top bar and the sidebar's upper space drag the window, which has no title bar.

Keep the range on Money, month/view on Spending, New goal on Goals, New habit on Life, and Add on Playbook/Notes in the top bar. Spending's Edit budget, Fill in from history and Categories share ⋯ with the money actions. At narrow widths search becomes an icon on every screen; money actions are grouped in ⋯ at all widths. Local filters, card headings and figures stay in the canvas. Screens do not repeat their screen title. Review's selected/all confirmation sits in the top bar; its waiting count and keyboard hint stay above the queue.

Settings is a canvas screen, reached through the sidebar's Settings row, the ⌘, shortcut or ⓘ. Its native segmented selector becomes a menu when it does not fit. The menu bar panel and lock screen remain separate surfaces using the same tokens.

## The current theme (swappable)

Everything here lives in `App/Design/`. Views never hard-code a colour, font or spacing value. That's what makes the theme swappable.

| Part | Today | Where |
| --- | --- | --- |
| Display type | Geist by default, for titles, the hero figure, card figures and headings | `Typeface.title`, `hero`, `figure`, `heading` |
| Text type | Geist by default for body, detail, section titles, captions and axes; figures use the selected face’s monospaced digits, with no separate Geist Mono font | `Typeface.body`, `detail`, `section`, `caption`, `axis` |
| Typefaces | Chosen in Settings: headings (Geist, New York, Spectral, Geist Serif, Charter, Iowan Old Style, Palatino, SF Pro) and text (Geist, SF Pro, Public Sans, Avenir Next, Seravek, Helvetica Neue). Every face has lining figures. Geist (Vercel's, the default for both), Spectral and Public Sans (seanjaymanuel.com's) and Geist Serif are bundled in `App/Fonts` under the OFL | `DisplayFace`, `TextFace` |
| Color theme | One palette, Workbench (Nov 9, 2026, after Vult): near-neutral greys, white cards on light grey, near-black in dark mode, a blue accent. Light, dark or matching the Mac is the Appearance setting. Sets canvas, cards, ink, rules and the sidebar fill | `ColorTheme` in `Theme.swift`; `Palette.canvas`, `surface`, `ink`, `inkSecondary`, `rule`, `sidebar` |
| Surfaces | Raised cards, 12 pt corners (`Radius.card`; controls 8), with a one-pixel hairline edge | `.card()`, `Hairline`, `Radius` |
| Row marks | A round mark leads transaction, account, habit, Playbook and note rows: a merchant's logo edge to edge (its tile becomes the circle) when Compass has one (logo.dev with a key, else Google's icon), otherwise initials on a quiet tint; an account's institution in its class colour (the same as its swatch); a habit's icon from its name (`HabitIcon`). Reminders have none. Habit marks sit with the title so weekday controls keep the full card width. Decorative, so VoiceOver skips it | `RowMark`, `MerchantLogos`, `HabitIcon` |
| Frame | A floating sidebar panel (216 pt; folded to icons, 64 pt scaled and at least 78 pt; 12 pt corners, hairline edge; the selected row a quiet ink tint with its icon in the accent) and a 52 pt top bar: section / screen, then search (⌘K), the screen's own controls (Money's range as a strip of segments, a menu when narrow), and one ⋯ menu with add account, import, sync and How this works. No title bar. Below 920 pt (scaled) the sidebar folds itself, search becomes an icon and every money screen groups add account, import and sync in one menu | `AppFrame`, `TopBarButton`, `Palette.selection`, `hover` |
| Review | New transactions and this month’s one-sided transfers, expandable current-category/budget details, a visible active row, ↑↓/Space/Return/Esc, top-bar confirmation, five-second Undo and Decided. Money colors match Transactions; saving errors stay visible | `ReviewView`, `ReviewDetails`, `CategoryGuess`, `PendingDecisions` |
| Money overview | Card for card as the draft (Nov 10, 2026), 16 pt card padding: net worth ("Net worth" with a small Total/By class/Monthly menu, the figure, this month's change; assets and owed at the right; the year so far and outside-retirement in the figure's tooltip; 200 pt chart, with the nearest unreached net worth goal as a dashed line when it's near the line) with Asset allocation beside it; Accounts with one line per class (swatch, name · count, share bar, share, change this month, balance), opening to the class's history and accounts, and a staleness line only when something needs an update; then three tiles: Flexible left, Goals (how many on pace, the first that needs a look), Waiting on you (Review). Stacked below 900 pt scaled | `MoneyOverview`, `AssetAllocation`, `AccountsBreakdown` |
| Transactions | Day groups with quiet money colors; summary/details panel on the right at wide widths, inline details and expandable summary at narrow widths. The summary shows six months of bars (money in green, money out red) ending with this month or the filtered one, chosen and the others dimmed; figures and where it went are for the chosen month. With no filter it reads only those months, so it doesn't wait for the whole history | `TransactionsView`, `TransactionPanels` |
| Spending and Goals | Spending leads with its flexible figure and budget cards; the month and Budget / Over time are in the top bar, and Edit budget, Fill in from history and Categories are in its ⋯ menu. Goals has a 312 pt list beside its details at wide widths; narrow windows keep the list/page flow. New goal is in the top bar. | `SpendingView`, `GoalsView`, `TopBarActions` |
| Life and Context | Life follows the draft (Nov 10, 2026): This week as seven day tiles with event chips (today outlined), Habits (14 days as squares, a check for today) beside To do (with Admin), This quarter (with Coming up), then the Vision with bets and the living list; the Playbook's today is on the Playbook only; Habits keeps its tally and grids. The Playbook is a list and its details, as Goals: a 312 pt list (search, Today, My sizes, then entries by area with an area icon and status) beside the chosen item at wide widths, list then details with a back link when narrow. New habit and Playbook/Notes Add are in the top bar; Notes keeps its native topic picker | `LifeOverview`, `HabitsView`, `PlaybookView`, `NotesView` |
| Settings | All six forms live in the main canvas, under a native segmented selector that becomes a menu when narrow. The sidebar's Settings row, ⌘, and ⓘ route here through the main window's lock gate. Grouped form backgrounds blend with the canvas | `SettingsView`, `SettingsCommands`, `SettingsPane` |
| Accent | Workbench's blue by default (Default); eight presets or a custom colour override it | `Palette.needle`, `needleText`, `onNeedle`, `Theme.swift` |
| App icon | One of four paper marks (Convergence, the default; Keystone; Fold; Focus) on a rounded square (Fold shaded, the rest flat), in its own color or the accent's | `AppMark`, `IconArt`, `IconColor` |
| Status | Green, amber, red | `Palette.onPace`, `attention`, `failure` |
| Series | The draft's softer blue, peach, mint, lilac and pink for cash, taxable, retirement, equity and other, and the same five for categories; debt stays olive, not red: owing isn't a failure. Validated with the dataviz checks in on-screen order on cards and canvas in both modes. Selected pills and segments (Total, ranges) are a grey ink tint, not the accent | `Palette.accountClass`, `Palette.series` |
| Meters | Thin capsules in ink (`Palette.progress`, on `progressTrack`), never the accent, so a gray accent never makes progress look off; amber or red only for a problem, green for a reached goal; ticks (an even pace, a minimum) in ink edged in the card's colour, so they show on a fill as dark as the ink. Past its budget, the flexible meter shows everything spent: the budget's share, a gap, then the overspend in red, labeled "$900 budget" where the budget ends and "$1,676 spent" at the end | `MeterBar`, `PaceMeter`, `PaceTick` |
| Category icons | An outline SF Symbol beside each category's name (budget rows, the Categories sheet, the category picker and button), matched to the sidebar's icons. Matched on whole words in the name, so a new or renamed category finds one; anything unmatched gets a tag. Totals have none, and VoiceOver skips them, since the name says the same | `CategoryIcon`, `CategoryGlyph` |
| Spacing | 8 pt grid with 4 pt half-step; 960 pt scaled content column and compact rows below 640 pt scaled | `Spacing` |
| Motion | Critically damped spring, 0.25 s | `Motion` |

### Changing the theme

When the maintainer wants a new typeface, palette or surface style:

1. **Change the tokens, not the views.** If a view needs editing to pick up the new theme, move that value into a token first.
2. **Pick for the subject.** Choose type and colour for a calm, private money app for one person. Avoid the stock looks that any app could have, such as:
   - a dark screen with one neon accent;
   - a newspaper layout with thin rules and sharp corners;
   - generic SaaS cards with soft grey shadows on everything.
3. **Keep the jobs.** A new palette still needs one accent, three status colours kept apart from the series colours, and series checked under common colour-vision deficiencies (with labelled legends as well as colour). A new typeface still needs a clear display, section, body and detail scale. Large type takes slightly negative tracking, and body text takes none.
4. **Recheck contrast.** Text meets 4.5:1 in both modes, including the accent as text and amber as text.
5. **Run the full quality check below**, and show the maintainer the before-and-after renders. The theme is the maintainer's call.

## Quality check before handing over

Every UI change gets this check, along with the tests and builds in CLAUDE.md, scaled to the size of the change. Documentation-only changes need a source/doc review and the required tests/build; unchanged UI uses the preceding render evidence. Render only what the change can affect:

| Change | Render |
| --- | --- |
| **Small**, on one screen: wording, spacing, a colour, an icon, one control | That screen only (`--snapshot-screens`), at 1280 in light and dark. Add 720 and Larger text if it changes a row, a label's length or anything that could wrap |
| **Layout** on one screen: a new section, a reflowed row, a new chart | That screen, the full matrix (1280, 720, Larger text × light and dark) |
| **Across screens**: a shared component, `Tokens`, `Theme`, a redesign, a new screen | Every screen, the full matrix, with before-and-after renders for the maintainer |

When unsure which row a change is, use the bigger one. Steps 2–4 apply at every size; step 2 covers only the renders you made.

### 1. Render the matrix

Build Debug, then render into a new folder so it can be compared with the last one. This is the full matrix; for one screen add `--snapshot-screens money` (or the screen's name: `money`, `spending`, `transactions`, `goals`, `review`, `life`, `habits`, `playbook`, `notes`, `settings`, `menubar`, `lock`) to each line and drop the lines you don't need:

```bash
APP="build/debug.noindex/Build/Products/Debug/Compass Dev.app/Contents/MacOS/Compass Dev"
OUT=/private/tmp/compass-ui-$(date +%Y%m%d-%H%M)
for a in light dark; do
  "$APP" --sandbox --seed-demo --appearance $a --snapshots $OUT --snapshot-size 1280x1000
  "$APP" --sandbox --seed-demo --appearance $a --snapshots $OUT --snapshot-size 720x1000 --snapshot-suffix 720
  "$APP" --sandbox --seed-demo --appearance $a --snapshots $OUT --snapshot-size 900x1100 --snapshot-suffix larger --snapshot-defaults textSize=larger
done
```

A full run writes 18 images per configuration: ten canvas screens, six explicit Settings tabs, menu bar content and the lock screen. Each Settings tab always renders, even with `--snapshot-screens`; `settings` also captures the saved tab. Snapshot defaults affect only that run. Run launches sequentially because they share the demo store.

Cover the states the change affects as well as the initial screen:

| Surface | Additional render state |
| --- | --- |
| Search | `--open-search "co"`; check results and the empty state |
| Money/accounts | `--snapshot-defaults accounts.expanded.cash=true`; verify account actions and histories remain represented |
| Spending | `--snapshot-defaults spending.view=overTime` as well as the default budget |
| Review | `--open-review "Hardware Co"`; include a categorized row, a matched transfer and `--snapshot-defaults review.selectFirst=true` to check both confirmation controls |
| Goals | `--open-goal "Emergency fund"`; check the wide list/detail and narrow page |
| Transactions | `--open-transaction "<demo merchant>"`; include a split charge and `--snapshot-defaults transactions.summary=true` at narrow widths |
| Life, Playbook, Notes, long forms | `--snapshot-size 1280x2400` to inspect content below the initial scroll position |
| Menu bar | `--snapshot-screens menubar --snapshot-defaults textSize=small`, as well as Standard and Larger |
| Settings | All six tab images; use `--snapshot-defaults guide.topic=life` (or the affected topic) for How it works |

If top-bar controls change, also check 720 pt with Larger text. Use only demo names in these commands.

The last design pass's blocking bugs showed only at 720 pt and at Larger text, so don't skip those whenever the matrix is called for.

### 2. Look at every render

Open the images and check each one against this list:

- [ ] Every previous section, figure, filter and action is still represented; compare against the screen’s preservation list in the redesign plan, including content below the fold.
- [ ] One thing leads the screen, and the hierarchy reads at a glance.
- [ ] Nothing clips, overlaps, truncates mid-word, or wraps letter by letter.
- [ ] Labels sit next to the thing they label (chart markers, legends, figures).
- [ ] Colour is used only for the jobs above, and the same thing has the same mark everywhere.
- [ ] Light and dark are equally legible, and nothing glows or disappears in dark mode.
- [ ] Figures are aligned and use monospaced digits; reminder dates/times remain complete, and habit weekday controls fit without squeezing the title.
- [ ] The copy is plain, specific, in sentence case, and says what happens.
- [ ] No new decoration that carries no information.

### 3. Check what renders can't show

Snapshots draw unlocked content directly and the lock screen separately. They verify layout, not authentication or working interactions. They also do not show:
- anything at 1x, unless rendered from a low-resolution copy (DEVELOPING), since they draw at the Mac's 2x;
- hover and press states;
- animations;
- Hide Amounts' blur;
- prominent buttons in a key window (they render grey offscreen).

For a change that touches them, read the code against the principles. Then check the relevant interactions in the sandbox, or explicitly leave them for the maintainer in the handoff:

- Frame/search: sidebar folding and arrow keys; ⌘K, results, Return and Esc; screen controls still reachable at the minimum window size.
- Settings/lock: sidebar Settings, ⓘ and the ⌘, shortcut (including while search is open); all tabs; closing/reopening the main window; locked main/menu bar surfaces reveal no private content. Snapshots alone do not prove this.
- Editing: top-bar Add/New commands and existing editors; transaction details saving on selection/navigation; goal selection, milestones and reward photos.
- Review: individual/batch decisions, five-second Undo, saving when leaving or quitting, and visible save errors. Click a row or tab to the list, then test ↑↓, Space on a categorized new row, Return and Esc. Category menus, the sidebar and global search must keep their own keys; top-bar confirmation must reflect the selected rows.
- Live services and accessibility: actual Reminders/Calendar changes, Hide Amounts on figures/charts/details, VoiceOver labels; Reduce Motion and Increase Contrast when motion or borders changed. Check 1x rendering for changed rules or small marks (DEVELOPING).

The open acceptance checks for the redesign are recorded in the redesign plan. Only mark one passed after observing it.

### 4. Review and hand over

- Run the `code-review` skill on the change and fix what it finds.
- Check the feature-work gate in PERFORMANCE.md; record timing/memory evidence or why this was a copy-only change.
- Commit, push and install as CLAUDE.md says.
- Tell the maintainer what changed, what was tested and anything that needs a live check. Keep implementation gaps separate from checks that need a live window.

## Live checks still open

The Workbench redesign (Nov 9–10, 2026) and the earlier finance design pass are implemented; these checks need a live window and haven't been observed yet. Offscreen renders don't prove them, so don't mark one passed from screenshots alone.

- **Frame, search and Settings:** sidebar folding and keyboard navigation; ⌘K results, Return and Esc; the Settings row, ⓘ and ⌘, (also while search is open); every Settings tab; locking when the main window closes and reopens.
- **Review:** decisions, category menus, batch selection, focused ↑↓/Space/Return/Esc, five-second Undo, leaving or quitting with decisions waiting, and visible save errors. The keys must not intercept the sidebar or search.
- **Goals:** a new achievement fills its bar once and stays for the visit; ⌘[ and Esc go back on a narrow page; row and right-click menus work by keyboard; reward photos persist.
- **Spending:** typing planned amounts, month scope, collapsing groups, Budget/Over time, stepping months, hover breakdowns and charges; fast reads don't flash a loading line.
- **Transactions:** ⌘F, filters, refiling, splits and details saving on navigation; summaries independent of how far you've scrolled.
- **Editing elsewhere:** top-bar New/Add, Spending's ⋯ actions, goal switching and search links, expanded account actions and history, Playbook and Notes editors and deletion.
- **Life and real services:** today's habit check, earlier days and linked reminder completion; Vision and yearly bets persist after relaunch; Reminders and Calendar changes.
- **Accessibility:** Hide Amounts on figures, charts and details; VoiceOver; keyboard-only use; Small and Larger text; Reduce Motion; Increase Contrast; a 1x display.

## What needs the maintainer

These are the maintainer's decisions. Propose them; don't ship them on your own:

- a new typeface, palette, canvas or surface style (anything in "The current theme");
- changing a layout decision recorded in DECISIONS.md, such as Spending leading with the amount left, Goals as a list plus a page, or Reminders holding the Life lists;
- removing or merging screens, or changing what a screen leads with.

Polish, accessibility fixes and bugs you can see in a render can be fixed and shipped directly.
