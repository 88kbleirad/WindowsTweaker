# WindowsTweaker

Tùy biến Windows có thể xem lại và hoàn tác, điều khiển từ terminal.

**Tiếng Việt** | [English](README.en.md)

Mỗi thay đổi là một **tinh chỉnh (tweak)**: có siêu dữ liệu (phạm vi, quyền cần thiết, điều kiện
hệ điều hành, mức ảnh hưởng, yêu cầu khởi động lại, khả năng hoàn tác), một bộ dò chỉ đọc, và một
bước áp dụng luôn chụp lại trạng thái cũ trước khi ghi. Bạn có thể chạy thử, xem lại, áp dụng, rồi
hoàn tác về đúng trạng thái đã tồn tại - không phải về một giá trị mặc định cứng.

## Công cụ làm được gì

- **Tùy biến Windows kèm xem trước và hoàn tác theo từng thao tác.** 113 tinh chỉnh trong 10 nhóm
  (riêng tư, bảo mật, Explorer, taskbar, ứng dụng, cập nhật, hệ thống, mạng, cá nhân hóa, bảo trì).
  `W` chạy thử danh sách đang chờ, `A` xem lại từng đích, và nhật ký giữ trạng thái đã chụp để `R`
  khôi phục. Các tinh chỉnh không thể hoàn tác đều được ghi rõ và không bao giờ tự động áp dụng.
- **Giao diện terminal điều khiển bằng bàn phím, kèm dòng lệnh tự động hóa.** Chạy bằng `pwsh`,
  không cần cài đặt và không có dịch vụ nền. Cùng backend đó cũng chạy một cửa sổ WPF tùy chọn
  (chỉ trên Windows 10/11).
- **Chẩn đoán và kiểm tra lệch cấu hình.** Quét kiểm tra chỉ đọc (`S`), đề xuất theo một mục tiêu
  kèm lý do cho từng quyết định (`M`), xác minh và khôi phục (`V`), công bố mất năng lực cho những
  thứ có thể ngừng hoạt động sau một thay đổi, và nhật ký theo từng thao tác kèm so sánh giá trị đã
  áp dụng với giá trị hiện tại.
- **Phân tích dung lượng và cách ly.** Trình duyệt thư mục ngay trong terminal có tổng hợp dung
  lượng (backend PowerShell, hoặc worker Go tùy chọn để nhanh hơn), và quy trình cách ly có nhật
  ký với bằng chứng, chỉ di chuyển trong cùng ổ đĩa và manifest bền vững.
- **Giám sát cục bộ, kèm tích hợp Prometheus và Grafana tùy chọn.** Bảng điều khiển dùng bàn phím
  trên lịch sử trong bộ nhớ có giới hạn, quy tắc cảnh báo khai báo, ghi SQLite tùy chọn, so sánh
  hai khoảng thời gian, và các khung đội máy / sự cố / playbook / gói hỗ trợ ở mức sớm. Tình trạng
  từng phần không đồng đều và đã được ghi rõ: exporter Prometheus có trong worker nhưng chưa được
  bộ thu thập đưa dữ liệu vào, và các khung đội máy/sự cố/playbook/gói hỗ trợ là phần ít được chạy
  thử nhất - xem [docs/MONITORING.md](docs/MONITORING.md) và
  [docs/MULTI-HOST.md](docs/MULTI-HOST.md).
- **Danh mục khai báo và gói tinh chỉnh cục bộ.** Tinh chỉnh có thể là dữ liệu (JSON) thay vì mã
  PowerShell, và một **gói tinh chỉnh** cục bộ có thể thêm định nghĩa trong không gian tên riêng
  nhưng không thể định nghĩa lại một tinh chỉnh có sẵn.
- **Chẩn đoán cấp phép & kích hoạt, kèm một công cụ bên ngoài tường minh.** `N` mở khu vực chỉ-đọc
  về trạng thái cấp phép Windows và Office (sản phẩm đang hoạt động, kênh cấp phép, trạng thái gia
  hạn, thời gian hệ thống, cấu hình do tổ chức quản lý), xuất báo cáo đã ẩn dữ liệu nhạy cảm, và yêu
  cầu kích hoạt bằng `slmgr /ato` sau khi nêu rõ mục đích. Trong cùng khu vực đó, `M` mở
  **Microsoft Activation Scripts** như một công cụ bên ngoài: tải đúng một tệp từ kho chính thức tại
  một commit cố định, kiểm chứng rồi chạy khi bạn yêu cầu - không nhúng mã, không tự chạy, không nằm
  trong preset hay batch. Xem [docs/EXTERNAL-TOOLS.md](docs/EXTERNAL-TOOLS.md).

