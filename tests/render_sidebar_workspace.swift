// Offscreen visual QA. Does not order a window or control another application.
import AppKit

@main
struct SidebarWorkspacePreview {
    static func main() throws {
        _ = NSApplication.shared
        let outputDirectory = CommandLine.arguments[1]
        try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
        for width in [360, 480, 720] {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let view = iTermSidebarWorkspaceView(frame: NSRect(x: 0, y: 0, width: width, height: 800))
                view.appearance = NSAppearance(named: appearance)
                view.layoutSubtreeIfNeeded()
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                }
                let data = bitmap.representation(using: .png, properties: [:])!
                try data.write(to: URL(fileURLWithPath: outputDirectory).appendingPathComponent("sidebar-\(width)-\(name).png"))
            }
        }
    }
}
