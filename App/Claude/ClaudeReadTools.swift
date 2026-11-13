import Core
import Foundation
import SwiftData

/// The read tools Claude is offered, each with its schema and handler.
extension ClaudeTools {
    // MARK: - The list

    /// The read tools, in the order Claude lists them.
    var readTools: [ClaudeTool] {
        let range =
            [
                "type": "string", "enum": TimeRange.allCases.map(\.rawValue),
                "description": "How far back from today. Default 1Y."
            ] as [String: Any]
        let by =
            [
                "type": "string", "enum": ["day", "week", "month"],
                "description": "day (the chart's line: thinned to about 120 averaged points on long ranges), or each week's or month's last value. Default day."
            ] as [String: Any]
        let month = ["type": "string", "description": "YYYY-MM. Default this month (month to date)."]
        func text(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
        return [
            tool(
                "overview",
                "The Money overview: net worth with its change since a month ago and since Jan 1 (opening balances of accounts linked since left out), which accounts are out of date, this month's flexible spending against the budget, the goals that need a look first, where the assets sit, and (once their pay is set up) the savings rate over the last 12 months and the year so far, and bonuses and vests they expect, which aren't part of the monthly budget.",
                run: { _ in try self.overview() }),
            tool(
                "net_worth",
                "Today's net worth: the total, the part outside retirement accounts, each account class, and the change over 3M, 6M, YTD, 1Y and 5Y (opening balances of accounts linked since left out).",
                run: { _ in self.netWorthNow() }),
            tool(
                "net_worth_history",
                "Net worth over a range, as the Net Worth chart draws it, in total or by account class. By month it also gives each month's change, leaving out opening balances (what an account held when it was linked), which are listed as openingBalances.",
                [
                    "range": range, "by": by,
                    "split": ["type": "string", "enum": ["total", "class"], "description": "total, or each account class too. Default total."]
                ], run: { args in try self.netWorthHistory(args) }),
            tool(
                "accounts",
                "Every account: name, class, balance (what's owed, for debts), when it was last updated and whether that's out of date, and its change over a month and a year. Never account numbers.",
                ["include_archived": ["type": "boolean", "description": "Also closed (archived) accounts. Default false."]],
                run: { args in try await self.accounts(args) }),
            tool(
                "account_history", "One account's balance over a range, as its history chart draws it (what's owed, for debts).",
                ["account": text("The account's name or id (from accounts)."), "range": range, "by": by], required: ["account"],
                run: { args in try await self.accountHistory(args) }),
            tool(
                "goals",
                "Every money goal: target, date, status, note (why it matters to them), progress (current, fraction, remaining, pace per month, needed per month, projected date, standing: reached, on track or behind for a dated goal; growing or not growing for one with no date), in the order active goals need a look, plus milestones reached. Pace is the last three months' gain leaving out opening balances of newly linked accounts; for a goal of investing accounts only it's what they put in over the last three full months (paceBasis contributions), with the market's part apart and accounts whose contributions can't be told listed.",
                run: { _ in try self.goals() }),
            tool(
                "goal_history", "One goal's measured value over a range, as its chart draws it.",
                ["goal": text("The goal's name or id (from goals)."), "range": range], required: ["goal"], run: { args in try await self.goalHistory(args) }),
            tool(
                "contributions",
                "Investing progress: for each investment, retirement and equity account, each month's starting and ending balance, money they put in and took out, and market change (the balance change less net contributions), with totals per month. Buys, sells, dividends and fees inside an account are not contributions. In a retirement account that never takes deposits from them (a 401(k) paid from payroll), what it bought less what it sold is the money that came in; an IRA they pay into buys with cash already inside. Contributions are null where the account's own transactions don't cover the month, or where some can't be told from trades (unclear counts them). Their 401(k) and stock plan take theirs paycheck by paycheck once their pay is set up (fromPay: their part and their employer's, split by their pay settings; estimated where a paycheck arrived but the account shows no buys for it, as the settings' expected amount).",
                [
                    "from": text("First month, YYYY-MM. Default 11 months before to."), "to": text("Last month, YYYY-MM. Default this month."),
                    "account": text("Only this account (name or id).")
                ], run: { args in try await self.contributions(args) }),
            tool(
                "monthly_review",
                "A month's report card: net worth change (leaving out opening balances of accounts linked that month, listed apart) split into market change (where it can be told) and everything else, money put into investing, flexible spending against the budget, fixed bills paid, income, the categories furthest from their usual (6-month average; a share of it for a month to date), each goal's movement, and the savings rate (from their pay settings and the paychecks that arrived). The current month is month to date.",
                ["month": month], run: { args in try await self.monthlyReview(args) }),
            tool(
                "pay",
                "Their pay, from the settings they keep in Settings › Pay (salary, every two weeks from a known payday, 401(k) % and match, stock plan) and the paychecks that synced: the settings, gross a year, each paycheck's gross, 401(k) (theirs and the match) and stock purchase (theirs and the company's), the latest net paycheck that arrived, take-home a month on average (latest net × 26 / 12), paydays for the next six months with three-paycheck months marked, the savings rate, and bonuses and vests they expect (never part of the monthly budget). No paystubs are needed.",
                run: { _ in try self.pay() }),
            tool(
                "budget",
                "The budget sheet for a month: income (their paychecks planned from their pay: two paychecks at the latest net), each fixed bill, flexible spending (with income planned, its budget is what's left after bills and savings), irregular spending (annual fees, charity: out of the flexible budget and its pace) and savings per account (short where less moved than planned), planned against actual, plus the flexible pace (left, daily allowance, even pace so far) and bills paid or due.",
                ["month": month], run: { args in try self.budget(args) }),
            tool(
                "spending",
                "Spending by category for a month against each one's 6-month average, plus the 12 months ending then for every category (the Over time grid). Transfers and income are left out.",
                ["month": month], run: { args in try self.spending(args) }),
            tool(
                "transactions",
                "Search transactions, newest first. Each has an id (for edit_transaction), their note, whether it's a one-off, whether someone owes them for it (owedBack, which isn't counted as spending), and the goal that paid for it (paidFromGoal: still spending, but out of the budget). A split one lists its parts (splits); its category is its largest part's, spending counts each part in its own category, and a category filter returns it whole when any part matches, so count only that part's amount.",
                [
                    "text": text("Matches merchant or statement text, ignoring case and store numbers."),
                    "category": text("A category name, or \"unfiled\" for ones with none."),
                    "month": text("YYYY-MM."), "from": text("First day, YYYY-MM-DD."), "to": text("Last day, YYYY-MM-DD."),
                    "account": text("Account name or id."),
                    "direction": ["type": "string", "enum": ["in", "out"], "description": "Only money in, or only money out."],
                    "min_amount": text("Smallest size, ignoring sign, like \"100\"."), "max_amount": text("Largest size, ignoring sign."),
                    "has_note": ["type": "boolean", "description": "Only ones with a note (true) or without (false)."],
                    "one_off": ["type": "boolean", "description": "Only one-offs (true) or not (false)."],
                    "reimbursable": ["type": "boolean", "description": "Only ones someone owes them for (true) or not (false)."],
                    "note_text": text("Matches their note, ignoring case."),
                    "limit": ["type": "integer", "description": "At most this many (default 50, up to 500)."]
                ], run: { args in try await self.transactions(args) }),
            tool(
                "categories",
                "Every category: its kind (spending, income or transfer), its budget role (fixed, flexible or irregular: annual or occasional costs kept out of the flexible budget) and how many transactions it holds. Claude changes them with set_budget_role.",
                run: { _ in try self.categories() }),
            tool(
                "reminders",
                "Apple Reminders as the Life overview sorts them, each repeating one with its repeat (custom when only Reminders can describe it): this week (overdue first, then Playbook repeats due by tomorrow, marked playbookEntry and ticked with done_playbook_entry, not complete_reminder; Compass keeps each as a reminder on their phone, listed only here as the entry), every day (daily repeats no habit stands in for; the habits tool has the rest), admin, this quarter (with target, progress and any reward for ones following net worth or a goal), coming up (deadlines in the next few months that are not quarter goals), living list (and what was ticked off it this year, with dates), and the inbox count.",
                run: { _ in try await self.remindersAgenda() }),
            tool("habits", "Each habit: times a week, check-ins this week and still needed, streak, and the last 8 weeks.", run: { _ in try self.habits() }),
            tool(
                "vision",
                "Their vision; this year's bets (the few things they're betting the year on); this quarter's goals from their This Quarter list in Reminders, with target, progress and any reward where one follows net worth or a money goal; and the Living List, open and ticked off this year.",
                run: { _ in try await self.vision() }),
            tool(
                "calendar",
                "Calendar events between two days, from the calendars they show in Compass and always the Compass calendar (where create_event adds events). Every event has an id for move_event and edit_event; Claude's own say createdByClaude. Lists the calendars read.",
                ["start": text("First day, YYYY-MM-DD. Default today."), "end": text("Last day, YYYY-MM-DD, at most 92 days on. Default 6 days after start.")],
                run: { args in try self.calendarEvents(args) }),
            tool(
                "free_time",
                "The free stretches between calendar events in a range: every gap, at any hour (Compass sets no working hours; judge which suit them). All-day events don't block time.",
                [
                    "start": text("ISO 8601 date-time or YYYY-MM-DD. Default now."),
                    "end": text("ISO 8601 date-time or YYYY-MM-DD (to the end of that day). Default 7 days after start."),
                    "minimum_minutes": ["type": "integer", "description": "Shortest gap worth listing. Default 30."]
                ], run: { args in try self.freeTime(args) }),
            playbookReadTool,
            notesReadTool
        ] + categoryReadTools
    }

    /// Every tool, each declared once with its schema and handler: the read
    /// tools, then the change tools, whose arguments are checked against
    /// their schema before they run.
    var all: [ClaudeTool] {
        let tools = readTools + changeTools.map(\.checkingArguments)
        assert(Set(tools.map(\.name)).count == tools.count, "Two Claude tools share a name")
        return tools
    }

    /// What `tools/list` answers.
    var list: [[String: Any]] { all.map(\.schema) }
}
