import AppKit
import Core
import SwiftUI

/// One reached goal or claimed reward on a timeline, used by Goals.
struct LifeMilestoneRow: View {
    let milestone: LifeMilestone

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.l) {
            Text(milestone.day.startDate(in: .current).formatted(.dateTime.month(.abbreviated).day().year()))
                .font(Typeface.detail).monospacedDigit().foregroundStyle(Palette.inkSecondary)
                .frame(width: 96 * TextSize.current.scale, alignment: .leading)
            Circle().fill(Palette.onPace).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(milestone.title).font(Typeface.body).foregroundStyle(Palette.ink)
                Text(milestone.source).font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            }
        }
        .padding(.vertical, Spacing.s + Spacing.xs)
    }
}

struct MilestoneRow: View {
    let event: Milestone
    var photo: Data?
    /// The goal rail stacks dates, photos and actions so every item keeps its room.
    var compact = false
    /// Opens the goal's page. When set, the row's text is a button.
    var action: (() -> Void)?
    /// For a reached goal whose reward isn't claimed yet: shows Mark Claimed.
    var onClaim: (() -> Void)?
    /// For a claimed reward: Add Photo… or Change Photo….
    var onPhoto: (() -> Void)?

    var body: some View {
        let layout =
            compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.s))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Spacing.m))
        layout {
            if let action {
                Button(action: action) { content.contentShape(.rect) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the goal")
            } else {
                content
            }
            if !compact { Spacer(minLength: 0) }
            trailing
        }
        .padding(.vertical, Spacing.s + Spacing.xs)
    }

    @ViewBuilder private var content: some View {
        if compact {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(spacing: Spacing.s) {
                    dot; date
                }
                story
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.l) {
                date.frame(width: 96 * TextSize.current.scale, alignment: .leading)
                dot
                story
            }
        }
    }

    private var date: some View {
        Text(event.day.startDate(in: .current).formatted(.dateTime.month(.abbreviated).day().year()))
            .font(Typeface.detail).monospacedDigit().foregroundStyle(Palette.inkSecondary)
    }

    private var dot: some View {
        Circle().fill(event.kind == .reached ? Palette.needle : Palette.onPace).frame(width: 8, height: 8)
    }

    private var story: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch event.kind {
            case .reached:
                Text("Reached \(event.goal.name)").font(Typeface.body).foregroundStyle(Palette.ink)
                if let detail = chainDetail { Text(detail).font(Typeface.detail).foregroundStyle(Palette.inkSecondary) }
                if let reward = unclaimedReward {
                    Text("Unlocked: \(reward)").font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                }
            case .rewardClaimed:
                Text("Claimed \(event.goal.reward?.name ?? "a reward")").font(Typeface.body).foregroundStyle(Palette.ink)
                if let photo, let image = NSImage(data: photo) {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: 160 * TextSize.current.scale, height: 110 * TextSize.current.scale).clipShape(.rect(cornerRadius: 8))
                        .padding(.vertical, Spacing.xs)
                        .accessibilityLabel("Photo of \(event.goal.reward?.name ?? "the reward")")
                }
                if let cost = event.goal.reward?.cost {
                    Text("Spent \(cost.wholeDollars), for reaching \(event.goal.name)")
                        .font(Typeface.detail).foregroundStyle(Palette.inkSecondary).privateAmount()
                }
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let onClaim, unclaimedReward != nil, event.kind == .reached {
            Button("Mark Claimed", action: onClaim).linkButton().font(Typeface.detail)
        }
        if let onPhoto, event.kind == .rewardClaimed {
            Button(photo == nil ? "Add Photo" : "Change Photo", action: onPhoto)
                .linkButton().font(Typeface.detail)
        }
    }

    /// The reward's name while it's unlocked but not yet claimed.
    private var unclaimedReward: String? {
        guard let reward = event.goal.reward, reward.claimedOn == nil else { return nil }
        return reward.name
    }

    /// "11 months after $50K" for a goal in a chain.
    private var chainDetail: String? {
        guard let months = event.monthsSincePrevious, let previous = event.previousName else { return nil }
        return months <= 1 ? "About a month after \(previous)" : "\(months) months after \(previous)"
    }
}
