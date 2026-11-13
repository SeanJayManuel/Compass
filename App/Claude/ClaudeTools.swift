import Core
import Foundation
import SwiftData

/// What Claude can ask Compass and change in it. Each tool is one `ClaudeTool`
/// entry (schema and handler together): the read tools are listed in
/// ClaudeReadTools.swift and answered by the Money, Pay and Life files with
/// the same Core functions the screens use; the tools that change things are
/// in ClaudeChangeTools.swift and the other `Claude*Tools` files. To add a
/// tool, add an entry to the right list and its handler beside it.
@MainActor
final class ClaudeTools {
    /// What Claude is told about Compass when it connects, naming the owner
    /// from Settings › Profile ("the owner" until a name is set).
    static func instructions(for name: String) -> String {
        let owner = name == Profile.defaultName ? "the owner" : name
        return """
            Compass is \(owner)'s personal finance and life app on their Mac. Amounts are US dollars, as strings with two \
            decimals. Net worth already subtracts debts. A debt account's balance, and the debt class's total, is what they owe (positive; below zero \
            means a card is overpaid), so a falling debt balance is good news. Transaction amounts are signed: money out \
            is negative, money in positive. Dates are ISO (YYYY-MM-DD, local days); months are YYYY-MM; times are ISO \
            8601 with their time zone's offset. Ranges are 3M, 6M, YTD, 1Y, 5Y or All and end today. The current month \
            is always month to date and says so (monthToDate). Investing contributions are their money moving in or out \
            of an account; market change is the rest of the balance change. Where Compass can't tell them apart, \
            contributions are null, not zero. An account's first balance when it's linked is an opening balance, money that \
            was already theirs: net worth changes, monthly changes and goal pace leave it out. Claude can keep up goals (create, change, \
            retire, rewards, also on a This Quarter reminder with a target; never deleted), reminders (add, edit with repeats, move, tick, reopen, delete), habits and check-ins, the vision and \
            this year's bets, the Playbook, notes, pay settings and expected bonuses and vests, accounts' names and archiving and \
            manual accounts (create, balances), merchant rules and categories (create, rename, merge), transactions added to a \
            manual account and split into categories, a transaction's note, one-off and reimbursable flags and category (what's owed back isn't counted as spending), the budget (set_budget_amount, set_budget_role), and events: created in a Compass calendar \
            (deleting only its own), and moved or edited on any calendar Compass reads once \(owner) has said yes to that change. Synced balances and balance history, transactions' amounts, dates and merchants, and sync are \
            read-only, account numbers are never given or taken, and nothing moves money. Confirm each change with \(owner) in \
            the chat before making it; the tools don't ask again. Every change shows in Compass with undo; the \
            changes tool lists them, and undo_change takes one back. \
            Notes hold \(owner)'s standing rules and the reasons behind them (why they keep a cash buffer, what they're \
            optimizing their career for), since chats through Compass can't keep memories: read them (the notes tool) at the \
            start of any planning or advice chat, and add or edit one when they settle a rule or explain a reason worth \
            keeping. Never put figures other tools already give in a note (balances, pay, budget amounts, goal targets); \
            say where the figure lives instead, so a note doesn't go stale.
            """
    }

    let container: ModelContainer
    let netWorth: NetWorthCache
    let reminders: RemindersService
    let calendar: CalendarService

    init(container: ModelContainer, netWorth: NetWorthCache, reminders: RemindersService, calendar: CalendarService) {
        self.container = container
        self.netWorth = netWorth
        self.reminders = reminders
        self.calendar = calendar
    }

    var store: CompassStore { CompassStore(context: container.mainContext) }
    var today: Day { netWorth.today }

    // MARK: - Calls

    /// The answer as JSON text; an error, or a tool that doesn't exist, says so with isError.
    func call(_ name: String, arguments: [String: Any]) async -> (text: String, isError: Bool)? {
        let args = Arguments(arguments)
        do {
            guard let tool = all.first(where: { $0.name == name }) else {
                return (json(["error": ClaudeRules.refusal(forTool: name)]), true)
            }
            if tool.checksArguments {
                let schema = tool.schema["inputSchema"] as? [String: Any]
                try args.onlyKnown((schema?["properties"] as? [String: Any] ?? [:]).keys)
            }
            let answer = try await tool.run(args)
            return (json(answer), false)
        } catch let problem as Problem {
            return (json(["error": problem.message]), true)
        } catch let refusal as ClaudeRefusal {
            return (json(["error": refusal.message]), true)
        } catch {
            return (json(["error": error.localizedDescription]), true)
        }
    }

    // MARK: - Reading the store

    /// Long-history reads get a context of their own off the main thread, as
    /// `NetWorthCache` does, so the window never waits on 90,000-odd balances.
    struct Money: Sendable {
        var accounts: [Account]
        var snapshots: [BalanceSnapshot]
        var transactions: [Transaction]
    }

    func load(snapshots: Bool = false, transactions: Bool = false) async -> Money {
        await Self.load(container, snapshots: snapshots, transactions: transactions)
    }

