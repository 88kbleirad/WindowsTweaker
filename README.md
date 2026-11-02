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
- **Ứng dụng desktop WinUI 3** (thay thế console làm giao diện chính khi build) giữ nguyên
  phong cách terminal: phông đơn khoảng cách, panel vuông, bảng gọn, nhãn trạng thái rõ ràng,
  điều hướng bằng bàn phím và bảng màu Catppuccin Mocha. Giao diện này nói chuyện với cùng một
  động cơ PowerShell qua một giao thức có phiên bản (cầu nối); nó không nhúng terminal, trình
  duyệt hay WebView. Xem [docs/FRONTEND.md](docs/FRONTEND.md) và
  [docs/BUILD-WINUI.md](docs/BUILD-WINUI.md).
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

## Ứng dụng WinUI (dùng nhanh)

Frontend WinUI 3 được build riêng (xem [docs/BUILD-WINUI.md](docs/BUILD-WINUI.md)); nó không
yêu cầu quyền quản trị để mở và duyệt. Cách dùng tóm tắt:

1. **Mở** bản đã build (`WindowsTweaker.WinUI.exe` hoặc gói MSIX). Thanh đầu hiện môi trường,
   backend và nút **Nâng quyền** xuất hiện khi phiên hiện tại không có quyền quản trị (chỉ cần
   cho các thao tác đánh dấu cần quyền; UAC hỏi khi nâng).
2. **Tinh chỉnh** (trái): gõ `/` hoặc `Ctrl+F` để tìm, chọn dòng, chọn trạng thái đích, bấm
   **Thêm vào duyệt** (hoặc `Ctrl+Enter`).
3. **Duyệt** (trái): xem danh sách đang chờ, **Xem trước** để thấy từng đích và ràng buộc,
   bật **Chạy thử** nếu chỉ muốn báo cáo, rồi **Áp dụng** (xác nhận; engine đọc lại trạng thái
   ngay trước khi ghi). Kết quả từng mục hiện ở bảng phía dưới kèm dấu xác minh đọc lại.
4. **Lịch sử** (trái): xem lịch sử, nhật ký và các thao tác bị ngắt; chọn một dòng rồi
   **Khôi phục** để hoàn tác về đúng trạng thái đã chụp.
5. **Đóng cửa sổ** khi có thao tác đang chạy: cửa sổ hỏi rõ — đợi xong, hủy phần đang chờ
   rồi đợi ranh giới an toàn, hoặc ở lại. Không bao giờ giết backend giữa chừng khi đang ghi.

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
| `N` | màn hình chẩn đoán & kích hoạt Windows (`A` kích hoạt, `S` cài đặt & chi tiết) |
| `L` / `I` | đổi ngôn ngữ / chọn chế độ biểu tượng |
| `?` | toàn bộ bảng phím và các nguyên tắc an toàn |
| `Q` (`Ctrl+C`) | thoát - thay đổi đang chờ và thao tác đang chạy luôn được nêu rõ |

Toàn bộ phím, kể cả phím của không gian giám sát và các hộp thoại, nằm ở
[docs/KEYBOARD.md](docs/KEYBOARD.md).

## Kích hoạt Windows (công cụ bên ngoài: Microsoft Activation Scripts)

`N` mở màn hình **Cấp phép & kích hoạt**. Đây là nơi duy nhất để kích hoạt Windows bằng công cụ bên
ngoài **Microsoft Activation Scripts (MAS)**: WindowsTweaker không nhúng, không sửa và không tự chạy
MAS - nó tải đúng một tệp từ kho chính thức tại một commit cố định (tag `3.12`, commit
`40c74d0d7f42146b1dd1ab59b5c7e836d6a56d1f`), kiểm chứng kích thước, mã blob git của thượng nguồn
và SHA-256 đã ghi lại, rồi chạy đúng một phương pháp kích hoạt Windows theo yêu cầu của bạn.

Cách dùng:

