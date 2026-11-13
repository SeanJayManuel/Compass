import Core
import SwiftData
import SwiftUI

/// The vision, edited in place on the Life overview's vision card. Set like
/// the card's own text, so starting to edit doesn't move a word. Each change
/// saves as they type.
struct VisionEditor: View {
    @Environment(\.modelContext) private var context
    @Query private var visions: [VisionRecord]
    @State private var text = ""
    @State private var loaded = false
    @FocusState private var editing: Bool

    var body: some View {
        // `TextEditor` doesn't grow with its text (it sizes itself to the
        // unwrapped lines, then scrolls inside itself), so a hidden copy of
        // the text, set the same way, gives it the height of the wrapped
        // text and the page does the scrolling. The copy ends with a spare
        // line, which is also the room for a new line being typed, and the
        // frame is never shorter than three lines.
        ZStack(alignment: .topLeading) {
            // `lineLimit(3...)` only caps a `Text`; it doesn't reserve lines,
            // so the three-line minimum is a second copy the frame takes the
            // taller of.
            sizingCopy(" \n \n ")
            sizingCopy(text + "\n ")
        }
        .hidden()
        .overlay {
            TextEditor(text: $text)
                .focused($editing)
                .font(Self.font)
                .foregroundStyle(Palette.ink)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("A few lines, in your own words. Health, people, work, place, how the days feel.")
                            .font(Self.font).foregroundStyle(Palette.inkSecondary)
                            .padding(.leading, Self.editorInset).allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Vision")
        }
        // The editor draws its text this far inside its own edge; pulling it
        // out by the same amount puts the text on the card's edge.
        .padding(.horizontal, -Self.editorInset)
        .onAppear {
            text = visions.first?.text ?? ""
            loaded = true
            editing = true
        }
        .onChange(of: text) { _, new in
            if loaded { try? CompassStore(context: context).saveVision(new) }
        }
        // Claude can edit the vision while this is open; take its text unless
        // they're typing, so their next keystroke doesn't save over it.
        .onChange(of: visions.first?.updatedAt) {
            guard !editing, let stored = visions.first?.text, stored != text else { return }
            text = stored
        }
    }

    /// A string set like the editor's text, to measure how tall it is.
    private func sizingCopy(_ string: String) -> some View {
        Text(string)
            .font(Self.font)
            .padding(.horizontal, Self.editorInset)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// The card's vision type, so the words stay put when editing starts.
    static var font: Font { Typeface.heading.italic() }

    /// How far inside its own edge `TextEditor` draws its text. It's AppKit's
    /// fixed text padding, so it doesn't grow with the Settings text size.
    private static let editorInset: CGFloat = 5
}
