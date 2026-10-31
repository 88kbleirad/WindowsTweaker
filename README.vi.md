# WindowsTweaker

Tùy biến Windows có thể xem lại và hoàn tác, điều khiển từ terminal.

Mỗi thay đổi là một **tinh chỉnh** kèm siêu dữ liệu (phạm vi, quyền cần có, điều kiện hệ điều
hành được hỗ trợ, mức ảnh hưởng, yêu cầu khởi động lại, khả năng hoàn tác), một **bộ nhận
diện chỉ đọc** và một phần **áp dụng** luôn lưu trạng thái trước đó trước khi ghi. Mọi thay
đổi đều có thể chạy thử, được xác minh, được ghi log theo từng thao tác và có thể hoàn tác về
đúng trạng thái đã tồn tại trước đó - không phải về một giá trị mặc định cứng.

Tài liệu tiếng Anh: [README.md](README.md).

## Tình trạng

* Nền tảng mục tiêu: **Windows 10 22H2 / Windows 11** với **PowerShell 7.4 trở lên**.
  Windows PowerShell 5.1 **không được hỗ trợ**: mã nguồn dùng các tính năng chỉ có ở
  PowerShell 7 (`-Encoding utf8NoBOM`, `-ErrorAction Ignore`, `[type]::new()`), và các mô-đun
  chỉ có trên Windows được nạp một cách tường minh.
* Giao diện: **giao diện dòng lệnh tương tác bằng bàn phím** (mặc định), dòng lệnh tự động
  hóa, và một cửa sổ WPF tùy chọn - tất cả dùng chung một backend.
* Tình trạng kiểm chứng: xem [docs/VALIDATION.md](docs/VALIDATION.md). Bản này được kiểm
  chứng tĩnh và bằng bộ kiểm thử tự động trên Linux (471 bài kiểm thử, bao gồm cả giao diện
  terminal được điều khiển không cần màn hình và trong một pty thật); các kiểm chứng tích hợp
  chỉ có trên Windows chưa chạy được và được liệt kê rõ ràng thay vì tuyên bố là đã chạy.

## Bắt đầu nhanh

```powershell
# Giao diện terminal (sản phẩm chính): duyệt, tìm, chọn, xem lại, áp dụng.
# Mọi lựa chọn đều được xem lại trước khi ghi; xem docs/KEYBOARD.md.
pwsh -File WindowsTweaker.ps1

# Chỉ đọc: máy này làm được gì, trạng thái hiện tại ra sao?
pwsh -File WindowsTweaker.ps1 -Status
pwsh -File WindowsTweaker.ps1 -List

# Chạy thử: hiện mọi thao tác sẽ chạy; không ghi gì.
pwsh -File WindowsTweaker.ps1 -Id Privacy.AdvertisingId -State Disabled -WhatIf

# Áp dụng, có lưu trạng thái cũ để hoàn tác.
pwsh -File WindowsTweaker.ps1 -Id Privacy.AdvertisingId -State Disabled

# Tùy chọn: xin thêm một điểm khôi phục trước (là phần bổ sung, không bao giờ ngầm định).
pwsh -File WindowsTweaker.ps1 -Id Privacy.AdvertisingId -State Disabled -IncludeRestorePoint

# Xem trước cả một bộ cài, rồi áp dụng.
pwsh -File WindowsTweaker.ps1 -PresetList
pwsh -File WindowsTweaker.ps1 -Preset privacy-hardening -WhatIf

# Hoàn tác, khôi phục đúng trạng thái trước đó.
pwsh -File WindowsTweaker.ps1 -Id Privacy.AdvertisingId -Rollback

# Giao diện đồ họa tùy chọn (chỉ trên Windows).
pwsh -File WindowsTweaker.ps1 -Gui
```

Dùng trong script:

```powershell
Import-Module ./src/WindowsTweaker/WindowsTweaker.psd1

Get-WtTweak -Category Explorer                        # danh mục
Get-WtTweakState -Search 'telemetry'                  # trạng thái hiện tại, chỉ đọc
Invoke-WtTweak -Id Privacy.AdvertisingId -State Disabled -WhatIf
Undo-WtTweak -Id Privacy.AdvertisingId                # hoàn tác thay đổi mới nhất
Get-WtHistory                                         # lịch sử thay đổi
Get-WtPreset                                          # bộ cài có sẵn và của bạn
Export-WtPreset -Entries @(@{ id = 'Explorer.FileExtensions'; state = 'Enabled' }) -Path ./my-preset.json
Export-WtReport -Format Json                          # môi trường + danh mục + lịch sử
```

Mã thoát của điểm vào: `0` thành công/không đổi/chạy thử, `1` thất bại hoặc không hỗ trợ,
`2` không có gì để làm (hoặc giao diện terminal không khởi động được).

## Giao diện terminal

Giao diện terminal là sản phẩm chính: nó thay thế menu dòng lệnh cũ và chuyển các luồng công
việc mà công cụ cũ làm trong cửa sổ sang dạng terminal.

