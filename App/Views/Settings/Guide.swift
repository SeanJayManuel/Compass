/// How each part of Compass works, in plain words with the formula where
/// there is one: read in Settings > How it works, and opened at the screen
/// you're on by the toolbar's ⓘ. Written from the logic in `Core`, so a
/// change there that alters what a number means changes its line here too.
enum GuideTopic: String, CaseIterable, Identifiable {
    case life, habits, playbook, money, spending, transactions, goals, pay, notes, sync

    static let key = "guide.topic"

    var id: Self { self }

    var title: String {
        switch self {
        case .life: "Life overview"
        case .habits: "Habits"
        case .playbook: "Playbook"
        case .money: "Net worth and accounts"
        case .spending: "Spending and the budget"
        case .transactions: "Transactions"
        case .goals: "Goals"
        case .pay: "Pay"
        case .notes: "Notes"
        case .sync: "Sync and your data"
        }
    }

    /// The part of the guide a screen opens.
    init(_ screen: Screen) {
        switch screen {
        case .life: self = .life
        case .habits: self = .habits
        case .playbook: self = .playbook
        case .money: self = .money
        case .spending, .review: self = .spending
        case .transactions: self = .transactions
        case .goals: self = .goals
        case .notes: self = .notes
        case .settings: self = .sync
        }
    }

