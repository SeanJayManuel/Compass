// Renders the bundled app icon from App/Design/IconArt.swift: the mark and
// accent chosen in Settings (the `<bundle ID>.dock` domain the app shares
// with the Dock tile plug-in), or Steps in cobalt when nothing is chosen.
// The install command runs it before building, so the Dock shows their choice
// even after Compass quits, now that macOS no longer loads the plug-in for an
// app that isn't notarized.
//
//   xcrun swiftc App/Design/IconArt.swift App/Design/Theme.swift scripts/export-icon/main.swift -o build/export-icon
//   build/export-icon App/Assets.xcassets/AppIcon.appiconset [com.seanjaymanuel.Compass]
import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
var mark = AppMark.bundled
var accent = NSColor(hex: AccentTheme.cobalt.light)
if CommandLine.arguments.count > 2, let chosen = UserDefaults(suiteName: CommandLine.arguments[2] + ".dock"),
    let saved = chosen.string(forKey: "mark").flatMap(AppMark.init(rawValue:)), chosen.object(forKey: "accent") != nil
{
    mark = saved
    accent = NSColor(hex: UInt32(truncatingIfNeeded: chosen.integer(forKey: "accent")))
}
for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    try IconArt.png(accent: accent, mark: mark, pixels: pixels)!
        .write(to: folder.appending(path: "icon-\(pixels).png"))
}
print("Wrote 7 icon sizes (\(mark.rawValue)) to \(folder.path)")
