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

## Tai thỏ (notch)

`Notch.swift` và `NotchExtras.swift`, bật trong Cài đặt › Tai thỏ, mặc định tắt hết:

- **Báo sự kiện:** cắm hoặc rút sạc, một thiết bị Bluetooth vừa kết nối, mất mạng hoặc có mạng lại,
  cuộc gọi bắt đầu (tên app) hoặc kết thúc (thời lượng). Tai thỏ giãn ngang thành hai "cánh", biểu
  tượng bên trái, chữ bên phải, trong 3 giây. Nhiều sự kiện liền nhau được xếp hàng, hiện lần lượt.
  - Sạc: `IOPSNotificationCreateRunLoopSource`, báo ngay.
  - Bluetooth: `PeripheralWatcher` nghe danh sách thiết bị âm thanh của CoreAudio (AirPods, tai nghe)
    và thông báo IOKit cho `AppleDeviceManagementHIDEventService` (chuột, bàn phím), rồi đọc pin sau
    2 và 7 giây vì AirPods báo pin hơi trễ.
  - Pin yếu: báo khi pin xuống 20% và 10% lúc không cắm sạc, mỗi mức một lần cho tới khi cắm lại.
  - **Tài nguyên** (`ResourceWatch`): một app dùng trên 150% CPU, CPU trên 95°C, hoặc áp lực bộ nhớ ở
    mức đỏ, kéo dài nửa phút. Hết cảnh báo khi app xuống dưới 80% hay CPU dưới 85°C, để số đo quanh
    ngưỡng không chập chờn. Danh sách app chỉ lấy (bằng `ps`) mỗi 5 lần lấy mẫu và chỉ khi CPU bận trên
    25%.
  - **Cuộc họp** (`MeetingWatcher`, công tắc riêng, xin quyền Lịch khi bật): đọc lịch của macOS qua
    EventKit mỗi phút và khi lịch đổi. Báo trước 5 phút và lúc bắt đầu. Họp Teams có trong đó khi tài
    khoản Microsoft 365 đã thêm trong Tài khoản Internet; link vào họp (Teams, Zoom, Meet, Webex) lấy
    từ URL, địa điểm hoặc ghi chú, link Teams mở bằng `msteams://` cho thẳng vào app.
  - **Chia sẻ màn hình** (`ScreenSharing`): không có API, nên dựa vào việc Teams, Zoom, Webex vẽ một
    khung viền to bằng cả màn hình, nổi trên cửa sổ thường, trong lúc chia sẻ. Chỉ kiểm tra khi đang
    có cuộc gọi. Trong lúc đó tai thỏ giữ quầng đỏ và hai chấm đỏ nhấp nháy. `--notch-info` in các
    cửa sổ của những app này để chỉnh lại nếu một app làm khác.
