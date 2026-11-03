import SwiftUI
import AppKit

/// Renders the promotional images in `docs/images` from the live interface:
/// `Tacho --promo docs/images`. Identifying values (IP addresses, VPN
/// interface, drive serial) are replaced first, since these get published.
@MainActor
enum PromoRenderer {

    static func run(directory: String) {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let store = AppEnvironment.store
        // Enough samples for the graphs to have shape, and the process lists
        // the CPU and memory popovers show.
        store.popoverModule = .cpu
        RunLoop.main.run(until: Date().addingTimeInterval(8))
        store.redactForScreenshots()

        let saved = L10n.current
        L10n.current = .vi
        defer { L10n.current = saved }

        save(hero(), "hero", to: folder)
        save(window(section: .cpu, content: CPUView(), scheme: .dark), "window-cpu", to: folder)
        save(window(section: .battery, content: BatteryView(), scheme: .dark), "window-battery", to: folder)
        save(window(section: .overview, content: OverviewView(), scheme: .light), "window-overview", to: folder)
        save(popoverRow([.network, .disk, .connectivity]), "popovers", to: folder)
        save(languages(), "languages", to: folder)
        print("Đã ghi ảnh vào \(folder.path)")
    }

    // MARK: Compositions

    private static func hero() -> some View {
        Backdrop {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .bottom, spacing: 18) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 112, height: 112)
                        .padding(-12)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tacho")
                            .font(.system(size: 64, weight: .heavy, design: .rounded))
                        Text("Đồng hồ đo cho chiếc Mac của bạn — ngay trên menu bar.")
                            .font(.system(size: 21, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        chips(["CPU", "Nhiệt độ", "Quạt", "GPU"])
                        chips(["RAM", "Ổ đĩa", "Mạng", "Pin"])
                    }
                }
                menuBar
                HStack(alignment: .top, spacing: 22) {
                    card(popover(.cpu))
                    card(popover(.battery))
                    card(popover(.memory))
                }
            }
        }
    }

    private static func popoverRow(_ modules: [MenuBarModule]) -> some View {
        Backdrop {
            HStack(alignment: .top, spacing: 22) {
                ForEach(modules) { card(popover($0)) }
            }
        }
    }

    private static func languages() -> some View {
        let images = Language.allCases.map { language -> (Language, NSImage?) in
            L10n.current = language
            return (language, popover(.cpu))
        }
        L10n.current = .vi
        return Backdrop {
            HStack(alignment: .top, spacing: 22) {
                ForEach(images, id: \.0) { language, image in
                    VStack(spacing: 14) {
                        Text(language.nativeName)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                            .background(.white.opacity(0.12), in: Capsule())
                        card(image)
                    }
                }
            }
        }
    }

    /// A tab of the main window inside drawn window chrome. The real window
    /// uses NavigationSplitView, which ImageRenderer cannot draw.
    private static func window<Content: View>(section: MonitorSection, content: Content,
                                              scheme: ColorScheme) -> some View {
        let store = AppEnvironment.store
        let settings = AppEnvironment.settings
        let body = image(content.environmentObject(store).environmentObject(settings)
                            .padding(18)
                            .frame(width: 860)
                            .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.965)),
                         scheme: scheme)
        let dark = scheme == .dark
        return Backdrop(light: !dark) {
            VStack(spacing: 0) {
                ZStack {
                    HStack(spacing: 8) {
                        ForEach([Color(red: 1, green: 0.37, blue: 0.34),
                                 Color(red: 1, green: 0.74, blue: 0.18),
                                 Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) {
                            Circle().fill($0).frame(width: 12, height: 12)
                        }
                        Spacer()
                    }
                    Text(section.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(dark ? .white.opacity(0.85) : .black.opacity(0.8))
                }
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(dark ? Color(white: 0.17) : Color(white: 0.92))

                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(MonitorSection.allCases) { item in
                            Label(item.title, systemImage: item.icon)
                                .font(.system(size: 13))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(item == section ? Palette.cpu.opacity(dark ? 0.35 : 0.2) : .clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                        }
                        Spacer()
                    }
                    .padding(10)
                    .frame(width: 190)
                    .frame(maxHeight: .infinity)
                    .background(dark ? Color(white: 0.145) : Color(white: 0.94))
                    .foregroundStyle(dark ? .white.opacity(0.85) : .black.opacity(0.8))

                    if let body {
                        Image(nsImage: body)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .background(dark ? Color(white: 0.12) : Color(white: 0.965))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(dark ? .white.opacity(0.12) : .black.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
        }
    }

    // MARK: Pieces

    private static var menuBar: some View {
        HStack(spacing: 0) {
            Image(systemName: "applelogo").font(.system(size: 15)).padding(.trailing, 18)
            Text("Finder").font(.system(size: 14, weight: .bold)).padding(.trailing, 16)
            ForEach(["File", "Edit", "View", "Go"], id: \.self) {
                Text($0).font(.system(size: 14)).padding(.trailing, 16)
            }
            Spacer()
            if let strip = menuBarStrip() { Image(nsImage: strip) }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private static func chips(_ titles: [String]) -> some View {
        HStack(spacing: 8) {
            ForEach(titles, id: \.self) { title in
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.12), in: Capsule())
            }
        }
    }

    private static func card(_ image: NSImage?) -> some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(.white.opacity(0.1), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
            }
        }
    }

    private static func popover(_ module: MenuBarModule) -> NSImage? {
        image(MenuBarPopover(module: module)
                .environmentObject(AppEnvironment.store)
                .environmentObject(AppEnvironment.settings)
                .environmentObject(AppEnvironment.updater)
                .background(Color(white: 0.13)),
              scheme: .dark)
    }

    /// The real menu bar readouts are AppKit views; drawn here on a clear
    /// background so they sit on the drawn menu bar.
    private static func menuBarStrip() -> NSImage? {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 24))
        container.appearance = NSAppearance(named: .darkAqua)
        var x: CGFloat = 0
        for module in [MenuBarModule.cpu, .memory, .network, .disk, .connectivity, .battery] {
            let view = StatusItemView(module: module, store: AppEnvironment.store)
            let width = view.preferredWidth
            view.frame = NSRect(x: x, y: 1, width: width, height: 22)
            container.addSubview(view)
            x += width + 10
        }
        container.frame.size.width = x
        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return nil }
        container.cacheDisplay(in: container.bounds, to: rep)
        let image = NSImage(size: container.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: Rendering

    private static func image<V: View>(_ view: V, scheme: ColorScheme) -> NSImage? {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
        renderer.scale = 2
        return renderer.nsImage
    }

    private static func save<V: View>(_ view: V, _ name: String, to folder: URL) {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: folder.appendingPathComponent("\(name).png"))
    }
}

/// The deep blue-violet gradient every promo image sits on, or a pale one.
private struct Backdrop<Content: View>: View {
    var light = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(48)
            .foregroundStyle(light ? Color.black : Color.white)
            .background(
                LinearGradient(colors: light
                                ? [Color(red: 0.86, green: 0.9, blue: 0.98), Color(red: 0.93, green: 0.88, blue: 0.98)]
                                : [Color(red: 0.05, green: 0.07, blue: 0.16),
                                   Color(red: 0.12, green: 0.14, blue: 0.34),
                                   Color(red: 0.24, green: 0.12, blue: 0.36)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
    }
}