## Tình trạng và yêu cầu

| Yêu cầu | Chi tiết |
|---|---|
| Hệ điều hành | **Windows 10 22H2 hoặc Windows 11** (nền tảng mục tiêu). Mọi tinh chỉnh đều khai báo `-SupportedOS`/`-MinBuild`; trên bản dựng khác nó báo `unsupported` kèm lý do thay vì đoán |
| PowerShell | **Windows PowerShell 5.1 (có sẵn trong Windows) và PowerShell 7.4-7.6.** `#Requires -Version 5.1` chặn các bản cũ hơn; PowerShell 7.4-7.6 là bản được dự án xác nhận đầy đủ. Chi tiết theo từng runtime: [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) |
| Quyền quản trị | Chỉ cần cho các tinh chỉnh khai báo `-Privilege Admin`; việc duyệt, xem trước và chạy thử không bao giờ cần |
| Trên Linux | Mô-đun nạp được và các bề mặt chỉ đọc chạy được (đây cũng là nơi bộ kiểm thử chạy), nhưng mọi tinh chỉnh mức hệ thống đều báo `unsupported`: hãy coi Linux là nơi xem lại và phát triển, không phải nơi áp dụng thay đổi |
| Kiểm chứng tích hợp trên Windows | **Chưa chạy.** Không có máy Windows nào để kiểm chứng: hành vi thật của registry, dịch vụ, tác vụ định kỳ, tường lửa, DNS, Appx, Defender, DISM và giao diện WPF đều chưa từng được chạy. Xem [docs/VALIDATION.md](docs/VALIDATION.md) |

Vài điều cần biết trước khi áp dụng:

- **Hoàn tác theo từng thao tác, không phải ảnh chụp toàn hệ thống.** Giá trị và khóa registry,
  loại khởi động và trạng thái dịch vụ, trạng thái tác vụ định kỳ, trạng thái nhóm tường lửa, danh
  sách DNS theo từng card mạng và tùy chọn Defender được chụp trước khi thay đổi và khôi phục lại
  sau đó. Những đích không có bộ đọc để đối chiếu được ghi là *không xác minh được*, không bao giờ
  ghi là đã xác minh. Điểm khôi phục hệ thống không bao giờ được tạo ngầm; muốn có thì dùng
  `-IncludeRestorePoint`.
- **Có những thao tác không thể hoàn tác.** Gỡ gói ứng dụng, gỡ OneDrive, tải và cài trình cài đặt,
  và xóa dữ liệu là những tinh chỉnh riêng, được đánh dấu `-Irreversible`/`-DataDeletion` với
  `Rollback = None`; các bộ cài có sẵn đều loại chúng ra.
- **Giám sát chỉ đo, không hứa.** Không gian giám sát báo cáo quan sát kèm chất lượng và loại bằng
  chứng; không có cam kết nào về việc tăng hiệu năng.

## Bắt đầu nhanh

Chạy từ thư mục gốc của kho. **Cả Windows PowerShell 5.1 lẫn PowerShell 7 đều khởi động được**;
cùng một giao diện, cùng một nhật ký, cùng khả năng hoàn tác.

```powershell
# Windows PowerShell 5.1 (console có sẵn trong Windows) - chạy trực tiếp
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WindowsTweaker.ps1

# PowerShell 7.4-7.6 - cùng giao diện, đủ tính năng đã kiểm chứng
pwsh -NoProfile -File .\WindowsTweaker.ps1
pwsh -NoProfile -File .\WindowsTweaker.ps1 -Language vi     # giao diện tiếng Việt
pwsh -NoProfile -File .\WindowsTweaker.ps1 -Status          # chỉ đọc: máy này làm được gì?
pwsh -NoProfile -File .\WindowsTweaker.ps1 -Id Privacy.AdvertisingId -State Disabled -WhatIf
```

Lệnh đầu tiên và hai lệnh `pwsh` đầu tiên mở giao diện. Lệnh chạy thử in ra mọi thao tác sẽ thực
hiện và không ghi gì; bỏ `-WhatIf` để áp dụng thay đổi và giữ lại trạng thái cũ cho việc hoàn tác.