    var entries: [GuideEntry] {
        switch self {
        case .life:
            [
                GuideEntry(
                    "This week",
                    "Your Calendar's week as seven day tiles, Sunday to Saturday, with event chips in each calendar's colour. All-day events come first; click an event to open Calendar. Hidden calendars stay out, and the band is hidden when Calendar access is denied."
                ),
                GuideEntry(
                    "To do",
                    "From Reminders: anything due by the end of this week (overdue first) and the This Week list, then admin, then any daily repeat still to do today that no habit stands in for. Lists you leave out, shopping lists to start with, never show. Ticking one here ticks it in Reminders. The list names are the standard ones unless Settings › Data names yours."
                ),
                GuideEntry(
                    "This quarter",
                    "Your This Quarter list from Reminders. A reminder can follow net worth or a money goal toward a target, with an optional reward unlocked at 100%. The bar doesn't tick off or reopen the reminder: you choose when it's done. Coming up holds the Long Term or Coming Up list's other deadlines.",
                    formula: "Linked progress = current value ÷ target, between 0% and 100%"),
                GuideEntry(
                    "Menu bar",
                    "The menu bar icon opens Today: reminders overdue or due today from every list you show, by when, with how many more are due later this week; this month's flexible amount left, as on Money; and your habits. It shows nothing while Compass is locked. Closing the window keeps Compass running for the icon and locks it in either mode that locks."
                ),
                GuideEntry(
                    "Vision and bets",
                    "Your vision in your own words, then this year's bets as separate lines, edited here and kept per year. The Living List underneath comes from Reminders."
                )
            ]
        case .habits:
            [
                GuideEntry(
                    "What a habit is",
                    "Something done a number of times a week, like working out 4 times. Weeks run Sunday to Saturday, and a day counts once, however many times you tick it."
                ),
                GuideEntry(
                    "How a week goes",
                    "Hit when it reaches the target, missed when it ends short. This week isn't over, so it's neither yet. The week you add a habit counts as hit if you reached the full target anyway, and otherwise doesn't count at all, so starting midweek is never a miss."
                ),
                GuideEntry(
                    "Left this week",
                    "What you still need, and the days you have left to do it, today included.",
                    formula: "Needed = target − days ticked this week"),
                GuideEntry(
                    "Streaks",
                    "Weeks in a row counts back from the last finished week, or from this week once it's hit. Days in a row counts up to today, or up to yesterday while today is still open, so the morning never breaks a streak.",
                    formula: "Week streak = hit weeks in a row"),
                GuideEntry(
                    "Last 30 days and the quarter",
                    "Days before a habit started don't count, and today counts only once it's done.",
                    formula: "Last 30 days = days done ÷ days that count\nQuarter = weeks hit ÷ weeks so far"),
                GuideEntry(
                    "The day grid",
                    "Each square is one day across all your habits: the darker it is, the more of them you did.",
                    formula: "Shade = habits done that day ÷ habits tracked then"),
                GuideEntry(
                    "Linked to Reminders",
                    "A habit can link to a daily repeat in Reminders. Ticking today in Compass ticks the reminder, and ticks you make on your phone are carried back. Every daily repeat gets a habit, 7 times a week; archive the habit to stop tracking it. You can tick any day back to the Sunday of the week a habit started."
                )
            ]
        case .playbook:
            [
                GuideEntry(
                    "What goes in it",
                    "Things that work for you, so you don't figure them out twice: something you buy (what exactly, and where from), a routine with steps, or just a note. The list shows Today, your sizes (with a note for brand exceptions), then each area's entries; choose one to see it in full. Each entry's line says its size or how often it repeats, or that it's due or time to restock."
                ),
                GuideEntry(
                    "Routines",
                    "A routine's steps happen every day or on the weekdays you pick. A step that isn't today shows when it's next."),
                GuideEntry(
                    "Repeats",
                    "Something done every so often, like cutting nails. It's due its interval after you last did it, or today if you never have. Each repeat can be a reminder in Reminders.",
                    formula: "Next due = last done + interval"),
                GuideEntry(
                    "Today",
                    "Every routine that doesn't repeat, plus each repeat due within 2 days, overdue first. A repeating routine shows when it's due. A routine with nothing today previews its next session by name, else how many steps it holds (\"7 steps tomorrow\")."
                )
            ]
        case .money:
            [
                GuideEntry(
                    "Net worth",
                    "Debts are stored as negative balances, so net worth is a plain sum. Each account's last balance carries forward until a newer one arrives.",
                    formula: "Net worth = every counted account's balance, added up"),
                GuideEntry(
                    "Investable",
                    "Everything except retirement accounts.",
                    formula: "Investable = net worth − retirement accounts"),
                GuideEntry(
                    "Opening balances",
                    "An account's first balance when it's linked was already yours, so it isn't growth. Changes, monthly figures and goal pace leave it out, unless the money came from one of your other accounts.",
                    formula: "Change = end − start − opening balances added between"),
                GuideEntry(
                    "Asset allocation",
                    "Each positive account-class total as a share of all positive class totals counted in net worth. Negative totals stay outside the donut; what you owe is under Debt in Accounts."
                ),
                GuideEntry(
                    "Account class changes",
                    "The 1M figure compares the class with one month ago, leaving out opening balances. Debt shows the change in what you owe, so a decrease is good news. Expand a class for its accounts and history."
                ),
                GuideEntry(
                    "Debts",
                    "On their own, a debt account and the debt class show what you owe as a positive number, so a falling line is good news. Below zero means a card is overpaid."
                ),
                GuideEntry(
                    "Investing: contributions and market",
                    "Each investing account's month splits into money you put in or took out, and what the market did with the rest (growth, dividends, fees). When Compass can't tell your deposits from trades, contributions are unknown, not zero. Accounts your pay goes into take contributions from your paychecks.",
                    formula: "Market change = balance change − contributions"),
                GuideEntry(
                    "Stale balances",
                    "A synced account's balance is stale after 7 days, a manual one's after 45. A banner shows when no sync has worked for more than a week."),
                GuideEntry(
                    "Archived accounts",
                    "An archived account stops counting the day after its last balance, so a closed account doesn't linger in net worth.")
            ]
        case .spending:
            [
                GuideEntry(
                    "Review",
                    "Open a row for its full bank description, a check against current category rules, and how it counts in that month’s budget. The original reason was not saved; pending guesses do not teach their own explanation. Confirming keeps the existing treatment rather than adding spending again. Click a row or tab to the list: ↑↓ moves, Space selects a categorized new transaction, Return toggles details and Esc closes them. Confirm selected or all from the top bar; confirmation and transfer decisions wait five seconds with Undo."
                ),
                GuideEntry(
                    "Budget controls",
                    "Choose the month and Budget or Over time at the top. The ⋯ menu holds Edit budget, Fill in from my history and Categories, alongside account, import and sync actions. Amounts can still be planned in their budget rows."
                ),
                GuideEntry(
                    "Kinds of category",
                    "Fixed bills come every month at an expected amount. Flexible categories share one flexible budget. Irregular ones come when they come (an annual fee, charity): they're out of the flexible pace and shown apart. Income and transfer categories aren't spending at all."
                ),
                GuideEntry(
                    "What counts as spending",
                    "Money out, net of refunds and of what you're owed back (reimbursable), less anything a goal paid for.",
                    formula: "Spending = money out − refunds − owed back − paid from goals"),
                GuideEntry(
                    "The headline",
                    "Only the flexible budget, since that's the part you steer day to day.",
                    formula: "Left = flexible budget − flexible spent"),
                GuideEntry(
                    "Even pace",
                    "The tick on the bar is where flexible spending would be today if it were spread evenly over the month. Past the tick reads as faster than an even pace; past the budget, over budget.",
                    formula: "Even pace = flexible budget × day of month ÷ days in month"),
                GuideEntry(
                    "A day",
                    "The daily allowance in Claude's budget answer, not a figure on Spending: what you can spend each remaining day and still end on budget, rounded down to the dollar.",
                    formula: "A day = left ÷ days left, today included"),
                GuideEntry(
                    "Income, Expenses, Left over",
                    "Each shows this month so far against the plan. Left over goes negative early in a month when bills come out before payday. Money in with no category yet isn't income until you file it.",
                    formula: "Expenses = fixed + flexible + irregular\nLeft over = income − expenses − savings"),
                GuideEntry(
                    "Every dollar is planned",
                    "Zero-based budgeting: every planned dollar of income goes to a bill, the flexible budget or savings. Spending says nothing when every dollar is planned; above zero it says what's left to budget, below zero how far the plan is past your income.",
                    formula: "Left to budget = planned income − planned expenses − planned savings"),
                GuideEntry(
                    "The budget by month",
                    "A change applies to this month only, or to this month and every one after. Whether a category is fixed or flexible is the same in every month."
                ),
                GuideEntry(
                    "A first budget",
                    "A category paid a steady amount (within 10% of its usual) in recent months starts as a fixed bill at its average. The flexible budget starts at the last three months of flexible spending, averaged."
                ),
                GuideEntry(
                    "Over time",
                    "Each category's month against its average over the six full months before. More than 20% over is worth a second look.")
            ]
        case .transactions:
            [
                GuideEntry(
                    "Money in and out",
                    "The summary shows a month at a time: this month unless you filter to another, with the five months before it as bars (money in green, money out red). Click a month's bars to see its figures and where its money went. It counts the transactions matching your search and filters, even before you've scrolled to them. Money in is filed income. Money out is net of refunds and what's owed back, including spending paid from goals. Transfers stay out; an unfiled deposit isn't income yet."
                ),
                GuideEntry(
                    "Transaction details",
                    "Click a merchant to open its details beside the list, or above it in a narrow window. Notes, one-off marks, what's owed back and goal funding save when you leave the details."
                ),
                GuideEntry(
                    "Transfers",
                    "Moving money between your own accounts (a card payment, savings, funding the brokerage) is neither spending nor income. Money out of one account and exactly the same amount into another within 3 business days pairs up and is filed under Transfer."
                ),
                GuideEntry(
                    "One-sided transfers",
                    "An uncategorized charge worded like a move between accounts (\"AUTOPAY\", \"PAYMENT THANK YOU\") with no partner Compass can see is only a suggestion, and you confirm it. Payments to people (Zelle, Venmo, PayPal, Cash App) are spending."
                ),
                GuideEntry(
                    "Categories",
                    "A merchant rule files that merchant's transactions in one category. Without one, Compass guesses from the merchant and the category's name. New transactions wait in Review for you to confirm."
                ),
                GuideEntry(
                    "Flags and splits",
                    "One-off marks a charge that isn't usual (a flight home, a new laptop): it still counts as spending, and you can search for it. Reimbursable means it's owed back, so it isn't counted as spending. A split puts parts of one charge in different categories."
                ),
                GuideEntry(
                    "Duplicates",
                    "An import or sync skips transactions already here, so bringing in the same history twice adds nothing.")
            ]
        case .goals:
            [
                GuideEntry(
                    "Opening a goal",
                    "In a wide window, the list stays beside the chosen goal's details. In a narrow window, a goal opens as a page; Goals, Esc or ⌘[ returns to the list. New goal is always at the top."
                ),
                GuideEntry(
                    "Kinds of goal",
                    "Net worth, the total of chosen accounts, or FIRE: investable assets against a year's spending times a multiplier, usually 25.",
                    formula: "FIRE target = annual spending × 25"),
                GuideEntry(
                    "Pace",
                    "The average monthly gain over the last three months, leaving out opening balances. A goal over investing accounts only uses what you put in instead, with the market shown apart.",
                    formula: "Pace = gain over 3 months ÷ 3"),
                GuideEntry(
                    "On track",
                    "A goal with a date is on track when its pace covers what each month must add. Without a date there's nothing to measure against, so it's growing or not growing.",
                    formula: "Needed a month = (target − now) ÷ months left"),
                GuideEntry(
                    "Projected date",
                    "When the goal would be reached at today's pace. Not shown when it's further out than 100 years.",
                    formula: "Projected = today + (target − now) ÷ pace"),
                GuideEntry(
                    "Order",
                    "Goals behind their date come first, then not growing, then on track by nearest date, then undated by nearest projection."),
                GuideEntry(
                    "Never deleted",
                    "A goal is achieved or retired with a reason, and stays in history. A reward is spending, never an asset.")
            ]
        case .pay:
            [
                GuideEntry(
                    "Paychecks",
                    "Set your salary, how often you're paid and one payday, and each paycheck is worked out from them: paydays count on from the one you gave. Synced deposits say what actually arrived. A paystub can fill the settings in."
                ),
                GuideEntry(
                    "401(k) and stock",
                    "Your 401(k) percent, the employer match (a percent of what you put in, on up to a percent of pay) and the stock plan's company part are counted as saved."
                ),
                GuideEntry(
                    "Savings rate",
                    "How much of what you earned you kept. Beside it, the share of take-home you moved into savings.",
                    formula: "Savings rate = (moved to savings + 401(k) + match + stock) ÷ (salary + match)"),
                GuideEntry(
                    "Bonuses and vests",
                    "Expected separately, kept apart from the monthly budget, and marked as a guess until they're known.")
            ]
        case .notes:
            [
                GuideEntry(
                    "What notes are for",
                    "Your standing rules and the reasons behind them (why you keep a cash buffer, what your career is optimizing for), so Claude knows them in every chat. Grouped by topic: Money, Goals, Career, Life, or your own."
                ),
                GuideEntry(
                    "No figures",
                    "Notes never repeat numbers Compass already has (balances, pay, budget amounts). They say where the figure lives instead, so a note doesn't go stale."
                ),
                GuideEntry(
                    "Claude's changes",
                    "Claude can keep up goals, reminders, habits, the Playbook, notes, the budget and categories, after asking you in the chat. Every change shows in Compass with undo. Synced balances and transactions' amounts are read-only, and nothing moves money."
                )
            ]
        case .sync:
            [
                GuideEntry(
                    "Settings",
                    "Open Settings in the main window with ⌘, or the sidebar's Settings row. The top bar’s ⓘ opens How it works for the screen you were on. Settings stays behind the same lock as every other screen."
                ),
                GuideEntry(
                    "Syncing",
                    "Compass syncs by itself once a day, when it opens or unlocks, and Sync Now works any time. After a failure it waits an hour, and automatic tries stop at 12 a day so the bank connection's daily limit is never reached."
                ),
                GuideEntry(
                    "On this Mac",
                    "Your store and caches live on this Mac, with a daily local backup kept for two weeks. Manual backups and exports go where you choose. SimpleFIN sync and optional merchant logos make network requests. Claude access is separately enabled and lets an authorized client read through the local endpoint even when the window is locked."
                )
            ]
        }
    }
}

/// One idea: what it is in words, and its formula when it has one.
struct GuideEntry: Identifiable {
    let title: String
    let text: String
    let formula: String?

    var id: String { title }

    init(_ title: String, _ text: String, formula: String? = nil) {
        self.title = title
        self.text = text
        self.formula = formula
    }
}
