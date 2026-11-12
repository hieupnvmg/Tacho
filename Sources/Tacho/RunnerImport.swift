import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The state of the "add a runner" sheet: the frames picked so far, the
/// name and the colour mode, and what is wrong if the runner cannot be added.
@MainActor
final class RunnerImportModel: ObservableObject {
    @Published var showing = false
    @Published var name = ""
    @Published var isTemplate = true
    @Published private(set) var frames: [CGImage] = []
    @Published var problem: String?

    func begin() {
        name = ""
        isTemplate = true
        frames = []
        problem = nil
        showing = true
    }

    /// Asks for PNG frames. Picked together, they are taken in file name
    /// order, so frame-1.png comes before frame-2.png and frame-10.png.
    func pickFrames() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = L("Chọn các khung hình PNG, cao 36 pixel")
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    func add(_ urls: [URL]) {
        let sorted = urls.filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        problem = nil
        for url in sorted {
            guard frames.count < RunnerLibrary.maxFrames else {
                problem = L("Tối đa %d khung hình.", RunnerLibrary.maxFrames)
                return
            }
            guard let image = NSImage(contentsOf: url),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  cgImage.height == RunnerLibrary.frameHeight,
                  RunnerLibrary.frameWidths.contains(cgImage.width) else {
                problem = L("%@ không dùng được: khung hình phải là PNG cao 36 pixel, rộng 10–100 pixel.",
                            url.lastPathComponent)
                continue
            }
            frames.append(cgImage)
        }
        if name.isEmpty, let first = sorted.first {
            // "cat-frame-0.png" → "cat"; a folder name says it better if any.
            let folder = first.deletingLastPathComponent().lastPathComponent
            let stem = first.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: #"[-_ ]?(frame)?[-_ ]?\d+$"#, with: "", options: .regularExpression)
            name = stem.isEmpty ? folder : stem
        }
    }

    func remove(at index: Int) {
        guard frames.indices.contains(index) else { return }
        frames.remove(at: index)
    }

    var nameTaken: Bool { RunnerLibrary.shared.nameIsTaken(name) }

    var canAdd: Bool {
        !frames.isEmpty && !name.trimmingCharacters(in: .whitespaces).isEmpty && !nameTaken
    }

    /// Saves the runner and returns its id, or nil after saying what failed.
    func save() -> String? {
        do {
            let runner = try RunnerLibrary.shared.add(name: name, isTemplate: isTemplate, frames: frames)
            showing = false
            return runner.id
        } catch {
            problem = L("Không lưu được: %@", error.localizedDescription)
            return nil
        }
    }
}

/// The sheet for adding a runner: frames from PNG files, picked or dropped,
/// a live preview, a name and the colour mode.
struct RunnerImportView: View {
    @ObservedObject var model: RunnerImportModel
    var onAdded: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Thêm hình chạy")).font(.headline)

            HStack(alignment: .top, spacing: 14) {
                preview
                VStack(alignment: .leading, spacing: 8) {
                    TextField(L("Tên"), text: $model.name)
                    if model.nameTaken {
                        Text(L("Tên này đã có.")).font(.system(size: 10)).foregroundStyle(Palette.critical)
                    }
                    Picker(L("Màu"), selection: $model.isTemplate) {
                        Text(L("Đơn sắc")).tag(true)
                        Text(L("Màu gốc")).tag(false)
                    }
                    .pickerStyle(.segmented)
                    Text(model.isTemplate
                         ? L("Tô theo màu chữ của menu bar, như các biểu tượng hệ thống.")
                         : L("Giữ nguyên màu của ảnh."))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            frameStrip

            if let problem = model.problem {
                Text(problem).font(.system(size: 10)).foregroundStyle(Palette.critical)
            }

            HStack {
                Link(L("Tìm thêm ở Runner Gallery"), destination: URL(string: "https://runcat-dev.github.io/RunnerGallery/")!)
                    .font(.system(size: 11))
                Spacer()
                Button(L("Huỷ")) { model.showing = false }
                    .keyboardShortcut(.cancelAction)
                Button(L("Thêm")) {
                    if let id = model.save() { onAdded(id) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canAdd)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    /// The frames playing at an even pace, on a menu bar–like strip.
    private var preview: some View {
        TimelineView(.periodic(from: .now, by: 0.15)) { context in
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12))
                if model.frames.isEmpty {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                } else {
                    let index = Int(context.date.timeIntervalSinceReferenceDate / 0.15) % model.frames.count
                    frameImage(model.frames[index])
                }
            }
            .frame(width: 120, height: 72)
        }
    }

    private func frameImage(_ frame: CGImage) -> some View {
        let image = Image(decorative: frame, scale: 2)
        return Group {
            if model.isTemplate {
                image.renderingMode(.template).foregroundStyle(.primary)
            } else {
                image
            }
        }
    }

    /// Every frame in order, each removable, with room to add or drop more.
    private var frameStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("Khung hình (%d/%d)", model.frames.count, RunnerLibrary.maxFrames))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button(L("Chọn ảnh…")) { model.pickFrames() }
            }
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 6) {
                    ForEach(Array(model.frames.enumerated()), id: \.offset) { index, frame in
                        ZStack(alignment: .topTrailing) {
                            frameImage(frame)
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
                            Button { model.remove(at: index) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .offset(x: 4, y: -4)
                        }
                    }
                    if model.frames.isEmpty {
                        Text(L("Kéo thả các file PNG vào đây, hoặc bấm Chọn ảnh…"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(height: 58)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.3),
                                                                       style: StrokeStyle(lineWidth: 1, dash: [4])))
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                load(providers)
                return true
            }
        }
    }

    private func load(_ providers: [NSItemProvider]) {
        var urls: [URL] = []
        let group = DispatchGroup()
        let lock = NSLock()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [model] in
            MainActor.assumeIsolated { model.add(urls) }
        }
    }
}