```
 ⊞ WindowsTweaker                                              Bộ cài: privacy-hardening    
 Windows11 build 22631 | PowerShell 7.4.2 | quản trị viên | thực thi | VI                   
├──────────────────┬──────────────────────────────────────┬────────────────────────────────┤
┌ Nhóm ────────────┬ Tinh chỉnh ──────────────────────────┬ Chi tiết ──────────────────────┐
 ⌂ Tổng quan [113]│ *  ▪ ID quảng cáo  Disabled   Enabled│▪ Kết quả và gợi ý web trong hộp 
 ▪ Quyền ri...[20]│>*  ▪ Kết quả web  Disabled   Enabled│  tìm kiếm                       
 ▭ Explorer   [18]│ *  ▪ Dữ liệu ch...  Enabled   Enabled│                                 
 ▦ Ứng dụng   [21]│    ▪ Ứng dụng Mi... Unsuppor...          │Privacy.BingSearch               
 ⊞ Hệ thống   [14]│    ▪ Báo cáo lỗi... Unsuppor...          │                                 
 ○ Mạng        [1]│    ▪ Phản hồi W... Unsuppor...          │Đặt chính sách người dùng để     
 ◆ Bảo mật    [11]│    ▪ Cho phép w... Unsuppor...          │loại bỏ gợi ý web khỏi hộp tìm   
 ⇩ Cập nhật    [5]│    ▪ Ứng dụng c... Unsuppor...          │kiếm của Start và File Explorer  
 ▤ Cá nhân...  [9]│    ▪ Nội dung đ... Unsuppor...          │(HKCU\Software\Policies\Microsof 
 ↺ Lịch sử     [0]│    ▪ Tìm kiếm n... Unsuppor...          │t\Windows\Explorer\DisableSearch 
└──────────────────┴──────────────────────────────────────┴────────────────────────────────┘
├──────────────────┴──────────────────────────────────────┴────────────────────────────────┤
 Lên/Xuống di chuyển  Trái/Phải hoặc Tab đổi khung  Space chọn  Enter hành động  / tìm  A…  
 Sẵn sàng. Dùng / để tìm, Space để chọn thay đổi, A để xem lại. 3 thay đổi đang chờ        
```

* **Các khung** - nhóm, danh sách tinh chỉnh và khung chi tiết nêu rõ mô tả, ảnh hưởng dự
  kiến, phạm vi, quyền, trạng thái hiện tại, mức ảnh hưởng, yêu cầu khởi động lại, khả năng
  hoàn tác và các phụ thuộc.
* **Bố cục** - ba khung khi terminal từ 92x18, hai khung từ 58x12, và một khung kèm dải tab
  khi nhỏ hơn. Đổi kích thước terminal sẽ vẽ lại mà không mất con trỏ, danh sách chờ, bộ lọc
  hay hộp thoại đang mở.
* **Biểu tượng** - một bộ biểu tượng theo ngữ nghĩa cho nhóm, trạng thái và hành động, vẽ
  theo bốn chế độ: `Unicode` (ký hiệu đơn sắc thận trọng, mặc định khi mã hóa đầu ra là
  UTF-8), `NerdFont` (ký tự vùng riêng tư, phải tự chọn), `ASCII` (thẻ dễ đọc như `[NET]`,
  `[OK]`, `[WARN]`, `[ERR]` và `[ADMIN]`) và `None`. `Auto` tự chọn Unicode hoặc ASCII theo
  terminal hiện tại; không bao giờ cài, dò hay đổi phông. Nhấn `I` để mở phần xem trước ngay
  trong terminal, vẽ đúng bảng ký tự của từng chế độ; lựa chọn được lưu vào `settings.json`
  cạnh kho trạng thái, và `-Icons <chế độ>` ghi đè cho một lần chạy. Biểu tượng chỉ để trang
  trí: trạng thái, nhóm và hành động luôn được viết bằng chữ, và phím tắt không phụ thuộc vào
  chúng.
* **Màu** - bảng Catppuccin Mocha với các mức true colour, 256 màu, 16 màu và không màu; góc
  khung vuông; có phương án khung ASCII. Ký hiệu trên dòng (`>`, `*`, `!`, `M`, `R`, `D`) giữ
  cho mọi trạng thái đọc được khi không có màu hoặc biểu tượng, không cần Nerd Font. Tiếng
  Anh và tiếng Việt dùng cùng một bố cục.
* **Worker nền tùy chọn** - một chương trình Go nhỏ, chỉ đọc, không cần quyền quản trị
  (`worker/bin/<os>-<arch>/wt-worker[.exe]`) có thể phục vụ các việc nền đo được qua giao thức
  JSON Lines có phiên bản trên stdin/stdout. Nó không bao giờ ghi một cài đặt, không bao giờ chạy
  bằng quyền quản trị, và không bao giờ cài đặt engine thay đổi, nhật ký hay hoàn tác - những
  phần đó vẫn ở PowerShell. Năng lực đầu tiên là quét thư mục kèm tổng hợp dung lượng
  (`Invoke-WtDirectoryScan`), với các chế độ backend `Auto` / `Go` / `PowerShell` (đặt trong cài
  đặt hoặc qua `-WorkerBackend`), tự động quay về bản PowerShell kèm lý do được báo cáo, và
  `-Scan <path>` trên dòng lệnh. Xem [docs/WORKER.md](docs/WORKER.md) cho giao thức, cách build,
  và chính xác những kiểm chứng trên Windows **chưa** chạy.
* **Xác minh thay đổi và khôi phục** - mọi thay đổi đang chờ đều được xem trước theo từng đích
  (giá trị hiện tại, giá trị và kiểu đề xuất, phạm vi, trạng thái hỗ trợ, giới hạn khôi phục, và
  việc một thao tác trước đó đã giữ bản gốc hay chưa), các đích chồng lấn được báo là xung đột
  trước khi chạy bất cứ thứ gì, và trạng thái đã xem lại được đọc lại ngay trước khi áp dụng:
  nếu nó đã đổi, thay đổi bị từ chối và phải xem lại. Nhật ký ghi phiên bản schema, phiên, thao
  tác, thao tác cha, nguồn gốc (manual, preset, recovery, reapply), giai đoạn, các đích chuẩn
  hóa, trạng thái đã chụp và kết quả đã xác minh, và được ghi trước thao tác ghi đầu tiên. Việc
  áp dụng và khôi phục đọc lại các đích được hỗ trợ; lỗi một phần sẽ kích hoạt khôi phục đền bù
  (báo theo từng đích, không bao giờ được mô tả là "Windows rollback nguyên tử") và giữ lại dữ
  liệu khôi phục. `V` hiển thị drift (matching / changed / unreadable / unsupported) và các thao
  tác bị ngắt, kèm hành động áp dụng lại và khôi phục tường minh - không bao giờ tự động áp dụng
  lại. Xem [docs/STATE-JOURNAL.md](docs/STATE-JOURNAL.md).