- **Rê chuột để mở bảng:** để con trỏ trên tai thỏ khoảng 0,2 giây. Rời ra ngoài thì tự đóng.
  - **Cuộc gọi** (`CallDetector`): app nào đang giữ micro, đọc từ danh sách tiến trình của CoreAudio
    (`kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyIsRunningInput`, cần macOS
    14.2). Tiến trình phụ như `com.microsoft.teams2.modulehost` được quy về app có biểu tượng trên Dock
    chứa nó; nút Mở mở app đó qua Launch Services, nên cửa sổ đang thu nhỏ cũng hiện lại. Bỏ qua tiến trình
    `com.apple.*` (Siri, đọc chính tả) trừ FaceTime. Micro rảnh 8 giây liên tục mới coi là hết cuộc
    gọi, vì tắt tiếng có thể nhả micro một lúc. Tên cuộc họp lấy từ tiêu đề cửa sổ, chỉ đọc được khi
    Tacho có quyền Ghi màn hình; không có thì ghi "Đang trong cuộc gọi". Kiểm tra mỗi 2 giây khi bật
    một trong hai công tắc tai thỏ.
  - **Bài đang phát** (`NowPlayingStream`): đọc "Now Playing" của macOS, cùng nguồn với Trung tâm
    điều khiển, nên YouTube trong trình duyệt hay web app cũng được, không riêng Spotify và Nhạc.
    Framework MediaRemote đứng sau nó không trả lời app ngoài Apple từ macOS 15.4, nhưng vẫn trả lời
    `/usr/bin/osascript` của Apple. Vì vậy khi bảng mở, Tacho chạy một vòng JavaScript for Automation
    trong osascript, in một dòng JSON mỗi 0,5 giây (ảnh bìa chỉ gửi khi đổi bài), và dừng nó khi bảng
    đóng. Đọc không cần quyền nào. Nếu nguồn không có ảnh bìa (YouTube), hiện icon của app.
  - **Nút lùi, phát/dừng, tới** (`MediaKeys`) gửi phím media giả lập (`NX_KEYTYPE_PLAY/NEXT/PREVIOUS`),
    y như bấm phím trên bàn phím, nên tới đúng app đang phát. `MRMediaRemoteSendCommand` không dùng
    được: gọi từ app ngoài Apple thì bị bỏ qua, gọi qua osascript thì lúc ăn lúc không (YouTube dừng
    được nhưng không phát lại). Phím giả lập cần quyền Trợ năng; bấm nút lần đầu thì macOS hỏi, và bảng
    hiện dòng nhắc cho tới khi có quyền. Bản phát hành ký ad-hoc nên mỗi bản mới có thể phải cấp lại; bản build trên máy có chứng chỉ "Tacho
    Signing" thì giữ được quyền.
  - **Phát ra:** danh sách thiết bị CoreAudio có đầu ra, bỏ thiết bị ảo (driver của Teams, Zoom) và
    thiết bị gộp. Bấm là đổi thiết bị mặc định (`kAudioHardwarePropertyDefaultOutputDevice`).
  - Bài hát và danh sách loa chỉ được đọc mỗi giây trong lúc bảng đang mở. Tên loa tự rút gọn chứ
    không cuộn ngang, vì vuốt ngang để chuyển trang.
  - **Micro và camera:** nút tắt micro dùng công tắc mute của thiết bị vào mặc định
    (`kAudioDevicePropertyMute`), thiết bị không có thì hạ âm lượng vào về 0 rồi trả lại; tắt cho mọi
    app cùng lúc. Camera đang bật hay không đọc từ CoreMediaIO
    (`kCMIODevicePropertyDeviceIsRunningSomewhere`); hệ thống không nói app nào dùng.
  - **Đầy sau:** khi đang sạc, thời gian tới lúc đầy (`TimeRemaining` của pin).
  - **Giữ máy thức** (`KeepAwake`): `IOPMAssertion` kiểu `PreventUserIdleDisplaySleep`, như
    `caffeinate -d`; bấm để bật tới khi tắt, chuột phải để chọn 1 hoặc 2 giờ.
  - **Kệ file** (`NotchShelf`): chỉ giữ đường dẫn, file vẫn ở chỗ cũ, tối đa 12. Kéo file khác app
    không gửi sự kiện chuột cho app khác, nên một cửa sổ đen nhỏ nằm đúng chỗ camera (không nhìn thấy)
    đón việc kéo thả và mở bảng; cửa sổ đó cũng nhận việc rê chuột vào tai thỏ.
  - **Trang mở đầu:** chọn bảng mở ra ở trang chính, clipboard hay AI. Mỗi lần vuốt chỉ sang một trang;
    cuộn quán tính sau khi nhấc tay (Magic Mouse) không bao giờ lật trang.
  - **Trang clipboard** (`ClipboardHistory`, công tắc riêng): vuốt hai ngón ngang trên bảng để sang.
    Đọc `changeCount` mỗi 0,75 giây, chỉ đọc nội dung khi nó đổi; giữ 20 mục, bỏ qua mục có kiểu
    `org.nspasteboard.ConcealedType` / `TransientType` của trình quản lý mật khẩu. Mặc định lưu cả xuống
    `~/Library/Application Support/Tacho/Clipboard/` (`history.json` và ảnh PNG, quyền 0700/0600, không
    mã hoá) một giây sau mỗi thay đổi, nạp lại khi mở app, bỏ mục cũ hơn 7 ngày; tắt "Giữ lịch sử" hoặc
    tắt clipboard là xoá phần đã lưu. `--notch-demo` không đọc cũng không ghi chỗ này. Tìm kiếm
    không phân biệt hoa thường và dấu. Chỉ ở trang này bảng mới nhận bàn phím (như Spotlight, không
    đưa Tacho lên trước).
  - **Trang AI** (`AIUsage.swift`, công tắc riêng): hạn mức 5 giờ và 7 ngày, giờ reset và token hôm
    nay của Claude Code và Codex; tai thỏ báo khi một hạn mức vượt 80% và 95%, mỗi mức một lần mỗi chu
    kỳ. Đọc mỗi phút ở luồng nền, mỗi file nhật ký chỉ đọc phần mới ghi thêm (`JSONLTail`), lọc dòng bằng
    chuỗi trước khi parse JSON.
    - Codex: sự kiện `token_count` trong `~/.codex/sessions/**/*.jsonl` có cả token mỗi lượt lẫn
      `rate_limits` (primary/secondary, `used_percent`, `window_minutes`, `resets_at`). Đọc các phiên
      của 2 ngày gần nhất; không thấy hạn mức thì lùi về phiên cũ hơn, đọc từ cuối file.
    - Claude Code: token từ `~/.claude/projects/**/*.jsonl`. Mỗi câu trả lời bị ghi nhiều dòng khi
      stream, nên gộp theo `message.id`. Không tính token đọc lại từ cache (rê chuột để xem). Hạn mức
      không nằm trong nhật ký (chỉ có `quotaLimits` khi đã bị chặn); Claude Code chỉ đưa nó cho lệnh
      statusLine. Nút "Kết nối Claude Code" thêm `Tacho --claude-statusline` làm statusLine trong
      `~/.claude/settings.json` (sao lưu thành `settings.json.tacho-backup`); lệnh đó ghi
      `~/.claude/tacho-usage.json` và in một dòng trạng thái. Nếu đã có statusLine khác, "Kết nối, giữ
      statusLine hiện tại" cất nó vào `~/.claude/tacho-statusline-previous.json`; Tacho chạy nó với cùng
      dữ liệu (tối đa 5 giây) và in đúng kết quả của nó, Gỡ thì trả lại nguyên vẹn. Cũng làm được bằng
      `Tacho --claude-connect` / `--claude-disconnect`. Thư mục home lấy theo `HOME` như Claude Code. StatusLine chỉ chạy ở
      `claude` trong terminal, không chạy trong app Claude desktop, nên số hạn mức Claude có thể cũ:
      thẻ ghi tuổi của số, và hạn mức đã qua giờ reset hiện "Reset".
    - `Tacho --ai-usage` in những gì hai bộ đọc thấy, để đối chiếu.

