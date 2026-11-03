# Tacho — cách hoạt động

Ghi chú kỹ thuật cho người muốn build, sửa hoặc phát hành Tacho. Giới thiệu và cách cài cho người dùng nằm ở [README](../README.md).

Mọi lệnh dưới đây chạy từ thư mục gốc của repo.

## Build & chạy

```bash
./build-app.sh
open "dist/Tacho.app"
```

`build-app.sh` chạy `swift build -c release` rồi đóng gói binary thành `.app`
double-click được (ký ad-hoc). Yêu cầu: macOS 13+, Swift 5.9+ (Command Line Tools là đủ).

Đóng gói thành file cài đặt `.dmg` (kéo app vào Applications):

```bash
./build-dmg.sh   # → dist/Tacho.dmg
```

App chỉ ký ad-hoc, chưa notarize. Trên máy khác, lần đầu mở macOS sẽ chặn: chuột phải vào app →
**Open**, hoặc vào **System Settings → Privacy & Security** bấm **Open Anyway**.

Biểu tượng app được vẽ bằng code trong `scripts/make-icon.swift`. Sửa xong thì chạy
`swift scripts/make-icon.swift` để ghi lại `Assets/AppIcon.icns` (được `build-app.sh` chép vào
bundle) và `docs/images/icon.png` (dùng trong README).

Kiểm tra số liệu không cần mở cửa sổ:

```bash
./.build/release/Tacho --dump
```

## Ngôn ngữ

Chọn **Tiếng Việt / English / Русский** trong **Cài đặt** (`⌘,`); đổi là áp dụng ngay, không cần
mở lại app. Mọi chữ trong code viết bằng tiếng Việt và bọc trong `L("…")` — chính chuỗi tiếng Việt
là khóa tra bản dịch. Thêm hoặc sửa chữ thì bổ sung bản dịch vào `scripts/gen_translations.py` rồi chạy:

```bash
python3 scripts/gen_translations.py   # sinh lại Translations.swift, báo lỗi nếu thiếu bản dịch
```

Xem giao diện ở ngôn ngữ khác mà không đổi cài đặt: `--snapshot <thư mục> --lang en`.

## Các màn hình

| Mục | Nội dung |
|---|---|
| Tổng quan | Vòng tròn CPU & RAM, sparkline disk I/O và mạng, thông tin máy, dung lượng ổ |
| CPU | Tải tổng tách user/system/idle, load average, mỗi lõi một vòng tròn (xanh ngọc = lõi tiết kiệm điện, xanh dương = lõi hiệu năng) kèm trung bình từng cụm, và card GPU (mức dùng, renderer, tiler, bộ nhớ), nhiệt độ CPU (trung bình và nóng nhất), và tốc độ từng quạt |
| Bộ nhớ | App / Wired / Compressed / Cached / Free, memory pressure, swap |
| Ổ đĩa | Tốc độ đọc–ghi, IOPS, tổng byte từ lúc boot, phần cứng ổ (model, serial, firmware, giao tiếp, SMART), từng phân vùng |
| Pin | % còn lại, thời gian còn dùng, dung lượng tối đa, chu kỳ sạc, tình trạng, điện áp/dòng/công suất, bộ sạc đang cắm, công suất máy đang dùng, công suất sạc vào pin, công suất tối đa và mức dùng của cục sạc |
| Mạng | Băng thông vào/ra và tổng lưu lượng |
| Tiến trình | 12 tiến trình tốn CPU nhất kèm RSS |

## Menu bar

Mỗi chỉ số là **một mục riêng trên menu bar** (kiểu iStat Menus), vẽ đồ thị sống
ngay tại chỗ:

- **CPU** — đồ thị lịch sử + phần trăm + nhiệt độ CPU trung bình
- **GPU** — đồ thị lịch sử + phần trăm mức dùng GPU
- **Bộ nhớ** — **áp lực bộ nhớ** (không phải tỉ lệ RAM đã dùng), màu theo mức
  normal/warning/critical của kernel
- **Mạng** / **Ổ đĩa** — hai dòng ↓/↑ và R/W, đồ thị chồng hai đường
- **Kết nối** — một chấm: xanh là có Internet, đỏ là mất mạng, vàng là đang kiểm tra.
  Bấm vào xem IP ra Internet, IP nội bộ và đường ra (có cảnh báo khi đang qua VPN)
