import Core
import Foundation
import SwiftData

/// A resolution or quarterly goal, stored as JSON beside its id. Nothing
/// shows them now that Reminders holds the quarter; they stay for the backup.
@Model
final class LifeGoalRecord {
    @Attribute(.unique) var id: UUID
    var goalData: Data
    var createdAt: Date

    init(_ goal: LifeGoal) {
        id = goal.id
        goalData = (try? JSONEncoder().encode(goal)) ?? Data()
        createdAt = .now
    }

    var goal: LifeGoal? { try? JSONDecoder().decode(LifeGoal.self, from: goalData) }
}

@Model
final class ListItemRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var addedOrdinal: Int
    var doneOrdinal: Int?
    /// The year it's listed under; items from before years existed have none.
    var year: Int?

    init(_ item: ListItem) {
        id = item.id
        title = item.title
        addedOrdinal = item.addedOn.ordinal
        doneOrdinal = item.doneOn?.ordinal
        year = item.year
    }

    var item: ListItem {
        ListItem(id: id, title: title, addedOn: Day(ordinal: addedOrdinal), doneOn: doneOrdinal.map(Day.init(ordinal:)), year: year)
    }
}

/// A weekly habit, stored as JSON beside its id like life goals.
@Model
final class HabitRecord {
    @Attribute(.unique) var id: UUID
    var habitData: Data
    var createdAt: Date

    init(_ habit: Habit) {
        id = habit.id
        habitData = (try? JSONEncoder().encode(habit)) ?? Data()
        createdAt = .now
    }

    var habit: Habit? { try? JSONDecoder().decode(Habit.self, from: habitData) }
}

/// A quarter reminder followed by one of Compass's numbers, stored as JSON
/// beside its id like life goals.
@Model
final class ReminderMeasureRecord {
    @Attribute(.unique) var id: UUID
    var linkData: Data

    init(_ link: ReminderMeasure) {
        id = link.id
        linkData = (try? JSONEncoder().encode(link)) ?? Data()
    }

    var link: ReminderMeasure? { try? JSONDecoder().decode(ReminderMeasure.self, from: linkData) }
}

/// What a good life looks like, in the owner's words. One row.
@Model
final class VisionRecord {
    var text: String
    var updatedAt: Date

    init(text: String) {
        self.text = text
        updatedAt = .now
    }
}

/// A year's bets, as they typed them: one a line.
@Model
final class YearlyBetsRecord {
    @Attribute(.unique) var year: Int
    var text: String
    var updatedAt: Date

    init(year: Int, text: String) {
        self.year = year
        self.text = text
        updatedAt = .now
    }

    var bets: YearlyBets { YearlyBets(year: year, bets: YearlyBets.lines(text)) }
}

extension CompassStore {
    func save(_ goal: LifeGoal) throws {
        let id = goal.id
        var descriptor = FetchDescriptor<LifeGoalRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let record = try context.fetch(descriptor).first {
            record.goalData = (try? JSONEncoder().encode(goal)) ?? record.goalData
        } else {
            context.insert(LifeGoalRecord(goal))
        }
        try context.save()
    }

    func save(_ item: ListItem) throws {
        let id = item.id
        var descriptor = FetchDescriptor<ListItemRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let record = try context.fetch(descriptor).first {
            record.title = item.title
            record.doneOrdinal = item.doneOn?.ordinal
            record.year = item.year
        } else {
            context.insert(ListItemRecord(item))
        }
        try context.save()
    }

    func save(_ habit: Habit) throws {
        let id = habit.id
        var descriptor = FetchDescriptor<HabitRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let record = try context.fetch(descriptor).first {
            record.habitData = (try? JSONEncoder().encode(habit)) ?? record.habitData
        } else {
            context.insert(HabitRecord(habit))
        }
        try context.save()
    }

    /// One life goal as stored now, or nil if it isn't saved yet.
    func lifeGoal(id: UUID) throws -> LifeGoal? {
        var descriptor = FetchDescriptor<LifeGoalRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.goal
    }

    func lifeGoals() throws -> [LifeGoal] {
        try context.fetch(FetchDescriptor<LifeGoalRecord>(sortBy: [SortDescriptor(\.createdAt)])).compactMap(\.goal)
    }

    func habits() throws -> [Habit] {
        try context.fetch(FetchDescriptor<HabitRecord>(sortBy: [SortDescriptor(\.createdAt)])).compactMap(\.habit)
    }

    func listItems() throws -> [ListItem] {
        try context.fetch(FetchDescriptor<ListItemRecord>()).map(\.item)
    }

    func reminderMeasures() throws -> [ReminderMeasure] {
        try context.fetch(FetchDescriptor<ReminderMeasureRecord>()).compactMap(\.link)
    }

    func save(_ link: ReminderMeasure) throws {
        let id = link.id
        var descriptor = FetchDescriptor<ReminderMeasureRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let record = try context.fetch(descriptor).first {
            record.linkData = (try? JSONEncoder().encode(link)) ?? record.linkData
        } else {
            context.insert(ReminderMeasureRecord(link))
        }
        try context.save()
    }

    func delete(_ link: ReminderMeasure) throws {
        let id = link.id
        try context.delete(model: ReminderMeasureRecord.self, where: #Predicate { $0.id == id })
        try context.save()
    }

    func vision() throws -> String {
        try context.fetch(FetchDescriptor<VisionRecord>()).first?.text ?? ""
    }

    func yearlyBets() throws -> [YearlyBets] {
        try context.fetch(FetchDescriptor<YearlyBetsRecord>(sortBy: [SortDescriptor(\.year)])).map(\.bets)
    }

    func betsText(year: Int) throws -> String {
        var descriptor = FetchDescriptor<YearlyBetsRecord>(predicate: #Predicate { $0.year == year })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.text ?? ""
    }

    func saveBets(_ text: String, year: Int) throws {
        var descriptor = FetchDescriptor<YearlyBetsRecord>(predicate: #Predicate { $0.year == year })
        descriptor.fetchLimit = 1
        if let record = try context.fetch(descriptor).first {
            guard record.text != text else { return }
            record.text = text
            record.updatedAt = .now
        } else {
            context.insert(YearlyBetsRecord(year: year, text: text))
        }
        try context.save()
    }

    func saveVision(_ text: String) throws {
        if let record = try context.fetch(FetchDescriptor<VisionRecord>()).first {
            guard record.text != text else { return }
            record.text = text
            record.updatedAt = .now
        } else {
            context.insert(VisionRecord(text: text))
        }
        try context.save()
    }
}