Cách làm:

- Vị trí và kích thước tai thỏ lấy từ `NSScreen.safeAreaInsets` và `auxiliaryTopLeftArea` /
  `auxiliaryTopRightArea`. Màn hình không có tai thỏ (hoặc gập máy dùng màn rời) thì không hiện gì.
- Một `NSPanel` không viền, không lấy focus, đặt trên thanh menu. Không có
  `.fullScreenAuxiliary` nên không đè lên app toàn màn hình.
- `NotchShape` có hai bán kính animate được: vai lõm ở hai góc trên để hoà vào mép màn hình, và góc
  bo phía dưới. Nhờ vậy hình đổi dáng chứ không chỉ kéo giãn. Mở dùng spring hơi nảy, đóng dùng spring
  không nảy. Nội dung hiện sau hình một nhịp, rõ dần từ mờ (blur), các ô lần lượt trượt vào. Bật
  Giảm chuyển động (Reduce Motion) thì chỉ mờ dần.
- Mọi hiệu ứng bắt đầu và kết thúc ở trạng thái "idle": hình đen nhỏ hơn tai thỏ thật một chút, nằm
  khuất sau phần cứng. Xong là `orderOut`, nên lúc không hiện gì panel không được vẽ.
- Theo dõi con trỏ bằng `NSEvent` global monitor cho `mouseMoved`, không cần quyền Accessibility (chỉ
  phím bấm mới cần).