- **Pin** — cục pin vẽ tay, mức đầy đúng theo phần trăm thật (SF Symbol chỉ có 5 nấc
  cố định nên không dùng được), có tia sét khi đang sạc

**Chế độ gọn** (Cài đặt → Hiển thị) gộp mọi chỉ số vào một mục duy nhất (`CompactStatusView`): mỗi
chỉ số một cột hai dòng, không đồ thị. Bấm vào cột nào thì popover của cột đó mở ngay dưới cột. Một mục
thay vì sáu nghĩa là macOS chỉ phải chụp lại một mục mỗi giây, nên nhẹ hơn (xem phần Hiệu năng).

Bấm vào mục nào sẽ mở popover chi tiết của chỉ số đó. Popover CPU và Bộ nhớ có thêm 5 app tốn
CPU / RAM nhất. Mỗi tiến trình được gom về app chứa nó: lấy đường dẫn bằng `proc_pidpath` rồi lấy
bundle `.app` ngoài cùng, nên mọi renderer của Chrome được cộng vào "Google Chrome". RAM là tổng RSS,
nên cao hơn số của Activity Monitor một chút, vì bộ nhớ dùng chung bị cộng nhiều lần. Danh sách chỉ
được lấy khi popover đang mở (hoặc tab Tiến trình đang hiện), 3 chu kỳ một lần. Chọn mục nào hiện, bật/tắt
đồ thị, ẩn icon khỏi Dock và đổi tần suất lấy mẫu trong **Cài đặt** (`⌘,`).
Mặc định bật CPU, Bộ nhớ, Mạng và Kết nối (nên app gọi ra Cloudflare ngay từ lần chạy đầu — xem phần bên dưới để tắt).

Đóng cửa sổ chính không thoát app — các mục menu bar vẫn chạy. Nếu tắt hết mục thì
icon Dock tự bật lại để còn đường quay vào app.

Tần suất lấy mẫu cũng chọn được 0.5s–5s ở góc dưới sidebar cửa sổ chính, và được nhớ giữa các lần mở app.

## Ảnh quảng cáo trong README

```bash
./dist/Tacho.app/Contents/MacOS/Tacho --promo docs/images
```

Dựng lại toàn bộ ảnh trong `docs/images/` từ giao diện thật. IP công khai, IP nội bộ, tên VPN và
serial ổ cứng được thay bằng giá trị mẫu trước khi chụp, vì các ảnh này được công khai.

## Xem giao diện không cần quyền Screen Recording

```bash
./.build/release/Tacho --snapshot /tmp/shots
```

App tự render view của nó ra PNG (sáng và tối, kèm cả dải menu bar) bằng `ImageRenderer`
và `cacheDisplay`. Dùng để soi layout mà không phải cấp quyền chụp màn hình.

## Nguồn dữ liệu

Tất cả đọc trực tiếp từ API hệ thống, không phụ thuộc thư viện ngoài:

- **CPU**: `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` — chênh lệch tick giữa hai lần lấy mẫu.
  Phân loại P/E-core qua `hw.perflevel0/1.logicalcpu`.
- **RAM**: `host_statistics64(HOST_VM_INFO64)` + `hw.memsize`; swap từ `vm.swapusage`.
  "Used" tính theo cách của Activity Monitor = app + wired + compressed.
- **GPU**: IORegistry `IOAccelerator` → `PerformanceStatistics` (`Device/Renderer/Tiler
  Utilization %`, `In use system memory`, `Alloc system memory`), tên chip và số nhân từ
  `model` và `gpu-core-count`. Không cần `powermetrics` nên không cần quyền root.
- **Áp lực bộ nhớ**: `kern.memorystatus_level` là phần trăm bộ nhớ còn trống toàn hệ thống
  (đúng bằng con số `/usr/bin/memory_pressure` in ra), nên áp lực = `100 - giá trị đó`.
  Mức normal/warning/critical lấy từ `kern.memorystatus_vm_pressure_level`.
  Đây là **hai chỉ số khác nhau**: máy có thể dùng 78% RAM mà áp lực chỉ 51% và vẫn ở mức
  bình thường — nên `usedFraction` và `pressure` được tách riêng trong code.