* **Ngôn ngữ** - Tiếng Anh và Tiếng Việt có đầy đủ mọi chuỗi hiển thị: tiêu đề, nhóm, chi
  tiết, dòng trạng thái, gợi ý phím, tiêu đề/câu hỏi/nút của hộp thoại, thông báo lỗi và cảnh
  báo không hỗ trợ trên nền tảng này. Nhấn `L` (hoặc dòng Ngôn ngữ ở Tổng quan) để đổi ngay -
  toàn bộ khung và tên tinh chỉnh được vẽ lại, trong khi nội dung tìm kiếm, danh sách chờ, con
  trỏ và lịch sử thao tác được giữ nguyên - và lựa chọn được lưu lại. Thứ tự ưu tiên khi khởi
  động: `-Language en|vi` (ví dụ `pwsh -File WindowsTweaker.ps1 -Language vi`) > lựa chọn đã
  lưu > `WT_LANG` > văn hóa giao diện > tiếng Anh. Đổi ngôn ngữ không bao giờ áp dụng hay đặt
  lại một tinh chỉnh nào.
* **Phím tắt** - [docs/KEYBOARD.md](docs/KEYBOARD.md) (tiếng Anh và tiếng Việt). Dòng cuối
  hiển thị các phím tắt vừa đủ chỗ và `?` liệt kê đầy đủ; `-InputDiagnostics` ghi lại mọi
  phím và nơi phím được gửi tới (che các ô nhập văn bản) khi một phím có vẻ bị bỏ qua.
* **Không bao giờ mở cửa sổ** - xác nhận, bảng chọn và thông báo lỗi đều là khung trong cùng
  màn hình. Bảng chọn gói Store, danh sách tính năng/khả năng của Windows, luồng cấu hình DNS
  và các hộp thoại nhập đường dẫn cho bộ cài đều là luồng terminal.
* **Không bị treo** - việc áp dụng và hoàn tác chạy trong một runspace riêng và báo cáo tiến
  độ có cấu trúc (`Mục 3/18`, không bao giờ là phần trăm tự đặt ra), kết quả từng mục và yêu
  cầu khởi động lại. Việc hủy là hợp tác: các mục trong hàng đợi bị bỏ, mục đang chạy kết thúc
  ở ranh giới an toàn - và giao diện nói rõ điều đó. Mỗi lần chỉ chạy một tác vụ.
* **Giữ gìn terminal** - dùng màn hình thay thế (không có vòng lặp `Clear-Host` gây nháy), và
  terminal được khôi phục khi thoát bình thường, khi nhấn `Ctrl+C` và khi có lỗi bất ngờ.

## Nguyên tắc an toàn

| Bảo đảm | Cách thực hiện |
|---|---|
| Nạp mô-đun không thay đổi gì | Tệp tinh chỉnh chỉ đăng ký siêu dữ liệu; có bài kiểm thử khẳng định không thao tác ghi nào chạy khi nạp và không tệp trạng thái/log nào được tạo |
| Khởi tạo chỉ đọc | `Get-WtEnvironment` chỉ đọc (phiên bản, quyền, build hệ điều hành, chờ khởi động lại, lệnh khả dụng). Mọi thao tác ghi khi khởi động của bản cũ đã bị loại bỏ |
| Chọn một dòng không thay đổi gì | Giao diện giữ một danh sách chờ; `A` xem lại đúng các thay đổi và chỉ khi bạn xác nhận mới áp dụng. Mọi thay đổi đều đi qua `Invoke-WtTweak`/`Undo-WtTweak` trong runspace riêng |
| `-WhatIf` không ghi gì | Mọi thao tác ghi đều qua `ShouldProcess`; chạy thử liệt kê *những* thao tác sẽ chạy và báo `dryrun`, không lưu trạng thái. Xem trước `W` trong giao diện dùng đúng luồng đó |
| Hoàn tác chính xác | Giá trị registry cũ **kèm kiểu và việc có tồn tại hay không**, kiểu khởi động/trạng thái dịch vụ, trạng thái tác vụ, trạng thái quy tắc tường lửa, danh sách DNS theo từng adapter và tùy chọn Defender được lưu trước khi thay đổi và khôi phục theo thứ tự ngược |
| Thao tác không thể hoàn tác đều được ghi rõ | Gỡ gói, gỡ OneDrive, tải trình cài đặt và xóa dữ liệu là các tinh chỉnh riêng với `-Irreversible`/`-DataDeletion`, `Rollback = None` và phần mô tả nói rõ mất gì |
| Không bao giờ báo thành công cho thao tác thất bại | Mỗi thao tác trả về `succeeded`, `unchanged`, `skipped`, `unsupported`, `dryrun` hoặc `failed`; giá trị được đọc lại để xác minh, mã thoát của tiến trình gốc được kiểm tra, và bảng kết quả lặp lại nguyên văn mọi trạng thái |
| Chính sách của tổ chức được hiển thị | Tinh chỉnh khai báo giá trị chính sách chi phối nó; trạng thái báo `Managed`/`ManagedBy` và mọi giao diện đều hiển thị |
| Không làm giảm bảo vệ | Không có gì tắt Defender, Controlled Folder Access, SmartScreen, nhắc UAC hay ghi log bảo mật khi khởi động hoặc như hệ quả của tinh chỉnh khác. Các tinh chỉnh làm giảm bảo vệ chỉ tồn tại dưới dạng mục riêng, `-Risk High`, gắn cờ `-ReducesProtection`, không bao giờ được áp dụng tự động, và bộ cài có sẵn loại trừ chúng |
| Giữ dữ liệu người dùng | Gỡ phần mềm và xóa dữ liệu là hai tinh chỉnh khác nhau. Tinh chỉnh OneDrive không đụng tới tệp của bạn, và việc gỡ gói chỉ xóa dữ liệu của đúng những gói bạn đã chọn |
| Không có đường tắt thực thi mã | Không `Invoke-Expression`, không tải-rồi-chạy, không chép tệp thực thi vào `System32` (thủ thuật `powershell_temp.exe` trước đây đã bị loại bỏ), không C# nội tuyến |
| Bản tải về được xác minh | `Get-WtVerifiedDownload` bắt buộc `https://`, chỉ chạy ngoài chế độ chạy thử, kiểm tra chữ ký Authenticode với nhà phát hành mong đợi và từ chối tệp nếu không khớp |

