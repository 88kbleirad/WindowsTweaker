do {
    Clear-Host
    Write-Host "===== Windows Tweak Tool ====="
    Write-Host "1. Tắt Telemetry"
    Write-Host "2. Tắt Windows Update"
    Write-Host "3. Tắt Cortana"
    Write-Host "4. Gỡ ứng dụng mặc định"
    Write-Host "5. Thoát"
    Write-Host "=============================="

    $choice = Read-Host "Chọn tùy chọn"
    switch ($choice) {
        1 { Disable-Telemetry }
        2 { Disable-WindowsUpdate }
        3 { Disable-Cortana }
        4 { Remove-Bloatware }
        5 { exit }
        default { Write-Host "Lựa chọn không hợp lệ." -ForegroundColor Red }
    }

    Pause
} while ($true)
