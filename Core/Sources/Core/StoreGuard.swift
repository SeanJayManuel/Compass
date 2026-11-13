import Foundation

/// The models in a store and each one's fields, by name.
public struct StoreShape: Codable, Equatable, Sendable {
    public var models: [String: Set<String>]

    public init(_ models: [String: Set<String>]) { self.models = models }

    /// Both shapes' models, with the fields either one names.
    public func merging(_ other: StoreShape) -> StoreShape {
        StoreShape(models.merging(other.models) { $0.union($1) })
    }
}

/// Whether this build may open a store. Opening a store migrates it to the
/// models this build knows, dropping any it doesn't, so a build older than
/// the store must refuse (on Oct 30, 2026 a build from before the Playbook
/// opened the store and dropped it).
public enum StoreGuard {
    /// What the store holds that this build doesn't know ("Model" or
    /// "Model.field"), sorted; empty when it may open. `retired` names models
    /// and fields removed on purpose, which the migration may drop.
    public static func unknown(in stored: StoreShape, known: StoreShape, retired: Set<String> = []) -> [String] {
        var unknown: [String] = []
        for (model, fields) in stored.models where !retired.contains(model) {
            guard let knownFields = known.models[model] else {
                unknown.append(model)
                continue
            }
            unknown += fields.subtracting(knownFields).map { "\(model).\($0)" }.filter { !retired.contains($0) }
        }
        return unknown.sorted()
    }
}