## Kiến trúc

```
WindowsTweaker.ps1                  điểm vào (giao diện terminal / dòng lệnh / -Gui)
src/WindowsTweaker/
  WindowsTweaker.psm1               bộ nạp tường minh, danh sách xuất rõ ràng
  Private/                          tiện ích, provider, mô hình tinh chỉnh, hoàn tác
    Common, Logging, Localization, Environment, State, Tweak, Rollback
    Providers/                      Registry, System (dịch vụ/tác vụ/tường lửa), Dns, Appx,
                                    Defender, Installers, Dism, Operations
    Tui/                            giao diện terminal
      Theme, Screen, Input          bảng màu, lưới ô và bộ vẽ, từ vựng phím
      Dialogs                       hộp thoại thông báo/xác nhận/nhập/danh sách
      Worker                        runspace riêng, có thể hủy, phát sự kiện có cấu trúc
      Workflows                     bảng chọn, xem lại, áp dụng/xem trước/hoàn tác, bộ cài
      Tui                           trạng thái, bố cục, xử lý phím, vòng lặp chính
  Public/                           API công khai (danh mục, tinh chỉnh, bộ cài, báo cáo)
  Tweaks/<Nhóm>/*.ps1               định nghĩa tinh chỉnh (siêu dữ liệu + thao tác)
  Data/Strings.<lang>.psd1          bản dịch (en là bản gốc, vi)
  Data/Presets/*.json               bộ cài có sẵn
  Gui/MainWindow.xaml, Gui.ps1      giao diện WPF tùy chọn
tests/                              bộ kiểm thử Pester (engine, provider, CLI, GUI, TUI)
tools/                              Parse-All, Test-Catalog, Test-Insight, Invoke-Validation,
                                    New-FeatureInventory, New-ReleasePackage, Measure-WtWorker
docs/                               danh mục, packs, worker, nhật ký trạng thái, kiểm chứng,
                                    giới hạn, phụ thuộc, bàn phím, ghi chú chuyển đổi
bootstrap/bootstrap.ps1             trình cài đặt chạy dưới dạng văn bản (irm | iex)
deploy/short-url/                   cấu hình nginx cho URL tải ngắn (chỉ chuẩn bị, chưa triển khai)
worker/                             worker Go tùy chọn: cmd/, internal/, go.mod, bin/
samples/example-pack.json           pack mẫu cho -CatalogValidate / -PackImport
licenses/                           nguyên văn giấy phép (MIT gốc, các mô-đun Go của worker)
artifacts/monitoring/               cấu hình scrape mẫu và dashboard Grafana
reference/                          tài liệu tham chiếu gốc (không bao giờ được chạy)
```

Thứ tự nạp là tường minh (tiện ích, provider, giao diện terminal, API công khai, tinh chỉnh,
GUI) và mọi tệp đều được phân tích cú pháp trước khi nạp: một lỗi cú pháp sẽ làm hỏng việc nạp
thay vì âm thầm bỏ qua định nghĩa - đúng kiểu lỗi đã tạo ra các "hàm không tồn tại" ban đầu.

Trình bày, nhận diện trạng thái, lập kế hoạch, thực thi và hoàn tác được tách riêng:

| Phần | Ở đâu | Chỉ đọc |
|---|---|---|
| Trình bày | `Private/Tui/*`, `Private/Gui.ps1`, phần tham số của điểm vào | có |
| Nhận diện trạng thái | `Get-WtTweakState` (mỗi tinh chỉnh có `-Detect`, luôn chỉ đọc) | có |
| Lập kế hoạch | danh sách chờ trong giao diện, và `-WhatIf` trong backend | có |
| Thực thi | `Invoke-WtTweak` / `Undo-WtTweak` qua các provider, trong runspace riêng | không |
| Hoàn tác | kho trạng thái và `Invoke-WtRollback` | không |

## Định nghĩa một tinh chỉnh

Khai báo (registry):

```powershell
New-WtRegistryTweak -Id 'Explorer.FileExtensions' -Category 'Explorer' `
    -Name @{ en = 'File name extensions'; vi = 'Phần mở rộng tên tệp' } `
    -Description @{ en = '...'; vi = '...' } -Impact @{ en = '...'; vi = '...' } `
    -Scope 'User' -Privilege 'None' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Detection @{ Path = 'HKCU:\...\Advanced'; Name = 'HideFileExt'; Map = [ordered]@{ Enabled = @(0); Disabled = @(1) } } `
    -States @{
        Enabled  = @(@{ Kind = 'RegistrySet'; Path = 'HKCU:\...\Advanced'; Name = 'HideFileExt'; Type = 'DWord'; Value = 0 })
        Disabled = @(@{ Kind = 'RegistrySet'; Path = 'HKCU:\...\Advanced'; Name = 'HideFileExt'; Type = 'DWord'; Value = 1 })
    }
```

Tinh chỉnh dạng script (dịch vụ, tác vụ, DNS, gói, trình cài đặt) dùng `New-WtScriptTweak`
với `-Detect` chỉ đọc và `-Apply` gọi các hàm provider. Tinh chỉnh cần tham số khai báo
`-Parameters` (ví dụ `Apps.WindowsFeature` khai báo `FeatureName`); giao diện thu thập chúng
qua bảng chọn và từ chối chạy nếu thiếu. Cả hai hàm khởi tạo được mô tả trong
[docs/MIGRATION-SPEC.md](docs/MIGRATION-SPEC.md), kèm danh sách loại thao tác và provider.

