import SwiftUI
import UniformTypeIdentifiers

/// The name Compass greets and the avatar in the sidebar.
struct ProfileSettings: View {
    @AppStorage(Profile.nameKey) private var name = ""
    @AppStorage(Profile.photoKey) private var photo: Data?
    @State private var choosingPhoto = false
    @State private var readingPhoto = false
    @State private var photoProblem: String?

    var body: some View {
        let scale = TextSize.current.scale
        Form {
            Section {
                HStack(spacing: Spacing.m) {
                    Avatar(size: 64 * scale)
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        HStack(spacing: Spacing.s) {
                            Button(photo == nil ? "Choose Photo" : "Change Photo") { choosingPhoto = true }
                                .disabled(readingPhoto)
                            if photo != nil {
                                Button("Use Initial") { photo = nil }
                            }
                            if readingPhoto { ProgressView().controlSize(.small) }
                        }
                        SettingsNote(
                            photo == nil
                                ? "Without a photo, the sidebar shows your initial on the accent color."
                                : "Kept small, at 256 pixels, and only on this Mac.")
                    }
                }
                .padding(.vertical, Spacing.xs)
                TextField("Name", text: $name, prompt: Text(Profile.defaultName))
                SettingsNote("Compass greets you by this name and shows it at the bottom of the sidebar.")
                if let photoProblem {
                    SettingsNote(photoProblem, color: Palette.failure)
                }
            } header: {
                SettingsHeader("Profile")
            }
        }
        .settingsPane()
        .fileImporter(isPresented: $choosingPhoto, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { usePhoto(at: url) }
        }
    }

    /// Downscales off the main thread: a camera photo can be 50 MB.
    private func usePhoto(at url: URL) {
        readingPhoto = true
        photoProblem = nil
        Task {
            let data = await Task.detached(priority: .userInitiated) {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                return Profile.avatarData(from: url)
            }.value
            readingPhoto = false
            if let data {
                photo = data
            } else {
                photoProblem = "That file couldn't be read as a photo. Try a JPEG, PNG or HEIC."
            }
        }
    }
}
