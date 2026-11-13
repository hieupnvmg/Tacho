import SwiftUI

struct SettingsView: View {
    /// Shown as a tab of the main window rather than in its own window.
    var embedded = false

    @EnvironmentObject private var settings: MenuBarSettings
    @EnvironmentObject private var store: MonitorStore
    @EnvironmentObject private var updater: Updater
    @EnvironmentObject private var alerts: AlertMonitor
    @StateObject private var loginItem = LoginItem()
    @StateObject private var runnerImport = RunnerImportModel()
    @ObservedObject private var runners = RunnerLibrary.shared
    @ObservedObject private var meetings = MeetingWatcher.shared
    @ObservedObject private var ai = AIUsageWatcher.shared

    var body: some View {
        Form {
            Section(L("Chung")) {
                Toggle(L("Mở Tacho khi đăng nhập"), isOn: Binding(get: { loginItem.isEnabled },
                                                                  set: { loginItem.set($0) }))
                if loginItem.status == .requiresApproval {
                    HStack {
                        Text(L("macOS cần bạn cho phép trong Cài đặt hệ thống."))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Mở mục Đăng nhập")) { loginItem.openSystemSettings() }
                    }
                }
                if let error = loginItem.error {
                    Text(error).font(.system(size: 10)).foregroundStyle(Palette.critical)
                }
            }

            Section(L("Ngôn ngữ")) {
                Picker(L("Ngôn ngữ"), selection: $settings.language) {
                    ForEach(Language.allCases) { language in
                        Text(language.nativeName).tag(language)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section(L("Hiện trên menu bar")) {
                ForEach(MenuBarModule.allCases) { module in
                    Toggle(isOn: binding(for: module)) {
                        Label(module.title, systemImage: module.icon)
                    }
                }
            }

            Section(L("Hiển thị")) {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(L("Gộp thành một mục gọn"), isOn: $settings.compact)
                    Text(L("Mọi chỉ số nằm chung một mục, mỗi chỉ số một cột hai dòng, đồ thị mờ phía sau. Hợp với MacBook có tai thỏ. Bấm vào cột nào thì mở bảng của cột đó."))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Toggle(L("Vẽ đồ thị trong mục menu bar"), isOn: $settings.showGraphs)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(L("Hình chạy theo CPU"), isOn: $settings.runningCat)
                    Text(L("Một hình động trên menu bar, CPU càng bận thì chạy càng nhanh. Bấm vào để mở bảng CPU. Hình từ RunCat Neo (Apache 2.0)."))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if settings.runningCat {
                    Picker(L("Hình chạy"), selection: $settings.runnerID) {
                        ForEach(runners.all) { runner in
                            // Each option shows its runner, as a still frame.
                            Label {
                                Text(runner.title)
                            } icon: {
                                if let frame = runner.frames.first {
                                    Image(nsImage: frame)
                                }
                            }
                            .tag(runner.id)
                        }
                    }
                    ForEach(runners.custom) { runner in
                        HStack(spacing: 8) {
                            if let frame = runner.frames.first {
                                Image(nsImage: frame)
                            }
                            Text(runner.title)
                            Spacer()
                            Button {
                                if settings.runnerID == runner.id { settings.runnerID = Runner.defaultID }
                                runners.delete(runner)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help(L("Xoá hình chạy này"))
                        }
                    }
                    Button(L("Thêm hình chạy…")) { runnerImport.begin() }
                        .sheet(isPresented: $runnerImport.showing) {
                            RunnerImportView(model: runnerImport) { id in settings.runnerID = id }
                        }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(L("Docker và Kubernetes trên menu bar"), isOn: $settings.infraItem)
                    Text(L("Số container đang chạy và context Kubernetes hiện tại; chuyển đỏ khi context có chữ prod. Đọc thẳng socket Docker và ~/.kube/config, không chạy lệnh nào."))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(L("Kiểm tra kết nối Internet"), isOn: $settings.checkConnectivity)
                    Text(L("Gọi 1.1.1.1 của Cloudflare mỗi 60 giây để biết có Internet và lấy IP ra Internet."))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Toggle(L("Ẩn biểu tượng khỏi Dock"), isOn: $settings.hideDockIcon)
                Picker(L("Tần suất cập nhật"), selection: $store.interval) {
                    Text(L("0,5 giây")).tag(0.5)
                    Text(L("1 giây")).tag(1.0)
                    Text(L("2 giây")).tag(2.0)
                    Text(L("5 giây")).tag(5.0)
                }
            }

            Section(L("Tai thỏ (notch)")) {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(L("Báo sự kiện ở tai thỏ"), isOn: $settings.notchEvents)
                    Text(L("Cắm hoặc rút sạc, pin yếu, kết nối chuột, bàn phím, tai nghe, mất hoặc có mạng lại, cuộc gọi bắt đầu hoặc kết thúc, app ngốn CPU, CPU quá nóng, hết RAM: tai thỏ giãn ra hai bên trong vài giây. Khi đang chia sẻ màn hình trong cuộc gọi, tai thỏ viền đỏ."))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(L("Rê chuột vào tai thỏ để mở bảng điều khiển"), isOn: $settings.notchPeek)
                    Text(L("Bài đang phát với nút điều khiển (YouTube, Spotify, Nhạc…), chọn loa hoặc tai nghe, cuộc gọi đang diễn ra với nút tắt micro, và kệ để thả file tạm."))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(L("Lịch sử clipboard trong tai thỏ"), isOn: $settings.notchClipboard)
                    Text(L("Vuốt ngang trên bảng tai thỏ để xem 20 mục copy gần nhất, bấm để copy lại. Bỏ qua mật khẩu từ trình quản lý mật khẩu."))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if settings.notchClipboard {
                        Toggle(L("Giữ lịch sử khi Tacho khởi động lại"), isOn: $settings.notchClipboardKeep)
                            .font(.system(size: 11))
                        Text(L("Lưu trên máy này (không mã hoá, chỉ tài khoản của bạn đọc được), tự xoá sau 7 ngày. Tắt đi là xoá phần đã lưu."))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(L("Hạn mức Claude Code và Codex trong tai thỏ"), isOn: $settings.notchAI)
                    Text(L("Một trang trong bảng tai thỏ: % hạn mức 5 giờ và 7 ngày, giờ reset, token đã dùng hôm nay; tai thỏ báo khi vượt 80% và 95%. Codex đọc thẳng từ nhật ký phiên. Hạn mức của Claude Code chỉ có khi Tacho làm statusLine của Claude Code."))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if settings.notchAI {
                        switch ai.hookup {
                        case .none:
                            Button(L("Kết nối Claude Code")) { ai.connectClaude() }
                                .help(L("Thêm Tacho làm statusLine trong ~/.claude/settings.json (có sao lưu)."))
                        case .tacho:
                            HStack {
                                Label(L("Đã kết nối Claude Code"), systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(Palette.memory)
                                    .font(.system(size: 11))
                                Button(L("Gỡ")) { ai.disconnectClaude() }
                                    .buttonStyle(.link)
                                    .font(.system(size: 11))
                            }
                            if ai.keepsPreviousStatusLine {
                                Text(L("statusLine cũ của bạn vẫn chạy như trước; gỡ là trả lại nguyên vẹn."))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        case .other:
                            Text(L("Claude Code đã có statusLine khác. Tacho có thể chạy kèm: dòng trạng thái giữ nguyên như cũ, Tacho chỉ lấy hạn mức."))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Button(L("Kết nối, giữ statusLine hiện tại")) { ai.connectClaude(keepingExisting: true) }
                                .help(L("Lưu statusLine hiện tại sang một bên, Tacho chạy nó mỗi lần; bấm Gỡ để trả lại."))
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(L("Nhắc cuộc họp từ Lịch"), isOn: $settings.notchMeetings)
                    Text(L("Báo trước 5 phút và có nút Vào họp. Cuộc họp Teams hiện ở đây khi tài khoản Microsoft 365 đã thêm trong Cài đặt hệ thống → Tài khoản Internet."))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if settings.notchMeetings && meetings.access == .denied {
                        Button(L("Tacho chưa được đọc Lịch. Mở Cài đặt…")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 10))
                    }
                }
                if settings.notchClipboard || settings.notchAI {
                    Picker(L("Khi mở tai thỏ, hiện"), selection: $settings.notchStartPage) {
                        ForEach(NotchPage.allCases.filter { page in
                            page == .main || (page == .clipboard && settings.notchClipboard)
                                || (page == .ai && settings.notchAI)
                        }) { page in
                            Text(page.title).tag(page)
                        }
                    }
                }
                if NotchGeometry.current() == nil {
                    Text(L("Màn hình hiện tại không có tai thỏ, nên chưa thấy gì."))
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.warning)
                }
            }

            Section(L("Cảnh báo khi")) {
                ForEach(AlertKind.allCases) { kind in
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(kind.title, isOn: Binding(get: { alerts.isEnabled(kind) },
                                                         set: { alerts.setEnabled(kind, $0) }))
                        Text(kind.condition)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                if alerts.authorization == .denied {
                    HStack {
                        Label(L("Thông báo của Tacho đang bị tắt trong macOS."),
                              systemImage: "bell.slash")
                            .font(.system(size: 11)).foregroundStyle(Palette.warning)
                        Spacer()
                        Button(L("Mở cài đặt Thông báo")) { Self.openNotificationSettings() }
                    }
                } else {
                    Button(L("Gửi thông báo thử")) { alerts.sendTest() }
                }
            }

            Section(L("Cập nhật")) {
                UpdateSection()
            }
        }
        .formStyle(.grouped)
        .frame(width: embedded ? nil : 400, height: embedded ? nil : 560)
        .frame(maxWidth: embedded ? 640 : nil, maxHeight: .infinity, alignment: .top)
        // Strings are looked up while rendering, so a new identity re-renders
        // every one of them in the new language.
        .id(settings.language)
        .onAppear {
            loginItem.refresh()
            alerts.refreshAuthorization()
        }
    }

    private static func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func binding(for module: MenuBarModule) -> Binding<Bool> {
        Binding(get: { settings.isEnabled(module) },
                set: { settings.setEnabled(module, $0) })
    }
}

/// Version, the automatic-check switch, and whatever the updater is doing.
struct UpdateSection: View {
    @EnvironmentObject private var updater: Updater

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private var isBusy: Bool {
        switch updater.state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    var body: some View {
        HStack {
            Text(L("Phiên bản %@", updater.currentVersion))
            Spacer()
            Button(L("Kiểm tra ngay")) { Task { await updater.check() } }
                .disabled(isBusy)
        }

        VStack(alignment: .leading, spacing: 2) {
            Toggle(L("Tự kiểm tra bản cập nhật"), isOn: $updater.automaticChecks)
            Text(L("Hỏi GitHub mỗi ngày một lần xem có bản mới không. Tắt mục này và mục kiểm tra Internet thì app không liên lạc ra ngoài máy."))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }

        status
    }

    @ViewBuilder
    private var status: some View {
        switch updater.state {
        case .idle:
            if let checked = updater.lastChecked {
                Text(L("kiểm tra lúc %@", Self.clock.string(from: checked)))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("Đang kiểm tra…")).foregroundStyle(.secondary)
            }
        case .upToDate:
            Label(L("Đang dùng bản mới nhất"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(Palette.memory)
        case .available(let release):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(L("Có bản mới %@", release.version), systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(Palette.cpu)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button(updater.canInstallInPlace ? L("Cập nhật ngay") : L("Tải về")) {
                        Task { await updater.install() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                if !release.notes.isEmpty {
                    Text(release.notes)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                }
                Link(L("Xem trên GitHub"), destination: release.page)
                    .font(.system(size: 11))
            }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress)
                Text(L("Đang tải… %.0f%%", progress * 100))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("Đang cài đặt… app sẽ tự mở lại")).foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.critical)
                    .font(.system(size: 11))
                if updater.latest != nil {
                    Button(L("Thử lại")) { Task { await updater.install() } }
                }
            }
        }
    }
}