## Danh mục khai báo và gói tinh chỉnh

Tinh chỉnh cũng có thể là dữ liệu. `src/WindowsTweaker/Data/Catalog/builtin.json` khai báo tinh
chỉnh bằng JSON (cùng bảng nhận biết và danh sách thao tác, đủ hai ngôn ngữ, bằng chứng tách
riêng), và **gói tinh chỉnh** cục bộ dùng đúng định dạng đó với một quy tắc thêm: mọi mã phải nằm
trong không gian tên của gói, nên gói đã nhập không bao giờ định nghĩa lại được tinh chỉnh có sẵn.

```text
pwsh -File WindowsTweaker.ps1 -CatalogList -CatalogFilter definitions,lifecycle:Experimental
pwsh -File WindowsTweaker.ps1 -CatalogInspect Privacy.WindowsTips
pwsh -File WindowsTweaker.ps1 -CatalogValidate ./samples/example-pack.json
pwsh -File WindowsTweaker.ps1 -CatalogPlan Privacy.SearchHighlights,Privacy.BingSearch
pwsh -File WindowsTweaker.ps1 -PackImport ./samples/example-pack.json -WhatIf
```

Tài liệu chỉ là dữ liệu: không có gì trong đó được thực thi, tải về hay phân giải, và việc nạp
không đọc hay ghi Windows. Định nghĩa được đăng ký qua đúng hàm khởi tạo cũ, nên xem trước, xem
lại, nhật ký, xác minh và hoàn tác không thay đổi. Điều kiện tiên quyết (`requires`), thứ tự
(`runAfter`) và xung đột (`conflictsWith`) được lập kế hoạch trước khi chạy, và điều kiện đã đạt
sẽ bị loại khỏi danh sách áp dụng thay vì bị ghi lại. Đổi tên hay ngừng dùng một mã vẫn giữ cho mã
đó hoạt động qua sổ chuyển đổi, và mục nhật ký giữ nguyên mã lúc nó được ghi.

Xem [docs/CATALOG.md](docs/CATALOG.md) và [docs/PACKS.md](docs/PACKS.md).

## Xem lại trước khi thay đổi: quét, đề xuất, các chiều trạng thái

Ba bề mặt chỉ đọc, không bề mặt nào áp dụng thay đổi:

```text
pwsh -File WindowsTweaker.ps1 -SanityScan
pwsh -File WindowsTweaker.ps1 -Recommend Privacy -RecommendManual
pwsh -File WindowsTweaker.ps1 -Choices
pwsh -File WindowsTweaker.ps1 -CatalogInspect Privacy.WindowsTips -CatalogDimensions
```

* **Quét kiểm tra** - bộ quy tắc nhỏ kèm nguồn: các giá trị tác vụ MMCSS (làm tròn, giới hạn, bị bỏ
  qua và đã loại bỏ theo tài liệu), cửa sổ nhận TCP cố định, tùy chọn đồng hồ chỉ dành cho gỡ lỗi, và
  các dấu hiệu cần khởi động lại. Một phát hiện không phải lỗi: nó kèm khẳng định trong tài liệu, kỳ
  vọng tương ứng và những gì khẳng định đó không bao quát. Chỉ báo `Clean` khi mọi phép dò bắt buộc
  đều trả lời; phép dò không đọc được sẽ khiến kết quả là `Incomplete`.
* **Đề xuất** - mỗi lần một mục tiêu (Balanced, Responsiveness, Gaming, PowerEfficiency, Privacy),
  kèm giải thích cho từng mục đã xét. Quyền được xét do công cụ quyết định, không do tài liệu: không
  gì làm giảm bảo vệ, không khôi phục chính xác được hoặc rủi ro cao bị tự chọn, và gói đã nhập chỉ
  có thể được đề nghị.
* **Cấu hình, hiệu lực và quyền sở hữu** - ba câu trả lời tách biệt. Ghi thành công và đọc lại chỉ
  chứng minh cấu hình, không chứng minh hành vi, nên trạng thái hiệu lực chỉ được báo từ bằng chứng
  (`Observed`, `Inferred`, hoặc `Unknown` một cách trung thực).
* **Lựa chọn loại trừ nhau** - một thiết lập có nhiều lựa chọn là một tinh chỉnh có nhiều trạng thái,
  nên mỗi lúc chỉ một lựa chọn đang chờ; đổi lựa chọn sẽ thay thế, tính lại phụ thuộc và xung đột, và
  hủy hiệu lực việc xem lại trước đó. Khôi phục đúng trạng thái đã lưu khác với yêu cầu dùng hành vi
  mặc định của Windows, và giao diện ghi nhãn khác nhau.

Trong giao diện terminal: `S` quét, `M` đề xuất, `C` lựa chọn.

## Tài liệu

