import AppKit
import Combine
import SwiftUI

// MARK: - Model

struct Container: Identifiable, Equatable {
    let id: String
    let name: String
    let image: String
    let state: String
    let status: String

    var isRunning: Bool { state == "running" }
}

struct KubeContext: Identifiable, Equatable {
    let name: String
    let cluster: String
    let namespace: String?

    var id: String { name }

    /// Names that say production, where a stray command does real damage.
    var isProduction: Bool {
        let text = (name + " " + cluster).lowercased()
        return ["prod", "prd"].contains { text.contains($0) }
    }
}

struct InfraState: Equatable {
    /// Nil while Docker is not running or not installed.
    var containers: [Container]?
    /// Memory given to Docker's virtual machine, from the engine.
    var vmMemory: UInt64?
    /// Memory each running container uses, by id; read while the panel is open.
    var containerMemory: [String: UInt64] = [:]
    var kubeCurrent: KubeContext?
    var kubeContexts: [KubeContext] = []

    var running: [Container] { containers?.filter(\.isRunning) ?? [] }
}

// MARK: - Docker

/// Asks the Docker engine directly over its Unix socket, the way the
/// `docker` command does, so neither the CLI nor a shell is needed. Docker
/// Desktop, OrbStack, Colima and Rancher Desktop each put the socket
/// somewhere else; the first that answers is used.
enum DockerSocket {
    static var candidates: [String] {
        let home = userHome.path
        return [home + "/.docker/run/docker.sock", "/var/run/docker.sock", home + "/.orbstack/run/docker.sock",
                home + "/.colima/default/docker.sock", home + "/.rd/docker.sock"]
    }

    /// Every container, running or not; nil when no engine answers.
    static func containers() -> [Container]? {
        guard let body = get("/containers/json?all=1"),
              let list = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] else { return nil }
        return list.map { entry in
            let name = ((entry["Names"] as? [String])?.first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return Container(id: entry["Id"] as? String ?? name, name: name, image: entry["Image"] as? String ?? "",
                             state: entry["State"] as? String ?? "", status: entry["Status"] as? String ?? "")
        }
    }

    /// Memory of Docker's virtual machine, from the engine's info.
    static func vmMemory() -> UInt64? {
        guard let body = get("/info"),
              let info = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return (info["MemTotal"] as? NSNumber)?.uint64Value
    }

    /// Memory a container uses now, page cache left out as `docker stats`
    /// does. One-shot, so it answers at once instead of sampling.
    static func memory(of id: String) -> UInt64? {
        guard let body = get("/containers/\(id)/stats?stream=false&one-shot=true"),
              let stats = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let memory = stats["memory_stats"] as? [String: Any],
              let usage = (memory["usage"] as? NSNumber)?.uint64Value else { return nil }
        let details = memory["stats"] as? [String: Any]
        let cache = ((details?["inactive_file"] ?? details?["cache"]) as? NSNumber)?.uint64Value ?? 0
        return usage > cache ? usage - cache : usage
    }

    /// `docker start` / `docker stop` for one container.
    @discardableResult
    static func setRunning(_ running: Bool, id: String) -> Bool {
        post("/containers/\(id)/\(running ? "start" : "stop?t=10")") != nil
    }

    private static func get(_ path: String) -> Data? { send("GET", path) }
    private static func post(_ path: String) -> Data? { send("POST", path) }

    private static func send(_ method: String, _ path: String) -> Data? {
        for socketPath in candidates where FileManager.default.fileExists(atPath: socketPath) {
            if let body = request(method, path, socket: socketPath) { return body }
        }
        return nil
    }

    private static func request(_ method: String, _ path: String, socket socketPath: String) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        // An engine that is starting up or stuck must not hold things up;
        // stopping a container may take its full grace period.
        var timeout = timeval(tv_sec: method == "POST" ? 15 : 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in pathBytes.enumerated() { buffer[index] = UInt8(bitPattern: byte) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        // HTTP/1.0, so the engine sends the body whole and closes.
        let request = Array("\(method) \(path) HTTP/1.0\r\nHost: docker\r\nContent-Length: 0\r\n\r\n".utf8)
        guard request.withUnsafeBytes({ write(fd, $0.baseAddress, request.count) }) == request.count else { return nil }
        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { break }
            response.append(chunk, count: count)
            if response.count > 8_000_000 { break }
        }
        guard let split = response.range(of: Data("\r\n\r\n".utf8)),
              let statusLine = String(data: response[..<split.lowerBound], encoding: .utf8)?
                  .split(separator: "\r\n").first,
              // 204: started or stopped; 304: it already was.
              [" 200 ", " 204 ", " 304 "].contains(where: { statusLine.contains($0) }) else { return nil }
        return response[split.upperBound...]
    }
}

// MARK: - Docker engine

/// Starting and stopping the Docker engine: the app that runs it, opened or
/// quit as if from the Dock. Docker Desktop and OrbStack are covered.
enum DockerEngine {
    static let apps = ["com.docker.docker", "dev.kdrag0n.MacVirt"]

