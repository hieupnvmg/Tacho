import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: MenuBarSettings
    @EnvironmentObject private var store: MonitorStore

    var body: some View {
        Form {
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
                Toggle(L("Vẽ đồ thị trong mục menu bar"), isOn: $settings.showGraphs)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(L("Kiểm tra kết nối Internet"), isOn: $settings.checkConnectivity)
                    Text(L("Gọi 1.1.1.1 của Cloudflare mỗi 60 giây. Đây là lần gọi mạng duy nhất của app; tắt đi thì app không liên lạc ra ngoài máy."))
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
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 450)
        // Strings are looked up while rendering, so a new identity re-renders
        // every one of them in the new language.
        .id(settings.language)
    }

    private func binding(for module: MenuBarModule) -> Binding<Bool> {
        Binding(get: { settings.isEnabled(module) },
                set: { settings.setEnabled(module, $0) })
    }
}
