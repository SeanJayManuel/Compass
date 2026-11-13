import AppKit
import os

/// Loaded by the Dock for a Compass kept in the Dock, running or not, so the
/// tile shows the mark and accent chosen in Settings instead of the bundled
/// icon. While Compass runs, its own `applicationIconImage` covers this.
/// The Dock calls in on its main thread.
@objc(CompassDockTile) @MainActor
final class CompassDockTile: NSObject, @preconcurrency NSDockTilePlugIn {
    private static let log = Logger(subsystem: "com.seanjaymanuel.Compass.docktile", category: "tile")
    private var dockTile: NSDockTile?
    private var observer: NSObjectProtocol?
    /// The app this plug-in ships in: its own ID without ".docktile".
    private let appID = (Bundle(for: CompassDockTile.self).bundleIdentifier ?? "com.seanjaymanuel.Compass.docktile")
        .replacingOccurrences(of: ".docktile", with: "")

    func setDockTile(_ dockTile: NSDockTile?) {
        self.dockTile = dockTile
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        guard dockTile != nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: DockTileShare.changed(appID: appID), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.redraw() }
        }
        redraw()
    }

    private func redraw() {
        guard let dockTile else { return }
        // Nothing saved yet: leave the bundled icon.
        guard let choice = DockTileShare.load(appID: appID) else {
            Self.log.info("No saved choice; showing the bundled icon")
            dockTile.contentView = nil
            dockTile.display()
            return
        }
        Self.log.info("Drawing \(choice.mark.rawValue, privacy: .public)")
        let size = dockTile.size
        let view = NSImageView(frame: NSRect(origin: .zero, size: size))
        view.imageScaling = .scaleProportionallyUpOrDown
        view.image = IconArt.image(accent: NSColor(hex: choice.accent), mark: choice.mark, size: 1024)
        dockTile.contentView = view
        dockTile.display()
    }
}
