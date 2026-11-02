# WindowsTweaker - Vietnamese strings for the native WinUI frontend (part file).
#
# Bản dịch của Strings.en.gui.psd1: cùng tập khóa, cùng thứ tự. Giao diện WinUI không giữ
# bản dịch riêng - mọi nhãn đều tra trong bảng này (đã gộp và được phục vụ qua thao tác
# `strings.get`).
#
# Read with Import-PowerShellDataFile, so it must stay a single hashtable literal.
@{
    # Window chrome and navigation.
    'Gui.Nav.Overview'        = 'Tổng quan'
    'Gui.Nav.Tweaks'          = 'Tinh chỉnh'
    'Gui.Nav.Review'          = 'Duyệt'
    'Gui.Nav.History'         = 'Lịch sử'
    'Gui.Nav.Diagnostics'     = 'Chẩn đoán'
    'Gui.Nav.Licensing'       = 'Bản quyền'
    'Gui.Header.Environment'  = 'Môi trường'
    'Gui.Header.Backend'      = 'Tiến trình nền'
    'Gui.Header.Language'     = 'Ngôn ngữ'
    'Gui.Header.ReducedMotion' = 'Giảm chuyển động'
    'Gui.Details'             = 'Chi tiết'
    'Gui.Actions'             = 'Thao tác'
    'Gui.Status'              = 'Trạng thái'
    'Gui.Ready'               = 'Sẵn sàng'
    'Gui.Starting'            = 'Đang khởi động tiến trình nền...'
    'Gui.BackendDown'         = 'Tiến trình nền chưa chạy.'
    'Gui.BackendRestart'      = 'Khởi động lại tiến trình nền'

    # Column headers.
    'Gui.Column.Tweak'        = 'Tinh chỉnh'
    'Gui.Column.Category'     = 'Nhóm'
    'Gui.Column.State'        = 'Trạng thái'
    'Gui.Tweaks.OnlySupported' = 'chỉ những mục máy này chạy được'
    'Gui.Tweaks.RowCount'     = '{0} dòng'
    'Gui.Column.Target'       = 'Đích'
    'Gui.Column.Risk'         = 'Rủi ro'
    'Gui.Column.Scope'        = 'Phạm vi'
    'Gui.Column.Result'       = 'Kết quả'
    'Gui.Column.Outcome'      = 'Kết cục'
    'Gui.Column.Time'         = 'Thời gian'
    'Gui.Column.Message'      = 'Thông báo'
    'Gui.Column.Value'        = 'Giá trị'
    'Gui.Column.Operation'    = 'Thao tác'
    'Gui.Column.Source'       = 'Nguồn'

    # Actions.
    'Gui.Action.Preview'      = 'Xem trước'
    'Gui.Action.AddPending'   = 'Thêm vào danh sách duyệt'
    'Gui.Action.RemovePending' = 'Bỏ khỏi danh sách duyệt'
    'Gui.Action.ClearPending' = 'Xóa danh sách duyệt'
    'Gui.Action.Apply'        = 'Áp dụng các thay đổi đã duyệt'
    'Gui.Action.ApplyDryRun'  = 'Xem trước (chạy khô)'
    'Gui.Action.Restore'      = 'Khôi phục thay đổi này'
    'Gui.Action.Export'       = 'Xuất'
    'Gui.Action.Copy'         = 'Sao chép'
    'Gui.Action.OpenLogs'     = 'Mở thư mục nhật ký'
    'Gui.Action.Cancel'       = 'Hủy thao tác'
    'Gui.Action.Quit'         = 'Thoát'
    'Gui.Action.Refresh'      = 'Làm mới'
    'Gui.Action.Inspect'      = 'Xem chi tiết'

    # Review workflow.
    'Gui.Review.Title'        = 'Các thay đổi đã duyệt'
    'Gui.Review.Empty'        = 'Chưa duyệt gì. Chọn một tinh chỉnh rồi thêm vào đây.'
    'Gui.Review.Confirm'      = 'Áp dụng {0} thay đổi đã duyệt?'
    'Gui.Review.Dependency'   = 'Phụ thuộc và xung đột được hiển thị trước khi chạy.'
    'Gui.Review.DryRunNotice' = 'Chạy khô: mọi thao tác được báo cáo và không ghi gì cả.'
    'Gui.Review.Revalidation' = 'Trạng thái đã duyệt được kiểm tra lại ngay trước khi thay đổi.'

    # Operation and result views.
    'Gui.Busy.Title'          = 'Đang thực hiện'
    'Gui.Busy.Item'           = 'Mục {0} / {1}'
    'Gui.Result.Title'        = 'Kết quả'
    'Gui.Result.Verified'     = 'Đã xác minh bằng cách đọc lại giá trị'
    'Gui.Result.Unverified'   = 'Ghi nhận là không xác minh được (đích này không có bộ đọc lại)'
    'Gui.Result.Compensated'  = 'Lỗi một phần: các đích đã thay đổi đã được đặt lại'
    'Gui.Result.Journal'      = 'Nhật ký đã ghi bền: {0}'
    'Gui.Result.Unchanged'    = 'Đã ở đúng trạng thái yêu cầu'

    # Closing during an operation.
    'Gui.Close.BusyTitle'     = 'Vẫn còn thao tác đang chạy'
    'Gui.Close.BusyBody'      = 'Một thay đổi đang được áp dụng. Thoát ngay sẽ bỏ dở nó trước ranh giới an toàn.'
    'Gui.Close.Wait'          = 'Chờ chạy xong'
    'Gui.Close.Cancel'        = 'Hủy phần đang chờ và chờ kết thúc'
    'Gui.Close.Stay'          = 'Ở lại'

    # Overview.
    'Gui.Overview.Environment' = 'Môi trường'
    'Gui.Overview.Catalog'    = 'Danh mục'
    'Gui.Overview.Tweaks'     = 'Tinh chỉnh'
    'Gui.Overview.Interrupted' = 'Thao tác bị gián đoạn'
    'Gui.Overview.Drift'      = 'Đã đổi so với lúc áp dụng'
    'Gui.Overview.Pending'    = 'Thay đổi đã duyệt'
    'Gui.Overview.Packs'      = 'Gói'
    'Gui.Overview.None'       = 'không có'

    # Diagnostics.
    'Gui.Diagnostics.Report'  = 'Báo cáo chẩn đoán'
    'Gui.Diagnostics.Scan'    = 'Quét thư mục'
    'Gui.Diagnostics.ScanPath' = 'Thư mục cần quét'
    'Gui.Diagnostics.Monitor' = 'Chu kỳ giám sát'
    'Gui.Diagnostics.MonitorRun' = 'Chạy một chu kỳ (chỉ đọc)'
    'Gui.Diagnostics.LogPath' = 'Tệp nhật ký'
    'Gui.Diagnostics.StatePath' = 'Tệp nhật ký thao tác'
    'Gui.Diagnostics.Privacy' = 'Hoạt động riêng tư'
    'Gui.Diagnostics.Devices' = 'Kiểm kê thiết bị'
    'Gui.Diagnostics.Power'   = 'Cài đặt nguồn'
    'Gui.Diagnostics.Quarantine' = 'Cách ly'
    'Gui.Diagnostics.SetupPlans' = 'Kế hoạch thiết lập'
    'Gui.Diagnostics.Unavailable' = 'Không khả dụng trên máy này'

    # Licensing and the external tool.
    'Gui.Licensing.Status'    = 'Trạng thái bản quyền'
    'Gui.Licensing.Edition'   = 'Phiên bản đã cài'
    'Gui.Licensing.Method'    = 'Phương thức kích hoạt'
    'Gui.Licensing.NoMethod'  = 'Chưa chọn gì'
    'Gui.Licensing.Tool'      = 'Công cụ bên ngoài'
    'Gui.Licensing.Activate'  = 'Kích hoạt Windows (công cụ bên ngoài)'
    'Gui.Licensing.Download'  = 'Tải và xác minh công cụ'
    'Gui.Licensing.Remove'    = 'Xóa bản công cụ đã tải'
    'Gui.Licensing.Slmgr'     = 'Yêu cầu kích hoạt bằng giấy phép đã cài (slmgr /ato)'
    'Gui.Licensing.Separate'  = 'Đây là công cụ bên ngoài: nó không ghi nhật ký thao tác và không thể hoàn tác ở đây.'
    'Gui.Licensing.Duration'  = 'Thời hạn: {0}'

    # Errors and empty states.
    'Gui.Error.BackendExited' = 'Tiến trình nền kết thúc bất ngờ (mã thoát {0}).'
    'Gui.Error.BackendTimeout' = 'Tiến trình nền không trả lời trong {0} ms.'
    'Gui.Error.BackendProtocol' = 'Tiến trình nền gửi một khung mà ứng dụng không dùng được: {0}'
    'Gui.Error.ProtocolMismatch' = 'Tiến trình nền nói giao thức {0}; ứng dụng này cần {1}.'
    'Gui.Error.RequiresElevation' = 'Thao tác này cần tiến trình nền có quyền quản trị, còn tiến trình hiện tại thì không.'
    'Gui.Header.Elevate'      = 'Nâng quyền'
    'Gui.Header.ElevateHint'  = 'Mở lại ứng dụng này với quyền quản trị (hộp thoại UAC) và khởi động lại phiên nền'
    'Gui.Error.BusyMutating'  = 'Không thể nâng quyền khi đang có thao tác. Hãy đợi thao tác kết thúc.'
    'Gui.Error.ElevationDeclined' = 'Đã từ chối hộp thoại nâng quyền; không có gì được khởi chạy và phiên này không đổi.'
    'Gui.Error.ElevationFailed' = 'Không thể khởi chạy bản sao có quyền quản trị.'
    'Gui.Footer.Hint'         = 'F5 làm mới · Ctrl+F tìm kiếm · Esc đóng hộp thoại · Tab/mũi tên di chuyển'
    'Gui.Error.NoSelection'   = 'Hãy chọn một dòng trước.'
    'Gui.Error.EmptySearch'   = 'Không có tinh chỉnh nào khớp với tìm kiếm này.'
    'Gui.Error.LoadFailed'    = 'Yêu cầu thất bại: {0}'
}
