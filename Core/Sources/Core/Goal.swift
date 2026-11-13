import Foundation

public enum GoalKind: Hashable, Codable, Sendable {
    /// Total net worth.
    case netWorth
    /// The sum of the chosen accounts.
    case accountTotal(Set<UUID>)
    /// Investable assets (taxable, retirement, equity) against annual spending
    /// times the multiplier, usually 25.
    case fire(annualSpending: Decimal, multiplier: Decimal)
}

public enum GoalStatus: Hashable, Codable, Sendable {
    case active
    case achieved(on: Day, value: Decimal)
    /// Never deleted: a goal you changed your mind about stays in history.
    case retired(reason: String)
}

/// A reward is spending, never an asset: it never counts toward net worth.
public struct Reward: Hashable, Codable, Sendable {
    public var name: String
    public var cost: Decimal?
    public var claimedOn: Day?

    public init(name: String, cost: Decimal? = nil, claimedOn: Day? = nil) {
        self.name = name
        self.cost = cost
        self.claimedOn = claimedOn
    }
}

public struct Goal: Hashable, Identifiable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: GoalKind
    /// Ignored for FIRE goals, whose target comes from spending.
    public var target: Decimal
    /// The bottom of a range, like an emergency fund of $22K to $25K.
    public var targetMin: Decimal?
    public var targetDate: Day?
    public var status: GoalStatus
    public var reward: Reward?
    /// The goal this one follows in a chain ($50K → $100K → $150K).
    public var predecessorID: UUID?
    /// Why it matters, in their words ("by my 30th birthday").
    public var note: String

    public init(
        id: UUID = UUID(),
        name: String,
        kind: GoalKind,
        target: Decimal,
        targetMin: Decimal? = nil,
        targetDate: Day? = nil,
        status: GoalStatus = .active,
        reward: Reward? = nil,
        predecessorID: UUID? = nil,
        note: String = ""
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.target = target
        self.targetMin = targetMin
        self.targetDate = targetDate
        self.status = status
        self.reward = reward
        self.predecessorID = predecessorID
        self.note = note
    }

    /// Goals saved before notes read back with none.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(GoalKind.self, forKey: .kind)
        target = try container.decode(Decimal.self, forKey: .target)
        targetMin = try container.decodeIfPresent(Decimal.self, forKey: .targetMin)
        targetDate = try container.decodeIfPresent(Day.self, forKey: .targetDate)
        status = try container.decode(GoalStatus.self, forKey: .status)
        reward = try container.decodeIfPresent(Reward.self, forKey: .reward)
        predecessorID = try container.decodeIfPresent(UUID.self, forKey: .predecessorID)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
    }

    public var effectiveTarget: Decimal {
        if case .fire(let spending, let multiplier) = kind { return spending * multiplier }
        return target
    }
}

/// Why a goal can't be saved as it stands. The goal editor and Claude's
/// tools check the same things and word them for their own reader.
public enum GoalProblem: Hashable, Sendable {
    case noAccounts
    case noSpending
    case noTarget
    case minimumNotBelowTarget
}

extension Goal {
    /// Nil when the goal can be saved.
    public var problem: GoalProblem? {
        switch kind {
        case .accountTotal(let ids) where ids.isEmpty: return .noAccounts
        case .fire(let spending, _): return spending > 0 ? nil : .noSpending
        default: break
        }
        guard target > 0 else { return .noTarget }
        if let targetMin, targetMin >= target { return .minimumNotBelowTarget }
        return nil
    }
}