| Tài liệu | Nội dung |
|---|---|
| [docs/SANITY-SCAN.md](docs/SANITY-SCAN.md) | Quét kiểm tra chỉ đọc: quy tắc, loại phép dò, kết quả, nguồn kèm khẳng định, báo cáo, phần không bao quát |
| [docs/RECOMMENDATIONS.md](docs/RECOMMENDATIONS.md) | Chính sách đề xuất: loại, mức sàn của công cụ, năm mục tiêu, giải thích cho từng quyết định, vì sao không tự áp dụng |
| [docs/STATE-DIMENSIONS.md](docs/STATE-DIMENSIONS.md) | Cấu hình so với hiệu lực so với quyền sở hữu, loại bằng chứng, ranh giới khởi động lại và bốn trạng thái dấu hiệu |
| [docs/CATALOG.md](docs/CATALOG.md) | Danh mục khai báo: định dạng tài liệu, quy tắc nghiêm ngặt, phụ thuộc, điều kiện, bằng chứng, sổ chuyển đổi mã, các bước viết |
| [docs/PACKS.md](docs/PACKS.md) | Gói tinh chỉnh: định dạng, quy tắc không gian tên, quy trình nhập/bật/tắt/xóa, nơi lưu, khôi phục sau khi xóa gói, các bước viết |
| [docs/KEYBOARD.md](docs/KEYBOARD.md) | Toàn bộ phím, hộp thoại, ký hiệu và bố cục, bằng tiếng Anh và tiếng Việt |
| [docs/WORKER.md](docs/WORKER.md) | Worker Go tùy chọn: đặc tả giao thức, cam kết năng lực, giới hạn song song và bộ nhớ, tích hợp PowerShell, build và đóng gói, vị trí giấy phép, cách đo hiệu năng, và các kiểm chứng trên Windows chưa chạy |
| [docs/STATE-JOURNAL.md](docs/STATE-JOURNAL.md) | Nhật ký thao tác: các trường của schema 2, chuyển đổi từ schema 1, độ bền và khóa, cam kết xác minh và đền bù, các lệnh xem lại |
| [docs/FEATURE-INVENTORY.md](docs/FEATURE-INVENTORY.md) | Giao diện, bộ cài và mọi tinh chỉnh: mã, nhóm, phạm vi, quyền, mức ảnh hưởng, khởi động lại, hoàn tác, kèm bảng đối chiếu mô-đun cũ |
| [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md) | Phiên bản PowerShell, yêu cầu về terminal, mô-đun chỉ có trên Windows theo từng tính năng, và điều gì xảy ra khi thiếu phụ thuộc |
| [docs/LIMITATIONS.md](docs/LIMITATIONS.md) | Giới hạn đã biết, các thao tác chỉ hoàn tác một phần, khoảng trống nền tảng |
| [docs/VALIDATION.md](docs/VALIDATION.md) | Chính xác những kiểm chứng đã chạy, kết quả, và những gì chưa chạy được |
| [docs/MIGRATION-SPEC.md](docs/MIGRATION-SPEC.md) | Quy ước nội bộ dùng để chuyển đổi cây mã cũ |
| [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) | Nguồn gốc (Sophia Script for Windows, MIT) và vấn đề giấy phép chưa giải quyết |

## Kiểm thử

```bash
pwsh -NoProfile -File tools/Parse-All.ps1        # phân tích cú pháp mọi script
pwsh -NoProfile -File tools/Test-Catalog.ps1     # bất biến của danh mục
pwsh -NoProfile -Command "Invoke-Pester -Path tests"
pwsh -NoProfile -File tools/Invoke-Validation.ps1  # tất cả các bước trên + analyzer + chứng minh chạy thử
```

Bộ kiểm thử chạy trên mọi nền tảng: các điểm chạm nền tảng (registry, dịch vụ, tác vụ, tường
lửa, DNS, Appx, Defender) được thay bằng bản giả trong bộ nhớ, nên việc lưu trạng thái, hành vi
chạy thử, xác minh, hoàn tác, ghi log, xử lý phụ thuộc và quy tắc chọn gói UWP/DNS đều được
kiểm thử mà không đụng tới hệ thống thật. Giao diện terminal có bộ kiểm thử riêng điều khiển nó
không cần màn hình (nguồn phím và kích thước terminal được tiêm vào), nên tiêu điểm, bộ lọc,
giữ lựa chọn khi đổi kích thước, hộp thoại, bộ cài và cam kết hủy của runspace đều được bao
phủ. Các kiểm chứng tích hợp chỉ có trên Windows được liệt kê trong `docs/VALIDATION.md`.

## Giấy phép

Mã gốc mà dự án này dựa trên là MIT (xem `THIRD-PARTY-NOTICES.md`). Kho này **không kèm giấy
phép riêng** - bản gốc không có, và việc chọn giấy phép cho dự án là quyết định của chủ sở hữu.
Hãy coi `THIRD-PARTY-NOTICES.md` là vấn đề còn bỏ ngỏ.

## Bề mặt bổ sung (lần làm này)

* **Công bố mất năng lực** (`Get-WtCapabilityLoss`) - định nghĩa trong danh mục có thể khai báo
  thứ gì có thể ngừng hoạt động sau một thao tác (mã năng lực ổn định, mô tả đã dịch, loại
  chắc chắn / có điều kiện / chưa biết, tạm thời hay vĩnh viễn, đường khôi phục và giới hạn).
  Bước xem lại tổng hợp công bố này trên toàn bộ lựa chọn đang chờ (khử trùng theo mã năng lực,
  nêu rõ từng hành động gây ra) và hiển thị nó ở khung chi tiết, phần xem trước bộ cài, bước xem
  lại và câu xác nhận cuối. Gói tinh chỉnh có thể thêm công bố nhưng **không bao giờ** được che
  cảnh báo do công cụ sở hữu.
* **Trình duyệt dung lượng đĩa** - trình duyệt thư mục ngay trong terminal (`Tổng quan -> Trình
  duyệt dung lượng đĩa`): chọn gốc tường minh, duyệt một cấp kèm tổng hợp cây con và sắp xếp
  theo dung lượng / số tệp / tên, bộ đệm danh sách có giới hạn, quét chỉ đọc, và xuất TXT/JSON.
  Nó dựa trên năng lực mới của worker là `scan.children` (`Get-WtDirectoryChildren`) với bản dự
  phòng bằng PowerShell; liên kết và reparse point được liệt kê nhưng không bao giờ đi theo, báo
  cáo nêu dung lượng logic và không bao giờ khẳng định số byte đó thu hồi được.
* **Cách ly có nhật ký** - `Tổng quan -> Cách ly`: quét ứng viên chỉ đọc kèm bằng chứng (bản ghi
  cài/gỡ, tệp thực thi di động, tiến trình/dịch vụ đang chạy, hoạt động gần đây, tên nhà cung
  cấp, dấu hiệu dữ liệu người dùng), lựa chọn đã xem lại, chỉ di chuyển trong cùng ổ đĩa, ý định
  khôi phục được ghi trước mọi thao tác di chuyển, xác minh lại nguồn, manifest bền trong kho
  trạng thái, khôi phục không ghi đè ngầm, thử lại bản ghi chưa xử lý, xóa tường minh, và hết hạn
  chỉ để đánh dấu cần xem lại. Byte đã di chuyển được báo riêng với byte được giải phóng.