`-ExecutionPolicy Bypass` ở trên chỉ áp dụng cho **tiến trình đó** (không đổi chính sách của máy,
không ghi gì vào registry). Nếu chính sách đã cho phép chạy script, bỏ cờ này đi.

Không có PowerShell 7? Bootstrap sẽ tự tìm, và chỉ hỏi một lần trước khi cài bằng `winget` (nguồn
chính thức của Microsoft). Từ chối vẫn chạy được trên 5.1. Cài thủ công:
<https://aka.ms/powershell-release?tag=stable> (chọn gói đúng kiến trúc x64/ARM64).

Muốn biết runtime hiện tại có gì:
`powershell.exe -NoProfile -File .\WindowsTweaker.ps1 -RuntimeReport` (chỉ đọc, in cả hai thứ
tiếng Việt và tiếng Anh).

Cách cài bằng `irm | iex` đã có script và giá trị mặc định trỏ tới repository thật
(`88kbleirad/WindowsTweaker`), và bản release `v1.0.0` đã được công bố: bootstrap gọi
`releases/latest`, tải archive đúng hệ điều hành/kiến trúc, đối chiếu SHA-256 với `checksums.txt`
của release, đưa vào thư mục staging rồi mở giao diện. Repository chưa công bố release vẫn nhận
`HTTP 404` và báo lỗi thay vì cài thứ chưa được kiểm chứng. Lệnh một dòng đã tài liệu hoá:

```powershell
irm "https://raw.githubusercontent.com/88kbleirad/WindowsTweaker/main/bootstrap/bootstrap.ps1" | iex
```

Xem [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md) để biết script kiểm chứng những gì, và
[docs/RELEASE.md](docs/RELEASE.md) để biết một bản release gồm những tệp nào.

## Phím thiết yếu

| Phím | Tác dụng |
|---|---|
| `Lên`/`Xuống`, `PageUp`/`PageDown` | di chuyển trong danh sách |
| `Trái`/`Phải` hoặc `Tab` | đổi giữa các khung |
| `Space` | thêm hoặc bỏ dòng hiện tại khỏi danh sách đang chờ |
| `Enter` | mở chi tiết và các hành động (chọn trạng thái, nhập tham số) |
| `A` | xem lại các thay đổi đang chờ - nơi duy nhất lựa chọn được áp dụng |
| `W` | xem trước (chạy thử) các thay đổi đang chờ, không ghi gì |
| `/` | tìm kiếm; truy vấn bắt đầu bằng `@` để lọc định nghĩa (`@risk:High`, `@scope:Machine`, ...) |
| `S` / `M` / `C` | quét kiểm tra / đề xuất / các cài đặt có nhiều lựa chọn |
| `V` | xác minh và khôi phục: lệch cấu hình, thao tác bị ngắt, khôi phục, xuất |
| `B` | không gian giám sát |
| `N` | chẩn đoán cấp phép & kích hoạt (trong đó `M` mở công cụ bên ngoài Microsoft Activation Scripts) |
| `L` / `I` | đổi ngôn ngữ / chọn chế độ biểu tượng |
| `?` | toàn bộ bảng phím và các nguyên tắc an toàn |
| `Q` (`Ctrl+C`) | thoát - thay đổi đang chờ và thao tác đang chạy luôn được nêu rõ |

Toàn bộ phím, kể cả phím của không gian giám sát và các hộp thoại, nằm ở
[docs/KEYBOARD.md](docs/KEYBOARD.md).

## Microsoft Activation Scripts (công cụ bên ngoài)

`N` mở khu vực **Chẩn đoán cấp phép & kích hoạt**; trong đó `M` mở công cụ bên ngoài **Microsoft
Activation Scripts (MAS)**. WindowsTweaker không nhúng, không sửa và không tự chạy MAS: nó tải đúng
một tệp từ kho chính thức tại một commit cố định (tag `3.12`, commit
`40c74d0d7f42146b1dd1ab59b5c7e836d6a56d1f`), kiểm chứng kích thước, mã blob git của thượng nguồn và
SHA-256 đã ghi lại, rồi chỉ chạy khi bạn yêu cầu.

Cách dùng:

