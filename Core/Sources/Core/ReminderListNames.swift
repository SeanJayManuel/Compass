import Foundation

/// The Reminders lists Compass gives a job to, by name. The standard names
/// are one way to keep lists; Settings > Data lets each be renamed, with
/// several names separated by commas.
public struct ReminderListNames: Equatable, Sendable {
    /// What a list is for.
    public enum Role: String, CaseIterable, Sendable {
        case week, admin, quarter, comingUp, living, inbox, repeats

        /// Where a renamed list is kept in the preferences.
        public var key: String { "reminders.lists.\(rawValue)" }

        /// What Settings calls it.
        public var label: String {
            switch self {
            case .week: "This week"
            case .admin: "Admin"
            case .quarter: "This quarter"
            case .comingUp: "Coming up"
            case .living: "Living list"
            case .inbox: "Inbox"
            case .repeats: "Playbook repeats"
            }
        }

        /// What the list does, for Settings.
        public var purpose: String {
            switch self {
            case .week: "Counts as due this week, even without dates."
            case .admin: "Errands, shown under To do whatever their dates."
            case .quarter: "This quarter's goals, which can follow net worth or a money goal."
            case .comingUp: "Deadlines in the next few months."
            case .living: "Shown with the vision."
            case .inbox: "Only counted, still to sort."
            case .repeats: "Where the Playbook's repeating entries become reminders."
            }
        }
    }

    public var week: [String]
    public var admin: [String]
    public var quarter: [String]
    public var comingUp: [String]
    public var living: [String]
    public var inbox: [String]
    public var repeats: [String]

    /// The names Compass looks for until they're changed.
    public static let standard = ReminderListNames(
        week: ["This Week"], admin: ["Admin", "Errands"], quarter: ["This Quarter"], comingUp: ["Coming Up", "Long Term"],
        living: ["Living List"], inbox: ["Inbox"], repeats: ["Repetitive Tasks"])

    public init(
        week: [String], admin: [String], quarter: [String], comingUp: [String], living: [String], inbox: [String], repeats: [String]
    ) {
        self.week = week
        self.admin = admin
        self.quarter = quarter
        self.comingUp = comingUp
        self.living = living
        self.inbox = inbox
        self.repeats = repeats
    }

    /// The names saved in the preferences, the standard ones where none are.
    public init(defaults: UserDefaults) {
        self = .standard
        for role in Role.allCases {
            self[role] = Self.parse(defaults.string(forKey: role.key), standard: Self.standard[role])
        }
    }

    /// The names in use now.
    public static var saved: ReminderListNames { ReminderListNames(defaults: .standard) }

    public subscript(role: Role) -> [String] {
        get {
            switch role {
            case .week: week
            case .admin: admin
            case .quarter: quarter
            case .comingUp: comingUp
            case .living: living
            case .inbox: inbox
            case .repeats: repeats
            }
        }
        set {
            switch role {
            case .week: week = newValue
            case .admin: admin = newValue
            case .quarter: quarter = newValue
            case .comingUp: comingUp = newValue
            case .living: living = newValue
            case .inbox: inbox = newValue
            case .repeats: repeats = newValue
            }
        }
    }

    /// Names typed with commas between them; nothing typed means the standard ones.
    public static func parse(_ text: String?, standard: [String]) -> [String] {
        let names = (text ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return names.isEmpty ? standard : names
    }

    /// Whether a Reminders list has this job, ignoring case and spaces around its name.
    public func matches(_ role: Role, _ title: String) -> Bool {
        self[role].contains { title.sameTitle(as: $0) }
    }
}