1. `N` mở màn hình chính. Màn hình cho biết phiên bản đã cài, trạng thái kích hoạt, phương pháp đã
   chọn và mức sẵn sàng của công cụ. Chỉ xem thì không có gì được tải về hay chạy.
2. Chọn phương pháp: nhấn `S` để mở màn hình cài đặt & chi tiết, rồi nhấn `1` (HWID), `2`
   (TSforge) hoặc `3` (Online KMS). Mỗi phương pháp được hiển thị kèm mô hình thời hạn (vĩnh viễn /
   có thời hạn) và yêu cầu Internet theo tài liệu thượng nguồn; chỉ những phương pháp tương thích với
   phiên bản đã cài mới có thể được chọn để chạy. `Esc` quay lại màn hình chính.
3. Trên màn hình chính, nhấn `A` để **kích hoạt Windows**: hành động chạy đúng phương pháp đã chọn,
   với đúng tham số được tài liệu hóa của phương pháp đó, trong cửa sổ console riêng - menu tương tác
   của MAS không bao giờ xuất hiện và không có phím nào được gửi tới nó. Các thao tác Office, ESU,
   đổi phiên bản, KMS-host và reset không thể truy cập từ đây.
4. Nếu tệp đã ghim chưa được tải về, `A` sẽ hỏi tải và xác minh nó trước (tiến trình hiện rõ số
   byte, `Esc` hủy; khi hủy thì không chạy gì). Nếu phiên hiện tại chưa có quyền quản trị, Windows
   tự hiện hộp thoại nâng quyền; từ chối thì không có gì được chạy và không thử lại.
5. Sau khi thao tác kết thúc, WindowsTweaker đọc lại hồ sơ cấp phép và báo cáo: trạng thái trước/sau,
   hiệu lực còn lại do Windows báo, mã lỗi có cấu trúc của dịch vụ Bảo vệ Phần mềm (nếu có), và
   liệu mức hoàn tất có xác định được hay không. Mã thoát của tiến trình **không** phải bằng chứng đã
   kích hoạt; nếu không quan sát được lúc kết thúc (ví dụ script đã khởi chạy lại chính nó), kết quả
   được báo là “đã khởi chạy; chưa xác định hoàn tất” thay vì thành công. Khi một thao tác có thể còn
   đang chạy, `A` sẽ từ chối lần thứ hai.
6. `S` còn là nơi chứa mọi chi tiết của bản tải: nguồn gốc, URL, SHA-256, mã blob git, giấy phép,
   cập nhật (`U`), tài liệu (`V`), xóa bản sao (`R`), và yêu cầu kích hoạt bằng giấy phép đã cài
   (slmgr /ato, phím `T`). `R` chỉ xóa tệp đã tải và bản ghi xuất xứ; các thay đổi cấp phép mà công
   cụ đã thực hiện vẫn giữ nguyên.

Ở chế độ chạy thử (`W` trên màn hình chính), `A`, `D`, `U`, `R` chỉ hiện đúng những gì sẽ làm -
phương pháp và dòng lệnh sẽ chạy, tệp và URL sẽ tải, danh sách tệp sẽ xóa - và không tải, không
chạy, không xóa gì; việc kích hoạt bị từ chối ngay cả khi bạn đã xác nhận.

Lưu ý: kích hoạt không đồng nghĩa với quyền sử dụng hợp pháp. Nhật ký đăng ký của WindowsTweaker
**không** hoàn tác được thao tác kích hoạt của công cụ này. Việc này không bao giờ nằm trong preset,
batch, tác vụ khởi động, chính sách giám sát hay sửa chữa tự động, không vô hiệu hóa Defender, không
thêm ngoại lệ bảo mật và không khởi động lại máy.

Chi tiết đầy đủ (bằng chứng thượng nguồn cho các tham số, chuỗi kiểm chứng, giấy phép GPL-3.0, các
giới hạn đã kiểm chứng): [docs/EXTERNAL-TOOLS.md](docs/EXTERNAL-TOOLS.md).

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