    static var installedApp: URL? {
        apps.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    static var runningApp: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { apps.contains($0.bundleIdentifier ?? "") }
    }

    static var name: String {
        installedApp.map { $0.deletingPathExtension().lastPathComponent } ?? "Docker"
    }

    static func start() {
        guard let url = installedApp else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    static func stop() {
        runningApp?.terminate()
    }
}

// MARK: - Kubernetes

/// The current context of ~/.kube/config, read with just enough YAML to
/// find the contexts list. GUI apps do not see the shell's KUBECONFIG, so
/// the default file is the one used.
enum KubeConfig {
    static var url: URL { userHome.appendingPathComponent(".kube/config") }

    static func read() -> (current: KubeContext?, all: [KubeContext]) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (nil, []) }
        var currentName: String?
        var contexts: [KubeContext] = []
        var inContexts = false
        var entry: [String: String] = [:]

        func flush() {
            if let name = entry["name"] {
                contexts.append(KubeContext(name: name, cluster: entry["cluster"] ?? "", namespace: entry["namespace"]))
            }
            entry = [:]
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }
            let topLevel = !line.hasPrefix(" ") && !line.hasPrefix("-") && !line.isEmpty
            if topLevel {
                if inContexts { flush() }
                inContexts = line.hasPrefix("contexts:")
                if line.hasPrefix("current-context:") { currentName = value(of: line) }
                continue
            }
            guard inContexts else { continue }
            var content = line.trimmingCharacters(in: .whitespaces)
            if content.hasPrefix("- ") {
                flush()
                content = String(content.dropFirst(2))
            }
            for key in ["name", "cluster", "namespace"] where content.hasPrefix(key + ":") {
                entry[key] = value(of: content)
            }
        }
        if inContexts { flush() }
        let current = currentName.flatMap { name in contexts.first { $0.name == name } ?? KubeContext(name: name, cluster: "", namespace: nil) }
        return (current, contexts)
    }

    private static func value(of line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
}

// MARK: - Watcher

@MainActor
final class InfraWatcher: ObservableObject {
    static let shared = InfraWatcher()

    @Published private(set) var state = InfraState()
    /// A start or stop under way, by container id, or "engine".
    @Published private(set) var pending: Set<String> = []
    /// While the panel is open, memory is read too.
    var detailed = false
    private var timer: Timer?
    private var busy = false

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Tolerance lets macOS fold this wakeup in with others.
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !busy else { return }
        busy = true
        let detailed = self.detailed
        DispatchQueue.global(qos: .utility).async {
            let containers = DockerSocket.containers()
            var vm: UInt64?
            var memory: [String: UInt64] = [:]
            if detailed, let containers {
                vm = DockerSocket.vmMemory()
                for container in containers where container.isRunning {
                    memory[container.id] = DockerSocket.memory(of: container.id)
                }
            }
            let kube = KubeConfig.read()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busy = false
                    var state = InfraState(containers: containers, vmMemory: vm, containerMemory: memory,
                                           kubeCurrent: kube.current, kubeContexts: kube.all)
                    if !detailed {
                        state.vmMemory = self.state.vmMemory
                        state.containerMemory = self.state.containerMemory
                    }
                    if state != self.state { self.state = state }
                }
            }
        }
    }

    func setContainer(_ container: Container, running: Bool) {
        pending.insert(container.id)
        DispatchQueue.global(qos: .userInitiated).async {
            DockerSocket.setRunning(running, id: container.id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.pending.remove(container.id)
                    self.refresh()
                }
            }
        }
    }

    /// Starts or quits the engine's app, then checks every few seconds until
    /// the engine answers or goes away (Docker takes a while to boot).
    func setEngine(running: Bool) {
        pending.insert("engine")
        if running { DockerEngine.start() } else { DockerEngine.stop() }
        var tries = 0
        func check() {
            tries += 1
            DispatchQueue.global(qos: .utility).async {
                let up = DockerSocket.containers() != nil
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if up == running || tries >= 30 {
                            self.pending.remove("engine")
                            self.refresh()
                        } else {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { check() }
                        }
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { check() }
    }
}

// MARK: - Menu bar item

/// Its own menu bar item: running containers and the Kubernetes context,
/// red when that context looks like production.
@MainActor
final class InfraStatusController: NSObject, NSPopoverDelegate {
    private let watcher = InfraWatcher.shared
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var cancellables: Set<AnyCancellable> = []

    init(settings: MenuBarSettings) {
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        settings.$infraItem
            .receive(on: RunLoop.main)
            .sink { [weak self] on in self?.setVisible(on) }
            .store(in: &cancellables)
        watcher.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.render(state) }
            .store(in: &cancellables)
    }

    private func setVisible(_ on: Bool) {
        if on, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(clicked(_:))
            self.item = item
            watcher.start()
            render(watcher.state)
        } else if !on, let item {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
            watcher.stop()
        }
    }

    /// Kept small: two symbols at the menu bar's usual size, the number of running containers while
    /// Docker runs, and the Kubernetes wheel (red for production) with the
    /// context's name in the tooltip.
    private func render(_ state: InfraState) {
        guard let button = item?.button else { return }
        button.attributedTitle = Self.title(for: state)
        let production = state.kubeCurrent?.isProduction == true
        var tip = state.kubeCurrent.map { "Kubernetes: \($0.name)" } ?? ""
        if production { tip += "\n" + L("Context Kubernetes đang trỏ tới production") }
        button.toolTip = tip.isEmpty ? nil : tip
    }

    static func title(for state: InfraState) -> NSAttributedString {
        let production = state.kubeCurrent?.isProduction == true
        let tint: NSColor = production ? .systemRed : .labelColor
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: production ? .bold : .medium)
        let title = NSMutableAttributedString()

        func symbol(_ name: String) {
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)
                    .applying(.init(paletteColors: [tint]))) else { return }
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(x: 0, y: -2.5, width: image.size.width, height: image.size.height)
            title.append(NSAttributedString(attachment: attachment))
        }
        func text(_ string: String) {
            title.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: tint]))
        }

        if let containers = state.containers {
            symbol("shippingbox.fill")
            text("\u{2009}\(containers.filter(\.isRunning).count)")
        }
        if state.kubeCurrent != nil {
            if title.length > 0 { text(" ") }
            // Just the wheel, red for production; the name is in the tooltip.
            symbol("helm")
        }
        if title.length == 0 { symbol("shippingbox") }
        return title
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            watcher.detailed = false
            // Released, so the closed panel stops following the watcher.
            popover.contentViewController = nil
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        watcher.detailed = true
        watcher.refresh()
        popover.contentViewController = NSHostingController(rootView: InfraPopover(watcher: watcher))
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}

