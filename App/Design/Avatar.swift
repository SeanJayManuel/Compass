import SwiftUI

/// The owner's avatar: the photo they picked, or their initial on the accent.
struct Avatar: View {
    var size: CGFloat
    @AppStorage(Profile.nameKey) private var storedName = ""
    @AppStorage(Profile.photoKey) private var photo: Data?

    var body: some View {
        Group {
            if let photo, let image = Profile.photo(from: photo) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                // Palette.needle is observed, so a new accent redraws this
                // circle even where Settings keeps the view alive.
                Circle()
                    .fill(Palette.needle)
                    .overlay {
                        Text(Profile.initial(of: Profile.name(from: storedName)))
                            .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                            .foregroundStyle(Palette.onNeedle)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }
}
