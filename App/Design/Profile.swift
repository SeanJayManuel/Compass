import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Who Compass belongs to: the name it greets and the avatar beside it in
/// the sidebar, both set in Settings.
enum Profile {
    static let nameKey = "profile.name"
    static let defaultName = "You"
    /// The avatar photo: a square JPEG of `photoPixels` a side.
    static let photoKey = "profile.photo"
    nonisolated static let photoPixels = 256

    static var name: String { name(from: UserDefaults.standard.string(forKey: nameKey)) }

    static func name(from stored: String?) -> String {
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultName : trimmed
    }

    /// The letter on the avatar when there's no photo.
    static func initial(of name: String) -> String {
        name.first.map { String($0).uppercased() } ?? "?"
    }

    /// The decoded photo, kept until the stored bytes change.
    static func photo(from data: Data) -> NSImage? {
        if let cached = photoCache, cached.data == data { return cached.image }
        let image = NSImage(data: data)
        photoCache = image.map { (data, $0) }
        return image
    }

    nonisolated(unsafe) private static var photoCache: (data: Data, image: NSImage)?

    /// A picked image file as the stored avatar: centre-cropped square,
    /// downscaled to 256 px, JPEG. JPEG has no transparency, so a
    /// transparent image (a Memoji sticker, say) sits on warm white rather
    /// than black. Safe off the main thread.
    nonisolated static func avatarData(from url: URL) -> Data? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return nil }
        // Read at a little over the final size so the crop keeps detail.
        let thumbnail =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: photoPixels * 3
            ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail) else { return nil }
        let side = min(image.width, image.height)
        let crop = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
        guard let square = image.cropping(to: crop),
            let context = CGContext(
                data: nil, width: photoPixels, height: photoPixels, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: photoPixels, height: photoPixels)
        // The light canvas, 0xF7F5F0.
        context.setFillColor(CGColor(srgbRed: 0xF7 / 255, green: 0xF5 / 255, blue: 0xF0 / 255, alpha: 1))
        context.fill(bounds)
        context.interpolationQuality = .high
        context.draw(square, in: bounds)
        guard let scaled = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
