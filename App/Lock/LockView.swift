import SwiftUI

struct LockView: View {
    @Environment(AppLock.self) private var lock

    var body: some View {
        VStack(spacing: Spacing.l) {
            Image(systemName: "lock")
                .font(.system(size: 32 * TextSize.current.scale, weight: .light))
                .foregroundStyle(Palette.inkSecondary)
            Text("Compass is locked")
                .font(Typeface.title)
                .foregroundStyle(Palette.ink)
            Button("Unlock with Touch ID") {
                Task { await lock.unlock() }
            }
            .keyboardShortcut(.defaultAction)
            .tint(Palette.needle)
            .disabled(lock.isAuthenticating)
            if DataEnvironment.current == .sandbox {
                Text("Sandbox data").font(Typeface.detail).foregroundStyle(Palette.behind)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.canvas)
    }
}