- **Disk I/O**: IORegistry, thống kê của `IOBlockStorageDriver`.
- **Dung lượng ổ**: `FileManager.mountedVolumeURLs` (bỏ qua disk image chỉ đọc và ổ < 1 GB).
- **Phần cứng ổ**: IORegistry `IOBlockStorageDevice` → `Device/Protocol Characteristics`.
  Dung lượng lấy từ `IOMedia` có `Whole = true`, nằm sâu hai cấp dưới device nên phải duyệt đệ quy.
- **Pin**: IORegistry `AppleSmartBattery`. Số mAh nằm trong dict con `BatteryData`
  (`DesignCapacity`, `NominalChargeCapacity`, `RemainingCapacity`), còn `CurrentCapacity`
  ở cấp ngoài đã là phần trăm trên Apple silicon. Riêng **dung lượng tối đa và tình trạng**
  lấy từ `system_profiler -json SPPowerDataType` (cache 30 phút, vì lệnh này tốn khoảng 1 giây) vì macOS không tính con số đó
  theo tỉ lệ mAh — tự tính sẽ ra lệch (76.6% thay vì 80%) và sai cả kết luận tình trạng.
  **Công suất** lấy từ dict `PowerTelemetryData` (mW, do bộ điều khiển nguồn đo): `SystemLoad` là
  máy đang dùng, `BatteryPower` là phần đang sạc vào pin, `SystemPowerIn` là tổng kéo từ cục sạc.
  Công suất tối đa của cục sạc là `AdapterDetails.Watts`. Mac không có `PowerTelemetryData` thì
  tính lùi từ điện áp × dòng điện.
- **Mạng**: sysctl `NET_RT_IFLIST2` → `if_data64.ifi_ibytes/ifi_obytes` (bỏ loopback). Với app
  thường (không có entitlement riêng của Apple) kernel vẫn cắt bộ đếm còn 32-bit, quay vòng mỗi
  4 GiB — `netstat` thấy số thật, app thì không. Vì vậy tốc độ được tính từ chênh lệch của từng
  card có xử lý quay vòng, và "tổng" là lưu lượng app đếm được **từ lúc mở app**, không phải từ
  lúc boot. Disk I/O cũng cộng chênh lệch theo từng ổ, nên cắm hay rút ổ không làm số vọt lên.
- **Nhiệt độ CPU**: các SMC key tiền tố `Tp` (lõi hiệu năng), `Te` (lõi tiết kiệm điện) và `Tf`
  (từ M3). Mỗi đời chip đặt tên khác nhau nên app duyệt bảng key của SMC một lần lúc chạy để tìm,
  rồi mỗi chu kỳ đọc lại, bỏ cảm biến trả 0. Hiển thị trung bình và cảm biến nóng nhất. Trên menu
  bar, nhiệt độ trung bình nằm ngay sau % CPU. Mac Intel (key `TC0P`…) chưa hỗ trợ.
- **Quạt**: SMC key `FNum` (số quạt), `F<n>Ac` (tốc độ hiện tại), `F<n>Mn`/`F<n>Mx` (giới hạn).
  Apple silicon trả kiểu `flt ` (Float little-endian), Intel trả `fpe2`. Mac không quạt
  (MacBook Air) thì phần này tự ẩn.
- **Tiến trình**: `/bin/ps -Aceo pid,pcpu,rss,comm -r`, làm mới mỗi 3 chu kỳ và chỉ khi đang mở tab Tiến trình.

## App có gọi ra Internet

App chỉ liên lạc ra ngoài máy ở **hai chỗ**, cả hai đều tắt được trong Cài đặt (`⌘,`):

1. **Kiểm tra kết nối** — mục "Kết nối" gọi `https://1.1.1.1/cdn-cgi/trace` của Cloudflare,
   60 giây một lần và mỗi khi đường mạng thay đổi, để biết thật sự có ra được Internet hay không
   (route tồn tại chưa chắc đã ra được — captive portal, uplink chết). Phản hồi của endpoint đó
   cũng chính là nguồn IP ra Internet: không có cách nào biết IP công khai mà không hỏi một bên
   ngoài mạng.