- Chạy thử mọi trạng thái: `open dist/Tacho.app --args --notch-demo`.
- Bảng không sát mép trên trên máy nào đó: `Tacho.app/Contents/MacOS/Tacho --notch-info` mở bảng, in
  kích thước màn hình, vùng tai thỏ, vị trí bảng muốn đặt và vị trí thật, rồi thoát.

## Hiệu năng

Đo bằng thời gian CPU của tiến trình trong 120 giây, trên MacBook Pro M1 Pro, ba màn hình, cửa sổ chính
đóng, chế độ gọn, bật tai thỏ (sự kiện, bảng, trang AI, lịch họp) và mục Docker/Kubernetes:

| | Trước đợt tối ưu (1.6.x) | Sau |
|---|---|---|
| CPU | 3,5% | 2,0% |
| Mẫu bận trong 30 giây (`sample`, 1 ms) | 1.248 | 374 |
| Bộ nhớ đỉnh lúc quét nhật ký AI lần đầu | 334 MB | 98 MB |

Cửa sổ chính đang hiện tốn thêm khoảng 2–3%. Lưu ý khi đo: app tự mở cửa sổ chính mỗi lần khởi
động, nên phải đóng nó (nút đỏ) trước khi đo trạng thái nền.

Những điều đã học được khi tối ưu — đừng đảo ngược:

- **Struct `App` không giữ store bằng `@StateObject`.** Như vậy cả scene theo dõi `MonitorStore`, và
  mỗi lần lấy mẫu SwiftUI dựng lại scene, cập nhật mọi cửa sổ kể cả cửa sổ đang ẩn. Các đối tượng
  sống trong `AppEnvironment`; App chỉ giữ tham chiếu thường, view nào hiển thị thì tự theo dõi.
- **Cửa sổ chính khi không nhìn thấy không theo dõi store.** `ContentView` chỉ theo dõi việc cửa sổ có
  hiện không; mọi thứ theo số liệu nằm trong `MainWindowContent`, chỉ tồn tại khi cửa sổ hiện. Trước
  đó thanh công cụ của cửa sổ ẩn được sắp xếp lại mỗi lần lấy mẫu.
- **Popover đóng thì gỡ `contentViewController`.** Không thì view SwiftUI vẫn sống, vẫn vẽ lại, và
  `onDisappear` không chạy (bảng Mạng đã từng để `nettop` chạy mãi).
- **Việc chạy ngầm không gọi `ps`.** Canh app ngốn CPU đọc `proc_pidinfo` (libproc), không sinh tiến
  trình; `ps` chỉ dùng cho bảng người dùng đang xem (nó thấy cả tiến trình của user khác).
- **Timer có `tolerance`** để macOS gộp các lần đánh thức.
- **Nhiệt độ đọc 5 giây một lần** bất kể tần suất lấy mẫu; khe cảm biến không dùng bị bỏ sau 3 lần đọc.
- **Nhật ký lớn đọc theo khối 4 MB**, xong thì `malloc_zone_pressure_relief` trả bộ nhớ trống lại.
- **Biểu tượng app qua `IconCache`**, không gọi `NSWorkspace.icon` mỗi lần vẽ.

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
