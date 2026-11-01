# TUI performance profiles and batch-state guidance

This page is the user-facing reference for the two most-asked questions in VM guests:
how to pick a lighter presentation profile, and how to inspect what a failed batch did.

## Tiếng Việt — cách dùng

### Chọn hồ sơ hiệu năng (chỉ ảnh hưởng trình bày)

```powershell
# Giao diện: nhấn Ctrl+P để mở trình chọn hồ sơ.
#   Tự động (mặc định): Cân bằng nếu terminal hỗ trợ VT; Ít tài nguyên nếu là
#                       console cổ điển (Windows PowerShell 5.1, không xử lý VT).
#   Cân bằng: mặc định phong phú (biểu tượng dòng, thu thập nền nhanh hơn).
#   Ít tài nguyên: dành cho máy ảo (QEMU/KVM, VMware, VirtualBox) có đầu ra console
#                  chậm: tắt biểu tượng dòng, vẽ lại khi rảnh ít hơn, lô phím nhỏ
#                  hơn, thu thập nền chậm hơn.
#
# Dòng lệnh:
pwsh -File WindowsTweaker.ps1 -PerfProfile Low-resource
# hoặc qua biến môi trường:
$env:WT_TUI_PERF_PROFILE = 'Low-resource'

# Hồ sơ KHÔNG BAO GIỜ chạm vào điện năng, bảo mật, dịch vụ, mạng, driver hoặc
# cấu hình hypervisor. Nó không làm yếu nhật ký, khôi phục hay quy tắc khởi động lại.

# Đo hiệu năng (tùy chọn):
Start-WtTui -PerfDiagnostics
# Tóm tắt median/p95 khi thoát nằm trong logs/wt-<date>.jsonl.
```

### Xem lại một thao tác thất bại (chỉ đọc)

```powershell
# Lỗi gần nhất của lô vừa chạy (không cần chạy lại gì):
Get-WtOperation -Limit 20 | Where-Object { $_.outcome -eq 'failed' } |
    Format-Table operationId, tweakId, state, stage, outcome, updatedUtc -AutoSize

# Các thao tác bị gián đoạn (planned/applied nhưng chưa kết thúc) kèm giá trị hiện tại:
Get-WtInterruptedOperation -Targets | Format-Table OperationId, TweakId, Stage, CanRestore -AutoSize

# Trong giao diện: mở báo cáo kết quả lô (tự động hiện sau khi lô xong), nhấn E để
# xuất báo cáo JSON; báo cáo hiện thất bại trước, kèm giai đoạn thất bại, lỗi gốc,
# "Đã thay đổi" và số bản ghi khôi phục.
```

### Riêng Security.NetworkProtection

```powershell
# Xác minh trạng thái cấu hình và hiệu lực hiện tại:
Get-WtTweakState -Id Security.NetworkProtection | Format-List

# Mở nhật ký để xem lý do thất bại của provider (Tamper Protection có thể chặn
# Set-MpPreference; hoặc module Defender thiếu → Unsupported; hoặc chính sách quản lý):
Get-WtLogPath   # đường dẫn tệp nhật ký
```

Lưu ý: mục này làm **giảm mức bảo vệ** và không bao giờ nằm trong bộ cài tự động;
cần xem lại tác động trước khi áp dụng. Không tắt Tamper Protection hoặc Defender để
làm cho kiểm thử qua.

## English summary

* Pick a profile: `Ctrl+P` in the interface, `-PerfProfile Low-resource` on the command
  line, or `WT_TUI_PERF_PROFILE`. Auto already selects Low-resource for a classic console
  (no VT processing).
* Inspect a failed operation read-only: `Get-WtOperation` filtered by `failed`, and
  `Get-WtInterruptedOperation -Targets`. In the batch report press `E` to export JSON.
* `Security.NetworkProtection` failure causes are visible in the log path printed by
  `Get-WtLogPath`; Tamper Protection blocking `Set-MpPreference` is one possible cause,
  missing Defender module another, and a managed policy another. Never disable Tamper or
  Defender to make a test pass.
