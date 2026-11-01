# Keyboard reference / Tham khảo bàn phím

WindowsTweaker's interactive interface is keyboard-only. It never opens a window and it
never changes Windows while you are browsing: a change is added to a **pending set**, and
only `A` (after an explicit confirmation) applies the reviewed selection.

* [English](#english)
* [Tiếng Việt](#tiếng-việt)

## English

### Screen layout

```
 ⊞ WindowsTweaker                                              Preset: privacy-hardening    
 Windows11 build 22631 | PowerShell 7.4.2 | administrator | live | EN                       
├──────────────────┬──────────────────────────────────────┬────────────────────────────────┤
┌ Categories ──────┬ Tweaks ──────────────────────────────┬ Details ───────────────────────┐
 ⌂ Overview  [113]│ *  ▪ Advertising...  Disabled   Enabled│▪ Web results and suggestions in 
 ▪ Privacy    [20]│>*  ▪ Web results...  Disabled   Enabled│  the search box                 
 ▭ Explorer   [18]│ *  ▪ Diagnostic ...   Enabled   Enabled│                                 
 ▦ Apps       [21]│    ▪ Microsoft a... Unsuppor...          │Privacy.BingSearch               
 ⊞ System     [14]│    ▪ Windows Err... Unsuppor...          │                                 
 ○ Network     [1]│    ▪ Windows fee... Unsuppor...          │Sets the user policy that keeps  
 ◆ Security   [11]│    ▪ Let website... Unsuppor...          │web suggestions out of the Start 
 ⇩ Updates     [5]│    ▪ Potentially... Unsuppor...          │and File Explorer search boxes   
 ▤ Personal... [9]│    ▪ Recommended... Unsuppor...          │(HKCU\Software\Policies\Microsof 
 ↺ History     [0]│    ▪ Search high... Unsuppor...          │t\Windows\Explorer\DisableSearch 
└──────────────────┴──────────────────────────────────────┴────────────────────────────────┘
├──────────────────┴──────────────────────────────────────┴────────────────────────────────┤
 Up/Down move  Left/Right or Tab panes  Space select  Enter actions  / search  A review  …  
 Ready. Use / to search, Space to select a change, A to review. 3 pending change(s)        
```

* **Header** - application name, Windows version and build, PowerShell version, privilege
  level (`administrator` / `standard user`), dry-run state, language and the active preset.
* **Categories** - Overview, Privacy, Desktop & Taskbar, File Explorer, Applications,
  System, Network, Security, Windows Update, History & Restore. The number in brackets is
  how many rows that category has.
* **Tweaks** - name, detected state, pending target, support status and impact level.
* **Details** - description, planned effect, scope, privileges, current state, impact
  level, restart requirement, rollback fidelity, dependencies, parameters, detected
  instances, and the pending change if there is one.
* **Footer** - the context-sensitive shortcuts for the situation you are in, and the
  current status message.

Layouts are chosen from the terminal size, and everything survives a resize:

| Terminal | Layout | Panes |
|---|---|---|
| 92x18 or larger | Wide | categories, list and details side by side |
| 58x12 to 91x17 | Medium | categories and list; `Tab` focuses Details and it replaces the list |
| smaller | Compact | one pane at a time with a category tab strip |

### Row markers

Markers stay readable without colour or icons:

| Marker | Meaning |
|---|---|
| `>` | cursor (the highlighted row) |
| `*` | this row is in the pending set |
| `!` | unsupported on this machine (the reason is in the details pane) |
| `M` | the setting is managed by your organization |
| `R` | irreversible change (no rollback) |
| `D` | the change deletes user data |

### Icons

Icons are optional decoration: every state, category and action is also written as text,
and no shortcut depends on them.

| Mode | What is drawn | Notes |
|---|---|---|
| `Auto` | Unicode when the output encoding is UTF-8, otherwise the ASCII tags | the saved mode is honoured; `NerdFont` is never chosen automatically |
| `Unicode` | conservative monochrome symbols (`⌂`, `▪`, `○`, `◆`, `✓`, `✗`, `△`, `⇄`, `↻`) | one cell wide; no icon font is required |
| `NerdFont` | private-use glyphs (`U+F000`–`U+F2FF`, inside `U+E000`–`U+F8FF`) | needs a Nerd Font patched terminal font; an unpatched font draws boxes |
| `ASCII` | readable tags: `[HOME]`, `[NET]`, `[OK]`, `[WARN]`, `[ERR]`, `[ADMIN]`, `[RSTRT]`, `[UNDO]`… | readable in any font and on any code page |
| `None` | nothing | labels and row markers only |

Where they appear: the category pane (before every category), every tweak row (the icon of
that tweak’s own category), history rows (the outcome), the details pane (current state,
administrator requirement, restart requirement, rollback fidelity), the status line (the tone
of the message), dialogs (title tone, list entries, Yes/No buttons) and the operation panel
(running icon, plus a bar drawn from the completed item counts).

Facts worth knowing:

* **No font is detected, installed or changed.** The preview is the honest way to see what
  this terminal draws: if a glyph appears as a box, press `I` again and choose `Unicode`,
  `ASCII` or `None`.
* An icon is never the only signal: `Privileges: administrator` and `Current state:
  Disabled` remain in the details pane even when an icon is drawn beside them.
* Width is measured in terminal cells, never in characters. The icon column has a measured
  slot per mode (7 cells in ASCII) and is dropped when a pane is too narrow, instead of
  squeezing the label or shifting the columns behind it.
* The mode is saved in `settings.json` in WindowsTweaker’s data directory
  (`%LOCALAPPDATA%\WindowsTweaker` on Windows), and `-Icons Auto|Unicode|NerdFont|ASCII|None`
  overrides it for a single run. `-Ascii` forces ASCII frames **and** ASCII icons.

### Keys

| Key | Action |
|---|---|
| `Up` / `Down` | move through the rows of the focused pane (the list scrolls with the cursor) |
| `PageUp` / `PageDown`, `Home` / `End` | move by a screen / to the ends of the list |
| `Left` / `Right`, `Tab` / `Shift+Tab` | move between the panes (in Compact layout: between the tab strip and the list) |
| `Space` | add or remove the current row in the **pending set**. A two-state tweak toggles to the opposite state; anything else (multi-state, or a tweak that needs arguments) opens a picker instead of guessing |
| `Enter` | on a tweak: open the details and the available actions (choose the state, collect arguments). On a history row: offer to roll that recorded change back. On an Overview row: show the full environment snapshot |
| `/` | search: the filter is typed live, `Enter` keeps it, `Esc` clears it. While it is open, letters go into the filter and never trigger a global shortcut. A query that starts with `@` is a definition filter instead of a text search: `@risk:High`, `@lifecycle:Experimental`, `@scope:Machine`, `@support:Unverified`, `@evidence:ProviderTested`, `@pack:<pack id>`, `@tag:<tag>`, `@requires:<id>` - comma separated for more than one, the same vocabulary the command line uses (`-CatalogFilter`). A filter that is not recognised is reported on the status line instead of quietly showing everything |
| `A` | review the pending changes: the exact list, what each one does, its restart and rollback state. This is the only place a selection is applied, and only after a confirmation |
| `W` | dry-run preview of the pending changes: the same code path, forced into `-WhatIf`, writing nothing |
| `H` | execution history (newest first) |
| `R` | restore: pick a recorded change and roll it back to the state captured before it was applied |
| `P` | presets: load a shipped or user preset, import one from a file, export the pending changes, or discard them |
| `L` | switch language (English / Tiếng Việt) immediately: the whole interface and the detected names are re-rendered, the choice is saved, and `-Language en|vi` overrides it for one run. Also available as the `Language` row in Overview |
| `I` | choose the icon display mode. The picker previews every mode with the real glyph table of this terminal, marks the saved choice and writes it to `settings.json`; nothing is installed or changed for you |
| `D` | toggle dry run: while it is on, previews and applies write nothing |
| `G` | re-read the current state (read-only refresh) |
| `S` | sanity scan: read-only findings with the observed value and its type, the documented claim and expectation, the effective-behaviour class, the conditions the rule was written for, the remediation link and the limitations, plus the pending-restart markers. `/` filters, `E` asks for a path before writing a report (the screen's scan is what is exported), `Enter` closes the list. Nothing is applied from here |
| `M` | recommendations for one objective, with the reason for every item (recommended, already satisfied, excluded, unknown, blocked), its effective state and evidence class, and its verification status. `Left`/`Right` changes the objective, `O` walks forward; neither applies anything nor touches a selection you made by hand |
| `C` | settings that offer several alternatives. The live alternative stays labelled while the pending one is marked `(*)`; `Enter` picks one. Choosing another **replaces** the pending alternative, recomputes dependencies and conflicts, and invalidates the earlier review of that item. Restoring the captured original state is done from the journal (`R`), not here |
| `V` | verification and recovery: what was applied vs what is live now (matching / changed / unreadable / unsupported), interrupted operations, `R` review and reapply, `U` restore, `E` export the journal, `D` export the diagnostics. Nothing is reapplied automatically |
| `?` | the full keyboard reference and the safety rules |
| `Ctrl+P` | open the TUI performance profile picker (Auto / Balanced / Low-resource); presentation-only, never touches power or security |
| `Esc` | close a dialog; otherwise clear the filter; otherwise return the focus to the list |
| `Q` (or `Ctrl+C`) | quit. Pending changes and a running operation are raised explicitly - quitting is never silent about either |

### Dialogs

Dialogs are panels inside the same screen; no window, file dialog or message box is ever
opened.

| Dialog | Keys |
|---|---|
| Message / help | `Enter`, `Space` or `Esc` close; `Up`/`Down`, `PageUp`/`PageDown` scroll |
| Confirmation | the buttons say `Yes [Y]` and `No [N]`; `Left`/`Right` or `Tab`/`Shift+Tab` move the highlight (it wraps), `Y`/`N` answer immediately, `Enter` accepts **the highlighted button** (**No** is highlighted by default, so a stray `Enter` changes nothing), `Esc` cancels and leaves the interface exactly where it was |
| Text input (paths, DNS servers, DoH template) | type to edit, `Backspace`/`Delete`, `Left`/`Right`, `Home`/`End`, `Enter` validates and accepts, `Esc` cancels. Invalid input shows the reason and the field stays open |
| List (packages, features, capabilities, adapters, states, history, presets, pending review, sanity findings, recommendations, choice groups) | `Up`/`Down`, `PageUp`/`PageDown`, `Home`/`End`; `Space` to tick a row in a multi-selection list (and step to the next one); `Enter` accepts; `/` filters; `Esc` cancels. While the filter is focused, every typed character is text - a shortcut letter (`E`, `O`, `X`, `C`, ...) never fires from inside the filter |
| Store package picker | `U` switches the removal scope between *current user* and *all users* (the latter needs elevation); protected and non-removable packages cannot be ticked |
| Pending review | every row lists the exact targets with their current and proposed values (and identifies targets that only become known when the change runs); overlapping targets are reported as conflicts. `X` removes the highlighted change, `C` discards all of them, `R` toggles "restart automatically after completion" for this batch only (off by default, never remembered, and refused on a platform that cannot restart), `Enter` continues to the confirmation, which re-reads the reviewed state first and refuses to apply it if anything moved |
| Restart countdown (only after a clean, fully recorded batch with `R` enabled) | shows the applied/unchanged counts, what the selection requires (a full restart, an Explorer/sign-out restart or an unknown requirement), the planned restart time and the warning that open applications can delay or prevent it. The note line counts down 60 s, one row repainted per second. `Esc` cancels the restart, `Q` cancels it and quits; `Enter`/`Space` do nothing, so a key pressed out of habit cannot restart the machine early |

### Shortcut line and diagnostics

The bottom line shows as many shortcuts as fit without being cut off; `?` always lists
every key. The interface never claims a key that does not work, and the dialog hints list
the keys that dialog actually handles.

`-InputDiagnostics` (or `WT_TUI_INPUT_TRACE=1`) appends one structured log record per key
press - the normalised key name plus the place it was dispatched to (`global:q`,
`dialog:confirm`, `search`, ...) - to the log file. Characters typed into a search box, a
path field or any other text field are masked, and nothing is drawn on the screen. Use it
when a key appears to be ignored:

```bash
pwsh -File WindowsTweaker.ps1 -InputDiagnostics
# then inspect the newest log file
```


### Monitoring workspace (B)

| Key | Action |
|---|---|
| `B` | open the monitoring workspace (also the Overview -> Monitoring row) |
| `Left`/`Right` | switch dashboard (Overview / Network / Changes) |
| `Up`/`Down` | move the panel selection |
| `Enter` | inspect the selected panel (metric ids, units, source, history, errors, raw samples) |
| `F` | mark the display as frozen (a header flag; the frame loop does not pause repainting yet) |
| `P` | pause/resume collection (visible label) |
| `T` | cycle the time range (1m/5m/15m/1h) |
| `A` | alert rules: states, holds, hysteresis; `Enter` toggles acknowledge (mute is displayed but nothing sets it) |
| `E` | edit the dashboard layout (add/remove/reorder panels, set size, save, duplicate, reset) |
| `C` | compare two monitored intervals (baseline vs comparison) |
| `O` | configure the optional remote Prometheus data source (connection test, `[prom]` badges) |
| `R` | toggle optional SQLite metric recording (retention policy shown before enabling) |
| `1` | fleet (multi-host overview) from configured Prometheus data sources |
| `2` | incident workspace (unified timeline around an alert/interval) |
| `3` | run a read-only diagnostic playbook |
| `4` | preview and export a sanitized support bundle |


| `?` | context help |
| `Esc` | leave the workspace back to the main interface |

Charts draw gaps (never zeros), show min/max and aggregation method, and state when the
requested range exceeds available history.

The fleet, incident, playbook and support-bundle views (`1`-`4`) exist but are the least
exercised part of the workspace: [docs/MULTI-HOST.md](MULTI-HOST.md) lists what is wired and
what is not.

### Licensing workspace (N)

| Key | Action |
|---|---|
| `N` | open the licensing & activation diagnostics workspace (also the Overview -> Licensing & Activation Diagnostics row) |
| `R` | refresh the read-only inventory; the status line confirms it and the `Collected` timestamp changes |
| `E` | export the redacted report: a preview is shown first, then an export path is asked for, and the file is written only after that |
| `A` | request activation with the installed license (documented `slmgr /ato`): the purpose, the possible network activity and the required permissions are shown first, and **No** is the highlighted answer |
| `M` | open the external tool: Microsoft Activation Scripts (download, launch and remove on explicit request) |
| `?` | context help for this workspace |
| `Esc` | leave the workspace and return to the main interface unchanged |

Everything the workspace shows is read-only: the Windows licensing products, the license status with
its raw code, the license channel, the grace state, the W32Time state and the component
availability. The partial product key is **not** displayed by default (the workspace reads the
redacted view), and a full key, an activation token, a machine identifier or an organization
hostname is never displayed or exported. `A` is the only key that asks Windows to do something, it
never runs automatically, and its result is re-read rather than assumed: an accepted command is not
reported as an activated license. See [docs/VALIDATION.md](VALIDATION.md) section 21 for what was
validated here and what still needs a Windows host.

### External tool inside the licensing workspace (M)

| Key | Action |
|---|---|
| `M` | open the Microsoft Activation Scripts (external tool) view from the licensing workspace |
| `V` | view the upstream documentation (`https://massgrave.dev/`) |
| `D` | download the pinned upstream file: one confirmation, then a background transfer that reports real byte counts, verifies and keeps |
| `U` | resolve the newest upstream release and offer it as a new pin: the tag, commit and size are shown before anything is downloaded |
| `L` | launch the verified local copy in its own console (explicit UAC handoff when the session is not elevated) |
| `R` | remove the local copy, its staging leftover and the provenance record |
| `?` | the full disclosure (provenance, what runs, what is not offered) |
| `Esc` | back to the licensing diagnostics |

While this view is open, its own keys replace the main-screen hints in the footer - and while a
transfer runs, the hint becomes the single key that matters: `Esc` cancels it. A second `D`/`U`
while one runs is refused. In dry-run mode every one of these keys shows what would happen instead
of doing it, and a launch is refused before its confirmation dialog. Nothing is downloaded, launched
or deleted while the view is only being read: every action starts with a dialog that defaults to
**No**. The tool is not a tweak - it is never part of a preset, a batch, a
startup task or a monitoring policy, it writes no rollback data, and the registry journal cannot
undo what it does to licensing state. See [EXTERNAL-TOOLS.md](EXTERNAL-TOOLS.md) for the
pinned version, the provenance chain and the licence obligations.

### While an operation is running

* The progress panel shows the active item and **item counts that actually happened**
  (`Item 3 of 18`) - never an invented percentage.
* Per-item results appear as they finish; the final panel lists every operation of every
  change with its status, message and restart requirement.
* `Esc` requests cancellation: queued items are dropped, and the item that is already
  running finishes at its safe boundary. `Q` cancels the queue and quits afterwards.
* A native operation that is already in flight (DISM, `Remove-AppxPackage`, a service
  stop) cannot be interrupted; the interface says so instead of pretending it did.
* Only one operation runs at a time, so two conflicting modifications can never
  interleave.

### Safety rules the interface enforces

1. Selecting a row never changes Windows.
2. Nothing is applied without an explicit confirmation of the exact, listed changes.
3. Protection-reducing tweaks are never part of the shipped presets and are flagged in the
   pending review.
4. Dry run is available everywhere, including for whole presets.
5. Irreversible and data-deleting changes say what is lost and require their own
   confirmation.
6. Files are never written outside the paths you type, and those paths are validated
   before anything runs.
7. The terminal is restored (alternate screen, colours, cursor) on a normal exit, on
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
│ > Tổng quan     [113]│ > ! Ô chọn mục trong File ...       │ Advertising ID     │
│   Quyền riêng tư [20]│   ! Chế độ thu gọn cho Fil...       │ Privacy.Advertis.. │
│   ...                │   ...                               │ ...                │
├──────────────────────┴─────────────────────────────────────┴────────────────────┤
│ Lên/Xuống di chuyển  Trái/Phải hoặc Tab đổi khung  Space chọn  Enter hành động   │
│ 3 thay đổi đang chờ                                                             │
└─────────────────────────────────────────────────────────────────────────────────┘
```

* **Tiêu đề** - tên ứng dụng, phiên bản và build Windows, phiên bản PowerShell, mức quyền
  (`quản trị viên` / `người dùng thường`), trạng thái chạy thử, ngôn ngữ và bộ cài đang dùng.
* **Nhóm** - Tổng quan, Quyền riêng tư, Màn hình & Taskbar, File Explorer, Ứng dụng, Hệ
  thống, Mạng, Bảo mật, Windows Update, Lịch sử & Hoàn tác. Số trong ngoặc là số dòng.
* **Tinh chỉnh** - tên, trạng thái hiện tại, trạng thái đích đang chờ, mức hỗ trợ và mức
  ảnh hưởng.
* **Chi tiết** - mô tả, ảnh hưởng dự kiến, phạm vi, quyền cần có, trạng thái hiện tại, mức
  ảnh hưởng, yêu cầu khởi động lại, khả năng hoàn tác, phụ thuộc, tham số, số đối tượng nhận
  diện được và thay đổi đang chờ nếu có.
* **Dòng cuối** - các phím tắt theo ngữ cảnh và thông báo trạng thái hiện tại.

Bố cục được chọn theo kích thước terminal và giữ nguyên khi bạn đổi kích thước:

| Terminal | Bố cục | Các khung |
|---|---|---|
| từ 92x18 | Rộng | nhóm, danh sách và chi tiết cạnh nhau |
| 58x12 đến 91x17 | Vừa | nhóm và danh sách; `Tab` chuyển sang Chi tiết và khung này thay thế danh sách |
| nhỏ hơn | Thu gọn | mỗi lần một khung, kèm dải tab chọn nhóm |

### Ký hiệu trên dòng

Các ký hiệu vẫn đọc được khi không có màu hoặc biểu tượng:

| Ký hiệu | Ý nghĩa |
|---|---|
| `>` | con trỏ (dòng đang chọn) |
| `*` | dòng này đang nằm trong danh sách chờ |
| `!` | không được hỗ trợ trên máy này (lý do ở khung chi tiết) |
| `M` | thiết lập do tổ chức của bạn quản lý |
| `R` | thay đổi không thể hoàn tác |
| `D` | thay đổi xóa dữ liệu người dùng |

### Biểu tượng

Biểu tượng chỉ để trang trí: mọi trạng thái, nhóm và hành động đều được viết bằng chữ, và không phím tắt nào phụ thuộc vào chúng.

| Chế độ | Vẽ gì | Ghi chú |
|---|---|---|
| `Auto` | Unicode khi mã hóa đầu ra là UTF-8, nếu không thì dùng thẻ ASCII | tôn trọng chế độ đã lưu; không bao giờ tự chọn `NerdFont` |
| `Unicode` | ký hiệu đơn sắc thận trọng (`⌂`, `▪`, `○`, `◆`, `✓`, `✗`, `△`, `⇄`, `↻`) | rộng một ô; không cần phông biểu tượng |
| `NerdFont` | ký tự vùng riêng tư (`U+F000`–`U+F2FF`, nằm trong `U+E000`–`U+F8FF`) | cần phông terminal đã vá Nerd Font; phông chưa vá sẽ vẽ thành ô vuông |
| `ASCII` | thẻ dễ đọc: `[HOME]`, `[NET]`, `[OK]`, `[WARN]`, `[ERR]`, `[ADMIN]`, `[RSTRT]`, `[UNDO]`… | đọc được với mọi phông và mọi bảng mã |
| `None` | không vẽ gì | chỉ có nhãn và ký hiệu trên dòng |

Xuất hiện ở: khung nhóm (trước mỗi nhóm), mọi dòng tinh chỉnh (biểu tượng của đúng nhóm tinh chỉnh đó), các dòng lịch sử (kết quả), khung chi tiết (trạng thái hiện tại, yêu cầu quyền quản trị, yêu cầu khởi động lại, khả năng hoàn tác), dòng trạng thái (sắc thái của thông báo), hộp thoại (sắc thái tiêu đề, các dòng trong danh sách, nút Có/Không) và bảng tiến độ (biểu tượng đang chạy, kèm thanh tiến độ vẽ từ số mục đã xong).

Điều nên biết:

* **Không dò, không cài và không đổi phông.** Phần xem trước là cách trung thực để biết terminal này vẽ được gì: nếu ký tự hiện thành ô vuông, hãy nhấn `I` lần nữa và chọn `Unicode`, `ASCII` hoặc `None`.
* Biểu tượng không bao giờ là tín hiệu duy nhất: `Quyền cần có: administrator` và `Trạng thái hiện tại: Disabled` vẫn nằm trong khung chi tiết dù có biểu tượng bên cạnh.
* Độ rộng được đo bằng ô terminal, không bao giờ bằng số ký tự. Cột biểu tượng có độ rộng cố định theo từng chế độ (7 ô với ASCII) và sẽ bị bỏ khi khung quá hẹp, thay vì bóp nhãn hay làm lệch các cột phía sau.
* Chế độ được lưu trong `settings.json` ở thư mục dữ liệu của WindowsTweaker (`%LOCALAPPDATA%\WindowsTweaker` trên Windows), và `-Icons Auto|Unicode|NerdFont|ASCII|None` ghi đè cho một lần chạy. `-Ascii` buộc khung ASCII **và** biểu tượng ASCII.

### Phím

| Phím | Tác dụng |
|---|---|
| `Lên` / `Xuống` | di chuyển trong khung đang chọn (danh sách cuộn theo con trỏ) |
| `PageUp` / `PageDown`, `Home` / `End` | di chuyển theo màn hình / tới đầu và cuối danh sách |
| `Trái` / `Phải`, `Tab` / `Shift+Tab` | đổi giữa các khung (ở bố cục Thu gọn: giữa dải tab và danh sách) |
| `Space` | thêm hoặc bỏ dòng hiện tại trong **danh sách chờ**. Tinh chỉnh hai trạng thái sẽ đảo sang trạng thái ngược lại; các trường hợp khác (nhiều trạng thái hoặc cần tham số) sẽ mở bảng chọn thay vì đoán |
| `Enter` | với tinh chỉnh: mở chi tiết và các hành động (chọn trạng thái, nhập tham số). Với dòng lịch sử: đề nghị hoàn tác thay đổi đã ghi. Với dòng Tổng quan: xem toàn bộ thông tin môi trường |
| `/` | tìm kiếm: bộ lọc được gõ trực tiếp, `Enter` giữ lại, `Esc` xóa. Khi đang mở, chữ được gõ vào bộ lọc và không kích hoạt phím tắt toàn cục. Truy vấn bắt đầu bằng `@` là bộ lọc định nghĩa thay vì tìm theo chữ: `@risk:High`, `@lifecycle:Experimental`, `@scope:Machine`, `@support:Unverified`, `@evidence:ProviderTested`, `@pack:<mã gói>`, `@tag:<thẻ>`, `@requires:<mã>` - nhiều bộ lọc thì cách nhau bằng dấu phẩy, dùng đúng bộ từ vựng như dòng lệnh (`-CatalogFilter`). Bộ lọc không được hiểu sẽ được báo trên dòng trạng thái thay vì âm thầm hiện tất cả |
| `A` | xem lại các thay đổi đang chờ: danh sách chính xác, tác dụng của từng mục, yêu cầu khởi động lại và khả năng hoàn tác. Đây là nơi duy nhất áp dụng lựa chọn, và chỉ sau khi bạn xác nhận |
| `W` | xem trước các thay đổi đang chờ bằng chạy thử: cùng luồng xử lý, bị buộc `-WhatIf`, không ghi gì |
| `H` | lịch sử thực thi (mới nhất trước) |
| `R` | hoàn tác: chọn một thay đổi đã ghi và khôi phục đúng trạng thái đã lưu trước khi áp dụng |
| `P` | bộ cài: nạp bộ cài có sẵn hoặc của bạn, nhập từ tệp, xuất các thay đổi đang chờ, hoặc bỏ chúng |
| `L` | đổi ngôn ngữ (English / Tiếng Việt) ngay lập tức: toàn bộ giao diện và tên hiển thị được vẽ lại, lựa chọn được lưu, và `-Language en|vi` ghi đè cho một lần chạy. Cũng có trong dòng `Ngôn ngữ` ở Tổng quan |
| `I` | chọn chế độ hiển thị biểu tượng. Bảng chọn xem trước từng chế độ bằng đúng bảng ký tự của terminal này, đánh dấu lựa chọn đã lưu và ghi vào `settings.json`; không cài hay đổi gì cho bạn |
| `D` | bật/tắt chạy thử: khi bật, cả xem trước và áp dụng đều không ghi gì |
| `G` | đọc lại trạng thái hiện tại (chỉ đọc) |
| `S` | quét kiểm tra: các phát hiện chỉ đọc kèm khẳng định trong tài liệu, kỳ vọng tương ứng và những gì quy tắc không bao quát, cùng các dấu hiệu cần khởi động lại. `Enter` xem một phát hiện đầy đủ, `E` hỏi đường dẫn trước khi ghi báo cáo. Không có gì được áp dụng từ đây |
| `M` | đề xuất cho một mục tiêu, kèm lý do cho từng mục (được đề xuất, đã đạt, bị loại, chưa rõ, bị chặn). `Trái`/`Phải` đổi mục tiêu, `O` tính lại; cả hai đều không áp dụng gì và không đụng tới lựa chọn bạn tự làm |
| `C` | các thiết lập có nhiều lựa chọn. `Enter` chọn một lựa chọn; chọn lựa chọn khác sẽ **thay thế** lựa chọn đang chờ, tính lại phụ thuộc và xung đột, và hủy hiệu lực việc xem lại trước đó của mục này. Khôi phục đúng trạng thái đã lưu được làm từ nhật ký (`R`), không phải ở đây |
| `V` | xác minh và khôi phục: đối chiếu giá trị đã áp dụng với giá trị hiện tại (khớp / đã thay đổi / không đọc được / không hỗ trợ), các thao tác bị gián đoạn, `R` xem lại và áp dụng lại, `U` khôi phục, `E` xuất nhật ký, `D` xuất chẩn đoán. Không có gì được áp dụng lại tự động |
| `?` | toàn bộ tham khảo bàn phím và các quy tắc an toàn |
| `Ctrl+P` | mở trình chọn hồ sơ hiệu năng TUI (Tự động / Cân bằng / Ít tài nguyên); chỉ ảnh hưởng trình bày, không bao giờ đụng đến điện năng hoặc bảo mật |
| `Esc` | đóng hộp thoại; nếu không thì xóa bộ lọc; nếu không thì đưa con trỏ về danh sách |
| `Q` (hoặc `Ctrl+C`) | thoát. Thay đổi đang chờ và tác vụ đang chạy đều được nêu rõ - không bao giờ thoát âm thầm |

### Hộp thoại

Hộp thoại là các khung nằm trong cùng màn hình; không bao giờ mở cửa sổ, hộp chọn tệp hay
hộp thông báo của Windows.

| Hộp thoại | Phím |
|---|---|
| Thông báo / trợ giúp | `Enter`, `Space` hoặc `Esc` để đóng; `Lên`/`Xuống`, `PageUp`/`PageDown` để cuộn |
| Xác nhận | nút hiển thị `Có [Y]` và `Không [N]`; `Trái`/`Phải` hoặc `Tab`/`Shift+Tab` đổi mục đang chọn (quay vòng), `Y`/`N` trả lời ngay, `Enter` chấp nhận **nút đang được tô sáng** (**Không** được chọn mặc định nên `Enter` lỡ tay không thay đổi gì), `Esc` hủy và giữ nguyên giao diện |
| Nhập văn bản (đường dẫn, máy chủ DNS, mẫu DoH) | gõ để sửa, `Backspace`/`Delete`, `Trái`/`Phải`, `Home`/`End`, `Enter` kiểm tra rồi chấp nhận, `Esc` hủy. Dữ liệu sai sẽ hiện lý do và ô nhập vẫn mở |
| Danh sách (gói, tính năng, khả năng, adapter, trạng thái, lịch sử, bộ cài, xem lại) | `Lên`/`Xuống`, `PageUp`/`PageDown`, `Home`/`End`; `Space` đánh dấu rồi chuyển sang dòng kế tiếp; `Enter` chấp nhận; `/` lọc; `Esc` hủy |
| Chọn gói Store | `U` đổi phạm vi giữa *người dùng hiện tại* và *tất cả người dùng* (cần quyền quản trị); gói được bảo vệ hoặc không thể gỡ thì không đánh dấu được |
| Xem lại danh sách chờ | mỗi dòng liệt kê đúng các đối tượng cùng giá trị hiện tại và giá trị đề xuất (và nêu rõ đối tượng chỉ biết được khi chạy); các đối tượng trùng nhau được báo là xung đột. `X` bỏ thay đổi đang chọn, `C` bỏ tất cả, `R` bật/tắt "tự động khởi động lại sau khi hoàn tất" cho riêng lô này (mặc định TẮT, không ghi nhớ, bị từ chối nếu nền tảng không hỗ trợ), `Enter` sang bước xác nhận — bước này đọc lại trạng thái đã xem và từ chối áp dụng nếu có gì đã thay đổi |
| Đếm ngược khởi động lại (chỉ sau khi lô áp dụng xong sạch sẽ và được ghi nhật ký đầy đủ, khi đã bật `R`) | hiển thị số thay đổi đã áp dụng/không đổi, yêu cầu khởi động lại của lựa chọn (khởi động lại toàn bộ, chỉ File Explorer/đăng xuất, hoặc chưa xác định), giờ dự kiến khởi động lại và cảnh báo rằng ứng dụng đang mở có thể làm chậm hoặc ngăn việc khởi động lại. Dòng ghi chú đếm ngược 60 giây, chỉ vẽ lại một dòng mỗi giây. `Esc` hủy khởi động lại, `Q` hủy rồi thoát; `Enter`/`Space` không làm gì để một phím bấm theo thói quen không thể khởi động lại máy sớm |

### Dòng phím tắt và chẩn đoán nhập liệu

Dòng cuối hiển thị vừa đủ các phím tắt mà không bị cắt; `?` luôn liệt kê đầy đủ. Giao diện
không bao giờ ghi một phím không hoạt động, và gợi ý trong hộp thoại liệt kê đúng những
phím hộp thoại đó xử lý.

`-InputDiagnostics` (hoặc `WT_TUI_INPUT_TRACE=1`) ghi thêm một bản ghi có cấu trúc cho mỗi
lần nhấn phím - tên phím đã chuẩn hóa và nơi phím được gửi tới (`global:q`,
`dialog:confirm`, `search`, ...) - vào tệp log. Ký tự gõ vào ô tìm kiếm, ô đường dẫn hay bất
kỳ ô nhập văn bản nào đều được che, và không có gì được vẽ lên màn hình. Dùng khi một phím
có vẻ bị bỏ qua:

```bash
pwsh -File WindowsTweaker.ps1 -InputDiagnostics
```

### Không gian chẩn đoán cấp phép & kích hoạt (N)

| Phím | Hành động |
|---|---|
| `N` | mở không gian chẩn đoán cấp phép & kích hoạt (cũng có ở dòng "Chẩn đoán cấp phép & kích hoạt" trong Tổng quan) |
| `R` | làm mới tồn kho chỉ-đọc; dòng trạng thái xác nhận và mốc `Thu thập lúc` thay đổi |
| `E` | xuất báo cáo đã ẩn dữ liệu nhạy cảm: hiện bản xem trước trước, sau đó hỏi đường dẫn, và chỉ ghi tệp sau bước đó |
| `A` | yêu cầu kích hoạt bằng giấy phép đã cài (`slmgr /ato` theo tài liệu): mục đích, khả năng truy cập mạng và quyền cần có được hiện trước, và nút được chọn mặc định là **Không** |
| `?` | trợ giúp ngữ cảnh của không gian này |
| `Esc` | rời không gian, trở lại giao diện chính mà không thay đổi gì |

Mọi thứ không gian này hiển thị đều chỉ-đọc: các sản phẩm cấp phép của Windows, trạng thái cấp
phép kèm mã gốc, kênh cấp phép, giai đoạn gia hạn, trạng thái W32Time và khả năng của các thành
phần. Khóa sản phẩm một phần **không** được hiển thị mặc định (không gian đọc bản đã ẩn), và khóa
đầy đủ, mã thông báo kích hoạt, định danh máy hay tên máy chủ của tổ chức không bao giờ được hiển
thị hoặc xuất ra. `A` là phím duy nhất yêu cầu Windows làm gì đó, không bao giờ chạy tự động, và
kết quả được đọc lại thay vì suy đoán: lệnh được chấp nhận không được báo là giấy phép đã kích
hoạt. Xem [docs/VALIDATION.md](VALIDATION.md) mục 21 để biết phần nào đã được kiểm chứng ở đây và
phần nào còn cần một máy Windows.

### Khi một tác vụ đang chạy

* Bảng tiến độ hiện mục đang chạy và **số mục đã thực sự hoàn thành** (`Mục 3/18`) - không
  bao giờ là phần trăm tự đặt ra.
* Kết quả từng mục hiện ngay khi xong; bảng cuối liệt kê mọi thao tác của mọi thay đổi kèm
  trạng thái, thông báo và yêu cầu khởi động lại.
* `Esc` yêu cầu hủy: các mục trong hàng đợi bị bỏ, mục đang chạy sẽ kết thúc ở ranh giới an
  toàn. `Q` hủy hàng đợi rồi thoát.
* Thao tác gốc đang chạy (DISM, `Remove-AppxPackage`, dừng dịch vụ) không thể ngắt giữa
  chừng; giao diện nói rõ điều đó thay vì giả vờ đã hủy.
* Mỗi lần chỉ có một tác vụ chạy, nên hai thay đổi xung đột không thể xen kẽ nhau.

### Nguyên tắc an toàn mà giao diện bảo đảm

1. Chọn một dòng không bao giờ thay đổi Windows.
2. Không có gì được áp dụng nếu bạn chưa xác nhận đúng danh sách thay đổi.
3. Tinh chỉnh làm giảm bảo vệ không bao giờ nằm trong bộ cài có sẵn và luôn được cảnh báo.
4. Chạy thử có ở mọi nơi, kể cả cho cả một bộ cài.
5. Thay đổi không thể hoàn tác hoặc xóa dữ liệu đều nói rõ mất gì và cần xác nhận riêng.
6. Không ghi tệp ra ngoài đường dẫn bạn nhập, và đường dẫn được kiểm tra trước khi chạy.
7. Terminal được khôi phục (màn hình thay thế, màu, con trỏ) khi thoát bình thường, khi nhấn
   `Ctrl+C` và khi xảy ra lỗi bất ngờ.