    @concurrent nonisolated private static func load(_ container: ModelContainer, snapshots: Bool, transactions: Bool) async -> Money {
        let context = ModelContext(container)
        return Money(
            accounts: context.all(AccountRecord.self).map(\.account),
            snapshots: snapshots ? context.all(SnapshotRecord.self).map(\.snapshot) : [],
            transactions: transactions ? context.all(TransactionRecord.self).map(\.transaction) : []
        )
    }

    /// One month's transactions (and `monthsBefore` before it, for bills' usual days).
    func monthTransactions(_ month: Month, monthsBefore: Int = 0) throws -> [Transaction] {
        let first = month.adding(-monthsBefore).firstDay.ordinal, last = month.adding(1).firstDay.ordinal
        return try container.mainContext.fetch(
            FetchDescriptor<TransactionRecord>(
                predicate: #Predicate {
                    $0.dayOrdinal >= first && $0.dayOrdinal < last
                })
        ).map(\.transaction)
    }

    func find(_ wanted: String, in accounts: [Account]) throws -> Account {
        if let account = accounts.first(where: { $0.id.uuidString.caseInsensitiveCompare(wanted) == .orderedSame }) { return account }
        let named = accounts.filter { Self.displayName($0.name).localizedCaseInsensitiveCompare(wanted.trimmingCharacters(in: .whitespaces)) == .orderedSame }
        if named.count == 1 { return named[0] }
        let containing = accounts.filter { Self.displayName($0.name).localizedCaseInsensitiveContains(wanted) }
        if containing.count == 1 { return containing[0] }
        throw Problem(
            named.count + containing.count > 1
                ? "More than one account matches \(wanted); use its id from accounts."
                : "No account called \(wanted). Names: \(accounts.map { Self.displayName($0.name) }.joined(separator: ", ")).")
    }

    // MARK: - Shaping answers

    /// The chart's point limit (Net Worth and account history).
    static let pointLimit = 120

    /// An account's name without the last digits of its number that Monarch
    /// and banks append, like "Checking (...1234)" or "CARD ...1234".
    static func displayName(_ name: String) -> String {
        name.replacing(/\s*\((?:\.+|…|x+|\*+)?\s*\d{2,}\)\s*$/, with: "")
            .replacing(/(?:\s*(?:\.{2,}|…)|\s+(?:x{1,4}|\*+|#))\d{2,}\s*$/, with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    func goalSummary(_ goal: Goal, progress: GoalProgress?) -> [String: Any] {
        var row: [String: Any] = ["id": goal.id.uuidString, "name": goal.name, "target": dollars(goal.effectiveTarget)]
        switch goal.status {
        case .active: row["status"] = "active"
        case .achieved(let on, let value): row["status"] = "achieved"; row["achievedOn"] = iso(on); row["achievedAt"] = dollars(value)
        case .retired(let reason): row["status"] = "retired"; row["retiredBecause"] = reason
        }
        if let progress {
            row["current"] = dollars(progress.current)
            row["fraction"] = fraction(progress.fraction)
            row["standing"] = progress.reading(dated: goal.targetDate != nil).rawValue
        }
        return row
    }

    /// The last value in each week (Sunday to Saturday) or month.
    func periodEnds<Point>(_ points: [Point], by: String, day: (Point) -> Day) -> [Point] {
        var result: [Point] = []
        var lastKey: Int?
        for point in points {
            let date = day(point)
            let key = by == "week" ? Week(date).start.ordinal : date.year * 12 + date.month
            if key == lastKey { result[result.count - 1] = point } else { result.append(point) }
            lastKey = key
        }
        return result
    }

    /// Each class's total; debt as what's owed, like a debt account's balance.
    func byClass(_ amounts: [AccountClass: Decimal]) -> [String: String] {
        var result: [String: String] = [:]
        for (accountClass, amount) in amounts { result[accountClass.rawValue] = dollars(BalanceHistoryMeasure(accountClass).drawn(amount)) }
        return result
    }

    /// A read-only tool, or with `changes` one that changes something, which
    /// Claude desktop asks about before running. MCP takes a change as
    /// destructive unless it says otherwise.
    func tool(
        _ name: String, _ description: String, _ properties: [String: Any] = [:],
        required: [String] = [], changes: Bool = false, destructive: Bool = true,
        run: @escaping (Arguments) async throws -> [String: Any]
    ) -> ClaudeTool {
        var schema: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
        if !required.isEmpty { schema["required"] = required }
        let annotations: [String: Any] =
            changes
            ? ["readOnlyHint": false, "destructiveHint": destructive, "openWorldHint": false]
            : ["readOnlyHint": true]
        let entry: [String: Any] = ["name": name, "description": description, "inputSchema": schema, "annotations": annotations]
        return ClaudeTool(name: name, schema: entry, run: run)
    }

    /// An event's EventKit identifier: Compass tells repeats apart with "@" and the start time.
    static func itemID(_ eventID: String) -> String {
        eventID.firstIndex(of: "@").map { String(eventID[..<$0]) } ?? eventID
    }

    /// Two decimals always ("1234.50"), or null.
    func dollars(_ amount: Decimal?) -> Any {
        guard let amount else { return NSNull() }
        return Self.twoDecimals(amount)
    }

    func dollars(_ amount: Decimal) -> String { Self.twoDecimals(amount) }

    nonisolated static func twoDecimals(_ amount: Decimal) -> String {
        amount.formatted(.number.precision(.fractionLength(2)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }

    /// A share from 0 to 1, to three decimals.
    func fraction(_ value: Decimal) -> String {
        value.formatted(.number.precision(.fractionLength(3)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }

    func iso(_ day: Day) -> String {
        String(format: "%04d-%02d-%02d", day.year, day.month, day.dayOfMonth)
    }

    /// With their time zone's offset: "2026-10-28T09:00:00-07:00".
    func isoTime(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    func monthText(_ month: Month) -> String { String(format: "%04d-%02d", month.year, month.month) }

    func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// One tool Claude can call: its MCP schema and what runs it, declared
/// together so a tool can't be listed without a handler or the reverse.
struct ClaudeTool {
    let name: String
    let schema: [String: Any]
    /// Change tools refuse arguments their schema doesn't name.
    var checksArguments = false
    let run: (Arguments) async throws -> [String: Any]

    var checkingArguments: ClaudeTool {
        var tool = self
        tool.checksArguments = true
        return tool
    }
}

/// A request Claude can fix, in words.
struct Problem: Error {
    var message: String
    init(_ message: String) { self.message = message }
}

/// Tool arguments, read strictly: a wrong value is an error, not a default.
struct Arguments {
    let values: [String: Any]
    init(_ values: [String: Any]) { self.values = values }

    func string(_ key: String) -> String? {
        guard let value = values[key] as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value.trimmingCharacters(in: .whitespaces)
    }

    func required(_ key: String) throws -> String {
        guard let value = string(key) else { throw Problem("\(key) is required.") }
        return value
    }

    func choice(_ key: String, in options: [String]) throws -> String? {
        guard let value = string(key)?.lowercased() else { return nil }
        guard options.contains(value) else { throw Problem("\(key) must be one of \(options.joined(separator: ", ")).") }
        return value
    }

    func range() throws -> TimeRange {
        guard let value = string("range") else { return .oneYear }
        guard let range = TimeRange.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(value) == .orderedSame }) else {
            throw Problem("range must be one of \(TimeRange.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return range
    }

    func bool(_ key: String) throws -> Bool? {
        guard let value = values[key] else { return nil }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        throw Problem("\(key) must be true or false.")
    }

    func int(_ key: String) throws -> Int? {
        guard let value = values[key] else { return nil }
        // JSON's true and false arrive as NSNumber too; 0 and 1 must still count.
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.intValue }
        if let text = value as? String, let number = Int(text) { return number }
        throw Problem("\(key) must be a whole number.")
    }

    func amount(_ key: String) throws -> Decimal? {
        guard let value = values[key] else { return nil }
        let text = (value as? String) ?? (value as? NSNumber)?.stringValue ?? ""
        guard
            let amount = Decimal(
                string: text.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: ""),
                locale: Locale(identifier: "en_US_POSIX"))
        else {
            throw Problem("\(key) must be an amount like \"100\" or \"99.50\".")
        }
        return abs(amount)
    }

    func month(_ key: String) throws -> Month? {
        guard let value = string(key) else { return nil }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, (1...12).contains(parts[1]), parts[0] > 1900 else { throw Problem("\(key) must be a month like 2026-03.") }
        return Month(year: parts[0], month: parts[1])
    }

    func day(_ key: String) throws -> Day? {
        guard let value = string(key) else { return nil }
        guard let day = Self.day(value) else { throw Problem("\(key) must be a date like 2026-03-14.") }
        return day
    }

    /// A date-time, or a day: its start, or with `endOfDay` the start of the next.
    func moment(_ key: String, endOfDay: Bool) throws -> Date? {
        guard var value = string(key) else { return nil }
        if let day = Self.day(value) { return Day(ordinal: day.ordinal + (endOfDay ? 1 : 0)).startDate(in: .current) }
        // "2026-10-30T09:00": a time to the minute, with seconds left off.
        if value.wholeMatch(of: /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/) != nil { value += ":00" }
        if let date = try? Date(value, strategy: .iso8601) { return date }
        // Without an offset, read as their local time.
        let local = Date.ISO8601FormatStyle(timeZone: .current).year().month().day().dateTimeSeparator(.standard).time(includingFractionalSeconds: false)
        if let date = try? local.parse(value) { return date }
        throw Problem("\(key) must be a date like 2026-03-14 or a time like 2026-03-14T09:00:00-07:00.")
    }

    static func day(_ text: String) -> Day? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard text.count == 10, parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        let day = Day(year: parts[0], month: parts[1], day: parts[2])
        // Rejects Feb 30 and the like, which the calendar rolls over.
        return day.dayOfMonth == parts[2] ? day : nil
    }
}
