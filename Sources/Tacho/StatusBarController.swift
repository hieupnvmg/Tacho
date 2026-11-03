import AppKit
import SwiftUI
import Combine

/// Owns one `NSStatusItem` per enabled module and keeps them redrawn.
@MainActor
final class StatusBarController: NSObject {

    private let store: MonitorStore
    private let settings: MenuBarSettings
    private let updater: Updater

    private var items: [MenuBarModule: NSStatusItem] = [:]
    private var views: [MenuBarModule: StatusItemView] = [:]
    /// Used instead of `items` while the compact setting is on.
    private var compactItem: NSStatusItem?
    private var compactView: CompactStatusView?
    private var popover = NSPopover()
    private var openModule: MenuBarModule?
    /// A transient popover closes on mouse-down, before the status button's
    /// action fires on mouse-up. Remembering what just closed lets a click on
    /// the same item act as "close" instead of opening it again.
    private var lastClosed: (module: MenuBarModule, time: Date)?
    private var cancellables: Set<AnyCancellable> = []

    init(store: MonitorStore, settings: MenuBarSettings, updater: Updater) {
        self.store = store
        self.settings = settings
        self.updater = updater
        super.init()

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        settings.$enabled
            .receive(on: RunLoop.main)
            .sink { [weak self] modules in self?.sync(to: modules) }
            .store(in: &cancellables)

        settings.$compact
            .dropFirst()
            .receive(on: RunLoop.main)
            // @Published fires before the new value is stored.
            .sink { [weak self] _ in
                DispatchQueue.main.async { self.map { $0.sync(to: $0.settings.enabled) } }
            }
            .store(in: &cancellables)

        settings.$showGraphs
            .receive(on: RunLoop.main)
            .sink { [weak self] show in
                self?.views.values.forEach { $0.showGraph = show }
                self?.compactView?.showGraph = show
                self?.refresh()
            }
            .store(in: &cancellables)

        settings.$language
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.relabel() }
            .store(in: &cancellables)

        settings.$checkConnectivity
            .receive(on: RunLoop.main)
            .sink { [weak store] enabled in store?.setConnectivityEnabled(enabled) }
            .store(in: &cancellables)