1. `N` rồi `M` để mở công cụ bên ngoài. Chỉ xem thì không có gì được tải về hay chạy.
2. `D` tải bản đã cố định; hộp thoại xác nhận mặc định là **Không**. Việc tải chạy nền: giao diện
   vẫn nhận phím, dòng tiến trình báo đúng số byte đã nhận, `Esc` hủy lần tải đang chạy, và nhấn
   `D`/`U` lần nữa trong lúc đang tải sẽ bị từ chối. `U` tìm bản phát hành mới hơn và hiện tag,
   commit, kích thước trước khi tải bất cứ thứ gì.
3. `L` chạy công cụ trong cửa sổ console riêng. Nếu phiên hiện tại chưa có quyền quản trị, Windows sẽ
   hiện hộp thoại nâng quyền; từ chối thì không có gì được chạy và không thử lại. WindowsTweaker
   không gửi phím, không chọn sẵn phương thức kích hoạt và không chạy lệnh kích hoạt nào - bạn tự
   chọn trong menu của MAS.
4. Sau khi công cụ kết thúc, WindowsTweaker đọc lại trạng thái cấp phép và nói rõ có đọc được hay
   không. Mã thoát của tiến trình **không** phải bằng chứng đã kích hoạt.
5. `R` xóa bản sao trên máy (tệp đã tải, phần tệp tạm còn lại và bản ghi xuất xứ). `V` mở tài liệu
   thượng nguồn trong trình duyệt. `Esc` quay lại phần chẩn đoán.

Ở chế độ chạy thử (`W` trên màn hình chính), các phím `D`, `U`, `L`, `R` chỉ hiện đúng những gì sẽ
làm - tệp và URL sẽ tải, dòng lệnh sẽ chạy, danh sách tệp sẽ xóa - và không tải, không chạy, không
xóa gì; riêng việc chạy công cụ bị từ chối ngay cả khi bạn đã xác nhận.

Lưu ý: MAS có thể thay đổi trạng thái cấp phép của Windows/Office; thời hạn phụ thuộc phương thức bạn
chọn trong công cụ (không phải mọi phương thức đều có thời hạn, cũng không phải mọi phương thức đều
vĩnh viễn), và **kích hoạt không đồng nghĩa với quyền sử dụng hợp pháp**. Nhật ký đăng ký của
WindowsTweaker **không** hoàn tác được thao tác kích hoạt của công cụ này. Công cụ nằm ngoài hoàn toàn
mọi preset, batch, tác vụ khởi động và chính sách giám sát.

Chi tiết đầy đủ (nguồn gốc, chuỗi kiểm chứng, giấy phép GPL-3.0, các giới hạn đã kiểm chứng):
[docs/EXTERNAL-TOOLS.md](docs/EXTERNAL-TOOLS.md).

## Đọc tiếp ở đâu

| Mảng | Tài liệu |
|---|---|
| Cài đặt, khởi chạy, dòng lệnh và API mô-đun | [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md), [docs/CLI.md](docs/CLI.md), [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md) |
| Giao diện và phím | [docs/KEYBOARD.md](docs/KEYBOARD.md) |
| Danh mục, gói tinh chỉnh và từng tinh chỉnh | [docs/CATALOG.md](docs/CATALOG.md), [docs/PACKS.md](docs/PACKS.md), [docs/FEATURE-INVENTORY.md](docs/FEATURE-INVENTORY.md) |
| Nhật ký, hoàn tác và giới hạn an toàn | [docs/STATE-JOURNAL.md](docs/STATE-JOURNAL.md), [docs/LIMITATIONS.md](docs/LIMITATIONS.md) |
| Giám sát, exporter và nhiều máy | [docs/MONITORING.md](docs/MONITORING.md), [docs/MULTI-HOST.md](docs/MULTI-HOST.md) |
| Kiến trúc, worker và kiểm chứng | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/WORKER.md](docs/WORKER.md), [docs/VALIDATION.md](docs/VALIDATION.md) |

Danh sách đầy đủ nằm ở [mục lục tài liệu](docs/README.md). Chi tiết chẩn đoán ở
[docs/SANITY-SCAN.md](docs/SANITY-SCAN.md), [docs/RECOMMENDATIONS.md](docs/RECOMMENDATIONS.md) và
[docs/STATE-DIMENSIONS.md](docs/STATE-DIMENSIONS.md).