* **Kiểm kê thiết bị và trình điều khiển** - `Get-WtDeviceInventory` (chỉ đọc): nút thiết bị kèm
  trạng thái do hệ điều hành báo, hardware ID, trình điều khiển đang gắn (INF/nhà cung cấp/phiên
  bản/chữ ký), độ tin cậy của tương quan, cùng danh sách gói trong Driver Store. Không hiện diện
  không bao giờ bị gọi là "không dùng", và kiểm kê chưa đầy đủ không bao giờ cho phép xóa.
* **Quy trình thiết lập có điểm lưu** - `Get-WtSetupPlan`, `New-WtSetupPlan`,
  `Import-WtSetupPlan` (nhập không áp dụng gì), `Get-WtSetupPlanPreview`, `Start-WtSetupPlan`,
  `Resume-WtSetupPlan`, `Remove-WtSetupPlanResume`: kế hoạch có phiên bản, các bước chỉ là mã
  tinh chỉnh/trạng thái trong danh mục, bước phụ thuộc dừng khi bước trước lỗi, không tự thử lại
  kết quả chưa chắc chắn, số lần khởi động lại/thử lại có giới hạn, và đăng ký tiếp tục gắn với
  danh tính nên từ chối mọi sửa đổi.
* **Hồ sơ quyền riêng tư và các khung hoạt động** - `Get-WtPrivacySummary` báo cáo siêu dữ liệu
  dạng tùy chọn/chính sách theo từng tinh chỉnh (khả năng sửa trong Settings, phiên bản/bản dựng,
  hệ quả chẩn đoán) như dữ liệu; `Get-WtPrivacyActivity` liệt kê các khung camera / micro / vị trí
  / chụp màn hình, tự báo `Unavailable` trên bản dựng này thay vì bịa log.
* **Trình xem cài đặt nguồn và cam kết SRUM** - `Get-WtPowerSettings` (chỉ đọc, `powercfg`) báo
  cáo kế hoạch đang hoạt động và giá trị AC/DC; `Get-WtSrumHistory` nêu rõ cam kết khả dụng của
  SRUM mà không bật dịch vụ và không coi bản ghi thiếu là "không có hoạt động".
* **Lệnh "Copy path" của Explorer** - `Explorer.CopyPathCommand` (mục menu ngữ cảnh cho người
  dùng hiện tại, được công cụ xem xét, hoàn tác khôi phục chính xác; placeholder `%W` có trích
  dẫn, không có hook toàn cục).

Các kiểm thử mới nằm ở `tests/CapabilityLoss.Tests.ps1`, `tests/Quarantine.Tests.ps1`,
`tests/Devices.Tests.ps1`, `tests/SetupPlans.Tests.ps1` và `tests/PrivacyPowerTools.Tests.ps1`;
worker Go được thêm `scan.children` cùng bộ kiểm thử riêng.

## Ghi công

Các bề mặt bổ sung được thiết kế với những dự án tham chiếu dưới đây chỉ như nguồn cảm hứng về
sản phẩm: `windows-11-practical-scripts`, `Windows-Telemetry-OFF`, `remove-hidden-devices`,
`debora`, `darkhub-suite`, `PrivacyPenguin` (chỉ đọc tài liệu, không bao giờ xem hay dùng lại mã
nguồn), `WinSpectorPro`, `ZapTweaks` và `win-Tweak`. Không có mã nào từ các dự án này được nhập
vào; worker và mọi mô-đun PowerShell ở đây là mã gốc, và tệp thông báo bên thứ ba không thay đổi.

## Không gian giám sát (quan sát cục bộ)

`B` (hoặc hàng Tổng quan -> Giám sát) mở chế độ giám sát điều khiển bằng bàn phím: các bảng
Tổng quan, Mạng và Thay đổi với đồ thị chuỗi thời gian, điều khiển khoảng thời gian/làm mới,
chọn card mạng và ổ đĩa, xem chi tiết từng panel, quy tắc cảnh báo cục bộ, và dòng thời gian
thay đổi liên kết tới các khung nhật ký/xác minh sẵn có. `F` đóng băng hiển thị (việc thu thập
vẫn tiếp tục), `P` tạm dừng thu thập, `T` đổi khoảng thời gian, `Enter` xem panel đang chọn.

Cam kết dữ liệu (metric.snapshot): gauge/counter có kiểu kèm đơn vị, mốc thời gian UTC, chiều có
giới hạn, nhà cung cấp, chất lượng (valid/unavailable/unsupported/stale/error) và mã lỗi ổn định.
Dữ liệu thiếu không bao giờ bị thay bằng số 0; tốc độ counter dùng thời gian trôi qua đơn điệu và
không bao giờ âm sau khi reset; byte/s luôn khác bit/s. Lịch sử bị giới hạn trong bộ nhớ (256
chuỗi x 4096 mẫu, giới hạn số lượng giá trị của chiều, khoảng trống được giữ nguyên).

Worker Go được thêm `metric.snapshot` (trên Linux đọc /proc và /sys; các provider trên Windows tự
báo unsupported và thu thập trên Windows do provider CIM của PowerShell đảm nhiệm). Bảng điều
khiển là tài liệu JSON có phiên bản, được kiểm tra theo danh sách cho phép (không nhúng mã);
nhập/xuất chỉ cục bộ. Cảnh báo là quy tắc khai báo với thời gian giữ, trễ, ngữ nghĩa dữ liệu
thiếu và ghi nhận/tắt tiếng tường minh; chúng không bao giờ thay đổi hệ thống.