        store.onEachSample { [weak self] in self?.refresh() }
        sync(to: settings.enabled)
    }

    // MARK: Status items

    private func sync(to modules: Set<MenuBarModule>) {
        if popover.isShown { popover.performClose(nil) }
        let ordered = MenuBarModule.allCases.filter(modules.contains)

        if settings.compact && !ordered.isEmpty {
            for item in items.values { NSStatusBar.system.removeStatusItem(item) }
            items = [:]
            views = [:]
            if compactItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                let view = CompactStatusView(store: store)
                view.showGraph = settings.showGraphs
                if let button = item.button {
                    view.frame = button.bounds
                    view.autoresizingMask = [.width, .height]
                    button.addSubview(view)
                    button.target = self
                    button.action = #selector(statusItemClicked(_:))
                    button.toolTip = "Tacho"
                }
                compactItem = item
                compactView = view
            }
            compactView?.modules = ordered
            refresh()
            return
        }

        if let item = compactItem {
            // Rebuilt below from scratch, in order.
            NSStatusBar.system.removeStatusItem(item)
            compactItem = nil
            compactView = nil
        }

        for module in items.keys where !modules.contains(module) {
            if let item = items[module] {
                NSStatusBar.system.removeStatusItem(item)
            }
            items[module] = nil
            views[module] = nil
        }

        // Rebuilt in declaration order so the menu bar layout stays stable.
        for module in MenuBarModule.allCases where modules.contains(module) {
            guard items[module] == nil else { continue }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let view = StatusItemView(module: module, store: store)
            view.showGraph = settings.showGraphs

            if let button = item.button {
                view.frame = button.bounds
                view.autoresizingMask = [.width, .height]
                button.addSubview(view)
                button.target = self
                button.action = #selector(statusItemClicked(_:))
                button.toolTip = module.title
            }

            items[module] = item
            views[module] = view
        }
        refresh()
    }

    /// Redraws every readout and resizes the ones whose text grew or shrank.
    private func refresh() {
        for module in views.keys { render(module) }
        if let item = compactItem, let view = compactView {
            let width = view.preferredWidth
            if abs(item.length - width) > 0.5 {
                item.length = width
                view.invalidateDrawing()
            }
            view.redrawIfChanged()
        }
    }

    /// Redraws one item, but only when what it shows has changed. The view
    /// stays a live subview rather than a pre-drawn image: macOS redraws it
    /// separately for each display's menu bar, which can differ between light
    /// and dark, so an image would show the wrong colours on one of them.
    private func render(_ module: MenuBarModule) {
        guard let view = views[module], let item = items[module] else { return }
        let width = view.preferredWidth
        if abs(item.length - width) > 0.5 {
            item.length = width
            view.invalidateDrawing()
        }
        view.redrawIfChanged()
    }

    /// Tooltips are set once per item, and an open popover would keep the
    /// old language until reopened, so both are refreshed here.
    private func relabel() {
        // @Published fires before the new value is stored; wait for didSet.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for (module, item) in self.items { item.button?.toolTip = module.title }
            // Column widths depend on the translated labels.
            if let view = self.compactView { view.modules = view.modules }
            self.refresh()
            if self.popover.isShown { self.popover.performClose(nil) }
        }
    }

    // MARK: Popover

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        // In compact mode the column under the pointer says which panel to open.
        var anchor = sender.bounds
        let module: MenuBarModule
        if let view = compactView, compactItem?.button === sender {
            let x = Self.pointerX(in: sender)
            guard let hit = view.module(atX: x),
                  let column = view.columns.first(where: { $0.module == hit }) else { return }
            module = hit
            anchor = NSRect(x: column.frame.minX, y: 0, width: column.frame.width, height: sender.bounds.height)
        } else if let hit = views.first(where: { $0.value.isDescendant(of: sender) })?.key {
            module = hit
        } else {
            return
        }

        // Clicking the open item closes it; clicking another switches to it.
        if popover.isShown {
            let wasOpen = openModule == module
            popover.performClose(nil)
            if wasOpen { return }
        } else if let closed = lastClosed, closed.module == module,
                  Date().timeIntervalSince(closed.time) < 0.3 {
            lastClosed = nil
            return
        }

        // Opening the connectivity panel is a good moment to re-check, rather
        // than showing a reading up to a minute old.
        if module == .connectivity {
            store.connectivityMonitor.refreshIfStale()
        }

        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopover(module: module)
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(updater))
        // Without activating first, a transient popover from an inactive app can
        // be dismissed by the very click that opened it.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: anchor, of: sender, preferredEdge: .minY)
        openModule = module
        store.popoverModule = module
        popover.contentViewController?.view.window?.makeKey()
    }
}

extension StatusBarController {
    /// Where across the item the pointer is. The click event itself cannot be
    /// trusted for this: macOS draws status items in every display's menu bar
    /// and forwards clicks to the real one as if they landed in its middle.
    /// The pointer's screen position is real, and so is the item's place on
    /// the display under it, since the menu bar is the same on each display.
    static func pointerX(in button: NSStatusBarButton) -> CGFloat {
        let mouse = NSEvent.mouseLocation
        let eventX = button.convert(NSApp.currentEvent?.locationInWindow ?? .zero, from: nil).x
        guard let window = button.window else { return eventX }
        let buttonInWindow = button.convert(button.bounds, to: nil)
        // The item's left edge measured from its own screen's right edge holds
        // on every display's menu bar; status items are laid out from the right.
        let fromRight = (window.screen?.frame.maxX ?? 0) - (window.frame.minX + buttonInWindow.minX)
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        var x = eventX
        if let screen {
            let left = screen.frame.maxX - fromRight
            let candidate = mouse.x - left
            if candidate >= 0 && candidate <= button.bounds.width { x = candidate }
        }
        return x
    }
}

extension StatusBarController: NSPopoverDelegate {
    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Switching items closes and reopens the popover; a late close
            // notification must not clear the newly opened one.
            guard !popover.isShown else { return }
            if let module = openModule {
                lastClosed = (module, Date())
            }
            openModule = nil
            store.popoverModule = nil
        }
    }
}