2. **Kiểm tra bản cập nhật** — hỏi `api.github.com` mỗi ngày một lần (xem phần dưới).

Tắt cả hai thì app không gửi gì ra ngoài. Mọi chỉ số còn lại đều đọc từ kernel trên máy.

## Cập nhật tự động (OTA)

App tự hỏi GitHub Releases của [`hieupnvmg/Tacho`](https://github.com/hieupnvmg/Tacho/releases)
lúc mở và sau đó mỗi ngày một lần. Có bản mới thì hiện dải **"Có bản mới…"** ở cuối mọi popover và
trong **Cài đặt → Cập nhật**; bấm **Cập nhật ngay** là app:

1. tải file `.dmg` và file `.dmg.sha256` của bản phát hành,
2. so mã SHA-256 — lệch là dừng,
3. mount `.dmg`, kiểm tra app bên trong đúng bundle id, đúng số phiên bản và chữ ký hợp lệ,
4. thoát; một script nhỏ chờ app tắt hẳn, thay bản cũ bằng bản mới (lỗi thì khôi phục bản cũ)
   rồi mở lại app.

App phải nằm ở thư mục ghi được (vd `/Applications` với tài khoản admin). Nếu đang chạy thẳng từ
`.dmg` thì nút đổi thành **Tải về** và mở trang release trên GitHub.

### Phát hành bản mới

```bash
./release.sh 1.1.0 "Mô tả thay đổi"
```

Script ghi `VERSION`, build `.dmg` + `.dmg.sha256`, commit, gắn tag `v1.1.0`, push, rồi tạo release
trên GitHub kèm hai file đó (cần GitHub CLI `gh`; không có thì script in link để tạo tay — nhớ đính
kèm **cả hai** file, thiếu `.sha256` app sẽ từ chối cập nhật).

Thử toàn bộ luồng mà không cần phát hành: tạo một file JSON giống API GitHub trỏ tới `.dmg` trên máy,
rồi chạy

```bash
TACHO_UPDATE_FEED=file:///đường/dẫn/feed.json ./dist/Tacho.app/Contents/MacOS/Tacho --update-check
TACHO_UPDATE_FEED=file:///đường/dẫn/feed.json ./dist/Tacho.app/Contents/MacOS/Tacho --update-install --no-relaunch
```

## Pin thiết bị Bluetooth

Popover Pin liệt kê các thiết bị Bluetooth đang kết nối có báo pin (`Peripherals.swift`):

- Chuột, bàn phím, trackpad của Apple: đọc `BatteryPercent` từ IOKit (`AppleDeviceManagementHIDEventService`).
- AirPods, Beats và một số tai nghe: chỉ có trong `system_profiler -json SPBluetoothDataType`
  (pin trái, phải, hộp sạc). Chỉ lấy thiết bị đang kết nối, vì thiết bị đã rời đi vẫn giữ số cũ.

Hai nguồn được gộp theo địa chỉ Bluetooth. Đọc mỗi 60 chu kỳ và ngay khi mở popover Pin.

## Lịch sử 24 giờ

Tab **Lịch sử** trong cửa sổ chính vẽ CPU, nhiệt độ, áp lực bộ nhớ, mạng và pin trong 1 giờ hoặc 24
giờ qua (Swift Charts). `HistoryRecorder` gộp mẫu mỗi giây thành điểm trung bình mỗi phút, giữ 24 giờ
(khoảng 1.440 điểm) và lưu vào `~/Library/Application Support/Tacho/history.json`: 10 phút một lần
và khi thoát app. Xem 24 giờ thì gộp tiếp thành bước 5 phút. Khi máy ngủ hoặc Tacho không chạy, đường
biểu đồ bị ngắt thay vì nối thẳng qua khoảng trống.

## Mở cùng máy và cảnh báo

**Mở Tacho khi đăng nhập** dùng `SMAppService.mainApp`, tức danh sách Login Items của macOS. Công tắc
đọc trạng thái từ hệ thống, không lưu riêng, nên luôn khớp với System Settings.

**Cảnh báo** (`Alerts.swift`) chạy sau mỗi lần lấy mẫu và gửi thông báo qua `UserNotifications`:

| Cảnh báo | Bắn khi | Bật lại khi | Mặc định |
|---|---|---|---|
| CPU quá nóng | trung bình ≥ 95°C liên tục 2 phút | xuống dưới 85°C | bật |
| Pin yếu | ≤ 20% và chưa cắm sạc | cắm sạc hoặc > 25% | bật |
| Pin đã sạc đầy | cắm sạc và pin đầy | rút sạc | tắt |
| Pin chuột, bàn phím, tai nghe yếu | một thiết bị Bluetooth ≤ 15% | thiết bị đó > 25% | bật |
| Ổ đĩa sắp đầy | ổ khởi động trống < 10% | trống > 12% | bật |
| Mất Internet | offline liên tục 30 giây (cần bật kiểm tra kết nối) | có mạng lại, kèm thông báo "đã có Internet trở lại" | bật |

Mỗi cảnh báo chỉ bắn một lần cho mỗi lần sự cố xảy ra. Khoảng chênh giữa ngưỡng bắn và ngưỡng bật
lại để số đo dao động quanh ngưỡng không gây ra một loạt thông báo.

## Hiệu năng

Đo bằng thời gian CPU của tiến trình trong 30 giây, trên MacBook Pro M1 Pro, lấy mẫu 1 giây/lần:

| Trạng thái | CPU |
|---|---|
| Chỉ có menu bar (cửa sổ đóng hoặc bị che) | ~3% |
| Cửa sổ chính đang hiện | ~4–5% |
| Chế độ gọn (một mục menu bar) | ~1,6% |

Những điều đã học được khi tối ưu — đừng đảo ngược:

- **Mục menu bar chỉ vẽ lại khi nội dung nhìn thấy được thay đổi** (`StatusItemView.redrawIfChanged`).
  macOS chụp lại mỗi mục cho từng menu bar (mỗi màn hình, mỗi Space) mỗi lần nó vẽ lại, tốn hơn
  chính việc vẽ.
- **Không override `viewDidChangeEffectiveAppearance` trong `StatusItemView`.** Các lần chụp đó đổi
  appearance của view theo từng màn hình; hook này từng làm mọi mục vẽ lại ~11 lần/giây.
- **Mục menu bar có độ rộng cố định** theo giá trị dài nhất. Đổi `length` bắt macOS sắp xếp lại cả
  menu bar trong một tiến trình khác.
- **Không dùng `button.image` cho mục menu bar.** Ảnh vẽ sẵn chỉ đúng một kiểu sáng/tối, trong khi menu
  bar mỗi màn hình có thể khác nhau; còn theo dõi `effectiveAppearance` của nút thì thành vòng lặp.
- **Cửa sổ chính gỡ nội dung tab ra khi không nhìn thấy** (`WindowObserver`: bị che, thu nhỏ, ở Space
  khác), nên SwiftUI không tính lại giao diện mỗi giây.
- **Không animation** trên các vòng tròn cập nhật mỗi giây (xem `CoreRing`).
- Nhiệt độ và quạt đọc mỗi 3 chu kỳ: mỗi key SMC là một lần gọi xuống kernel.

## Ghi chú

- Không cần quyền đặc biệt nào; tất cả API đều public và không cần root.
- Nhiệt độ CPU và tốc độ quạt đọc trực tiếp SMC qua user client `AppleSMC`
  (`SMC.swift`), không cần root. Giao thức này Apple không công bố nhưng ổn định nhiều năm và là
  cách iStat Menus, Stats cùng dùng. App chỉ **đọc**, không có code nào điều khiển quạt.
  Nhiệt độ pin thì lấy được, nhưng không phải máy nào cũng báo (MacBookPro18,3 không có),
  nên dòng này tự ẩn khi bằng 0.
- `@State` của SwiftUI hiện là macro cần plugin chỉ có trong Xcode đầy đủ. Để build được
  bằng Command Line Tools, state của UI (tab đang chọn, tần suất) nằm trong `MonitorStore`.
- Menu bar dùng `NSStatusItem` + `NSView` tự vẽ chứ không dùng `MenuBarExtra` của SwiftUI,
  vì label của `MenuBarExtra` chỉ nhận text/symbol tĩnh, không vẽ được đồ thị cập nhật liên tục.
  `MonitorStore.onSample` là chỗ báo cho AppKit vẽ lại sau mỗi lần lấy mẫu.