Đo trên máy này (CachyOS, PowerShell 7.6.9, amd64): 20 chu kỳ nhanh = 592 ms (29,6 ms/chu kỳ, 420
mẫu) với backend PowerShell; 968 ms (48,4 ms/chu kỳ) với chế độ Auto dùng worker Go, worker chiếm
~7,1 MB bộ nhớ thường trú. Đây là điều kiện đo được, không phải bảo đảm.

### Quan sát sâu hơn (tùy chọn, vòng này)

- **Số liệu bền vững** (`R` trong không gian làm việc, hoặc `Enable-WtMetricRecording`): worker Go
  là bộ ghi SQLite duy nhất (modernc.org/sqlite, thuần Go, BSD-3-Clause). Schema v1 với chuyển
  đổi tường minh, ghi theo lô trong giao dịch, hàng đợi có giới hạn với áp lực ngược kiểu bỏ-và-
  đếm, thời gian lưu cấu hình được (báo trước khi xóa, không bao giờ đụng bản ghi khôi phục),
  truy vấn khoảng có giới hạn, và xử lý tường minh hỏng/khóa/đầy đĩa — cơ sở dữ liệu hỏng không
  bao giờ bị thay thế ngầm.
- **Bảng điều khiển tùy biến** (`E` trong không gian làm việc): thêm/xóa panel được hỗ trợ, đổi
  thứ tự, đặt kích thước, lưu bố cục có tên, nhân bản, khôi phục về mẫu có sẵn, và nhập/xuất cục
  bộ với kiểm tra nghiêm ngặt (số liệu/phép tổng hợp nằm trong danh sách cho phép, không thực thi
  nhúng). Bố cục đã lưu không bao giờ ghi đè bố cục đang chạy khi nhập không hợp lệ.
- **So sánh hai khoảng** (`C`): quy trình khoảng nền so với khoảng đối chiếu với độ phủ, số mẫu,
  đơn vị, phép tổng hợp, trung vị/tứ phân vị, kết luận theo hướng (tốt lên/xấu đi/chưa kết
  luận/chưa đủ) và xuất JSON tùy chọn. Không bao giờ suy ra quan hệ nhân quả từ việc hai thứ xảy
  ra gần nhau.
- **Prometheus exporter tùy chọn**: mặc định tắt, chỉ loopback, cổng được kiểm tra, `/metrics` chỉ
  đọc dùng Prometheus Go client chính thức (Apache-2.0). Số liệu nằm trong danh sách cho phép, có
  tiền tố `wt_`, giới hạn số lượng; không có PID, đường dẫn, token, session ID hay operation ID
  trong nhãn; phép dò lỗi không bao giờ được xuất thành 0; chuỗi cũ bị xóa thay vì hiển thị như
  mới. Cấu hình scrape mẫu và JSON dashboard Grafana nằm ở `artifacts/monitoring/`.
- **Nguồn dữ liệu Prometheus từ xa** (`O`): cấu hình endpoint + kiểm tra kết nối, mẫu truy vấn
  được tuyển chọn (không sửa truy vấn tùy ý), phản hồi/thời gian chờ có giới hạn, nhãn không tin
  cậy được làm sạch, và nhãn nguồn `[prom]` để chuỗi từ xa không bao giờ bị trộn lẫn ngầm với
  chuỗi cục bộ.
- **Lịch sử cảnh báo**: các chuyển trạng thái được lưu (pending/firing/resolved/normal) kèm mã/
  phiên bản quy tắc, mốc thời gian, bằng chứng và danh tính nguồn dữ liệu; chỉ ghi khi trạng thái
  đổi (không trùng lặp mỗi lần làm mới, không gửi thông báo ra ngoài).

### Quan sát nhiều máy, sự cố, playbook và gói hỗ trợ

- **Đội máy (`1`)** — tổng quan nhiều máy chỉ đọc từ các nguồn Prometheus được cấu hình tường
  minh (phát hiện target qua `label_values(up, instance)`; danh tính ổn định = nguồn dữ liệu +
  instance; trạng thái healthy/failed-scrape/stale/missing-target/unreachable-ds/unknown; số
  nguồn/target/khoảng truy vấn đều có giới hạn).
- **Không gian sự cố (`2`)** — dòng thời gian hợp nhất cho một cảnh báo hoặc một khoảng: chuyển
  trạng thái cảnh báo, số liệu/chất lượng liên quan, thao tác trong nhật ký, drift, lỗi bộ thu
  thập, dấu hiệu khởi động lại/uptime-reset. Loại bằng chứng (observed/inferred/note/unavailable)
  và độ bất định của đồng hồ được giữ nguyên; ghi chú không bao giờ viết lại bản ghi nhật ký; có
  thể lưu/mở lại và xuất phần điều tra.
- **Playbook chẩn đoán (`3`)** — playbook có phiên bản, khai báo, chỉ đọc cho mạng chập chờn, đĩa
  gần đầy, dùng tài nguyên cao, xác minh thất bại, và khôi phục đang chờ/thất bại. Chỉ dùng phép
  dò trong danh sách cho phép; không nhúng script; không có "sửa tất cả"; phần khắc phục quay về
  đúng công cụ đã được xem xét sẵn có.
- **Gói hỗ trợ (`4`)** — xem trước rồi xuất tường minh gói hỗ trợ cục bộ đã làm sạch (manifest kèm
  hash; mặc định loại trừ thông tin đăng nhập, khóa, tên người dùng, tên máy, số sê-ri, đường dẫn
  riêng tư, toàn bộ dòng lệnh, nội dung tệp, bí mật khôi phục; xem trước việc che định danh; kích
  thước/số mục có giới hạn; nhập an toàn với đường dẫn và coi là bằng chứng lịch sử, không đáng
  tin).
- **Cấu hình giám sát có phiên bản** — các bản sửa chỉ ghi thêm cho bảng điều khiển/quy tắc cảnh
  báo/playbook, kèm so sánh trước khi kích hoạt, kích hoạt tường minh, hoàn nguyên, kiểm tra tương
  thích và ghi công bằng chứng cho đúng bản sửa đã tạo ra nó.
