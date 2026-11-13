import Observation
import SwiftUI

/// A change that couldn't be saved, told to the user once instead of being
/// dropped. Screens save through `attempt`; the main window shows the alert.
@MainActor @Observable
final class SaveFailures {
    static let shared = SaveFailures()

    /// What went wrong, while its alert is up.
    var message: String?

    /// Runs a save. A failure is logged and shown, and reads as false.
    @discardableResult
    func attempt(_ save: () throws -> Void) -> Bool {
        do {
            try save()
            return true
        } catch {
            storeLog.error("Couldn't save a change: \(error.localizedDescription, privacy: .public)")
            message = error.localizedDescription
            return false
        }
    }
}

extension View {
    /// Shows a change that couldn't be saved.
    func saveFailureAlert() -> some View {
        let failures = SaveFailures.shared
        return alert(
            "Compass couldn't save that change",
            isPresented: Binding(get: { failures.message != nil }, set: { if !$0 { failures.message = nil } })
        ) {
            Button("OK") { failures.message = nil }
        } message: {
            let reason: String = failures.message ?? ""
            Text(reason + " Nothing else was changed; try again, and check Settings › Data for a recent backup if it keeps happening.")
        }
    }
}
