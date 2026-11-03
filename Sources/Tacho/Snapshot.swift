import SwiftUI
import AppKit

/// Renders the app's own views to PNG files. Unlike `screencapture` this needs
/// no Screen Recording permission, because the app is drawing itself.
/// Usage: `Tacho --snapshot <thư mục>`
@MainActor
enum SnapshotRenderer {

    static func run(directory: String) {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let store = AppEnvironment.store
        let settings = AppEnvironment.settings

        // `--lang en` renders in another language without changing the saved one.
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--lang"), index + 1 < arguments.count,
           let language = Language(rawValue: arguments[index + 1]) {
            L10n.current = language
        }

        store.setConnectivityEnabled(settings.checkConnectivity)
        // With a test feed, show the update banner as it would appear.
        if ProcessInfo.processInfo.environment["TACHO_UPDATE_FEED"] != nil {
            Task { await AppEnvironment.updater.check() }
        }

        // Let the collectors fill in a few samples so the graphs are not empty,
        // including the process lists the CPU and memory popovers show.
        store.popoverModule = .cpu
        RunLoop.main.run(until: Date().addingTimeInterval(4))

        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .light ? "light" : "dark"
            render(BatteryView().environmentObject(store).environmentObject(settings),
                   width: 880, scheme: scheme, to: folder, name: "battery-\(suffix)")
            render(OverviewView().environmentObject(store).environmentObject(settings),
                   width: 880, scheme: scheme, to: folder, name: "overview-\(suffix)")
            render(CPUView().environmentObject(store).environmentObject(settings),
                   width: 880, scheme: scheme, to: folder, name: "cpu-\(suffix)")
            render(MemoryView().environmentObject(store).environmentObject(settings),
                   width: 880, scheme: scheme, to: folder, name: "memory-\(suffix)")
            render(DiskView().environmentObject(store).environmentObject(settings),
                   width: 880, scheme: scheme, to: folder, name: "disk-\(suffix)")
            render(NetworkView().environmentObject(store).environmentObject(settings),
                   width: 880, scheme: scheme, to: folder, name: "network-\(suffix)")
        }

        for module in MenuBarModule.allCases {
            render(MenuBarPopover(module: module)
                    .environmentObject(store)
                    .environmentObject(settings)
                    .environmentObject(AppEnvironment.updater),
                   width: 290, scheme: .dark, to: folder, name: "popover-\(module.rawValue)")
        }

        for (range, name) in [(HistoryRecorder.Range.hour, "history-hour"), (.day, "history-day")] {
            AppEnvironment.history.range = range
            render(HistoryView().environmentObject(AppEnvironment.history),
                   width: 880, scheme: .dark, to: folder, name: name)
        }
        AppEnvironment.history.range = .hour

        renderMenuBar(store: store, to: folder)
        print("Đã ghi ảnh vào \(folder.path)")
    }

    private static func render<V: View>(_ view: V,
                                        width: CGFloat,
                                        scheme: ColorScheme,
                                        to folder: URL,
                                        name: String) {
        let wrapped = view
            .padding(18)
            .frame(width: width)
            .background(scheme == .light ? Color(white: 0.96) : Color(white: 0.12))
            .environment(\.colorScheme, scheme)

        let renderer = ImageRenderer(content: wrapped)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: folder.appendingPathComponent("\(name).png"))
    }

    /// The menu bar readouts are AppKit views, so they are cached directly.
    private static func renderMenuBar(store: MonitorStore, to folder: URL) {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearanceName == .aqua ? "light" : "dark"
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
            container.appearance = NSAppearance(named: appearanceName)
            container.wantsLayer = true
            container.layer?.backgroundColor = appearanceName == .aqua
                ? NSColor.white.cgColor
                : NSColor(white: 0.13, alpha: 1).cgColor

            var x: CGFloat = 6
            for module in MenuBarModule.allCases {
                let view = StatusItemView(module: module, store: store)
                let width = view.preferredWidth
                view.frame = NSRect(x: x, y: 1, width: width, height: 22)
                container.addSubview(view)
                x += width + 10
            }
            // The compact item after a gap, as the alternative layout.
            x += 30
            let compact = CompactStatusView(store: store)
            compact.modules = MenuBarModule.allCases
            compact.frame = NSRect(x: x, y: 1, width: compact.preferredWidth, height: 22)
            container.addSubview(compact)
            x += compact.preferredWidth + 6
            container.frame.size.width = x

            guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { continue }
            container.cacheDisplay(in: container.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: folder.appendingPathComponent("menubar-\(suffix).png"))
        }
    }
}