// MARK: - Popover

struct InfraPopover: View {
    @ObservedObject var watcher: InfraWatcher

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            kubernetes
            Divider()
            docker
        }
        .padding(14)
        .frame(width: 320)
    }

    @ViewBuilder private var kubernetes: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "helm")
                Text("Kubernetes").font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            if let context = watcher.state.kubeCurrent {
                HStack(spacing: 6) {
                    Text(context.name)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(context.isProduction ? Palette.critical : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if context.isProduction {
                        Text("PRODUCTION")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Palette.critical))
                    }
                }
                if !context.cluster.isEmpty {
                    InfoRow(label: L("Cluster"), value: context.cluster)
                }
                InfoRow(label: L("Namespace"), value: context.namespace ?? "default")
                let others = watcher.state.kubeContexts.filter { $0.name != context.name }
                if !others.isEmpty {
                    Text(L("Context khác: %@", others.map(\.name).joined(separator: ", ")))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } else {
                Text(L("Chưa có context nào trong ~/.kube/config."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var docker: some View {
        let containers = watcher.state.containers
        let engineBusy = watcher.pending.contains("engine")
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox.fill")
                Text("Docker").font(.system(size: 12, weight: .semibold))
                if let containers {
                    Text(L("%d đang chạy / %d", containers.filter(\.isRunning).count, containers.count))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if DockerEngine.installedApp != nil {
                    if engineBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Toggle("", isOn: Binding(get: { containers != nil },
                                                 set: { watcher.setEngine(running: $0) }))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                            .help(containers != nil ? L("Tắt %@", DockerEngine.name) : L("Bật %@", DockerEngine.name))
                    }
                }
            }
            if let containers {
                if let vm = watcher.state.vmMemory {
                    let used = watcher.state.containerMemory.values.reduce(0, +)
                    HStack(spacing: 6) {
                        Image(systemName: "memorychip").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(L("Container dùng %@ / máy ảo %@", Fmt.bytes(used), Fmt.bytes(vm)))
                            .font(.system(size: 11))
                        Spacer()
                    }
                    ProgressView(value: min(Double(used) / Double(max(vm, 1)), 1))
                        .tint(Palette.memory)
                }
                if containers.isEmpty {
                    Text(L("Không có container nào."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(containers.sorted { $0.isRunning && !$1.isRunning }.prefix(12)) { container in
                        containerRow(container)
                    }
                }
            } else {
                Text(engineBusy ? L("Đang chờ Docker…") : L("Docker chưa chạy."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func containerRow(_ container: Container) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(container.isRunning ? Palette.memory : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 0) {
                Text(container.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text(container.image)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let memory = watcher.state.containerMemory[container.id] {
                Text(Fmt.bytes(memory))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else if !container.isRunning {
                Text(container.status)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if watcher.pending.contains(container.id) {
                ProgressView().controlSize(.mini).frame(width: 18)
            } else {
                Button {
                    watcher.setContainer(container, running: !container.isRunning)
                } label: {
                    Image(systemName: container.isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 9))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(container.isRunning ? L("Dừng container") : L("Chạy container"))
            }
        }
    }
}
