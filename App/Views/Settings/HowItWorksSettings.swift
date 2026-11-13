import SwiftUI

/// How each part of Compass works (`GuideTopic`): one topic at a time, each
/// idea in words with its formula under it. The toolbar's ⓘ opens it at the
/// screen you were on.
struct HowItWorksSettings: View {
    @AppStorage(GuideTopic.key) private var topic = GuideTopic.life

    var body: some View {
        Form {
            Section {
                Picker("Topic", selection: $topic) {
                    ForEach(GuideTopic.allCases) { Text($0.title).tag($0) }
                }
                SettingsNote("What each number means and when it changes. The ⓘ in the toolbar opens the screen you're on.")
            }
            Section {
                ForEach(topic.entries) { GuideRow(entry: $0) }
            } header: {
                SettingsHeader(topic.title)
            }
        }
        .settingsPane()
    }
}

private struct GuideRow: View {
    let entry: GuideEntry

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(entry.title).font(Typeface.body.weight(.semibold)).foregroundStyle(Palette.ink)
            Text(entry.text)
                .font(Typeface.body).foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let formula = entry.formula {
                Text(formula)
                    .font(Typeface.detail.monospacedDigit()).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Spacing.s).padding(.vertical, Spacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.needleWash, in: .rect(cornerRadius: 6))
            }
        }
        .padding(.vertical, Spacing.xs)
        .textSelection(.enabled)
    }
}
