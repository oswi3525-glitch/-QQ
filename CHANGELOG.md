# WQTerm — CHANGELOG

## [Unreleased] — Reliability overhaul
- MobileGestalt: sửa triệt để lỗi `errno 1` (EPERM). Phân biệt read/write/permission/verification/rollback; probe quyền ghi trước khi backup; file tạm chỉ tạo sau preflight; fsync/close kiểm tra; đọc lại so sánh sau ghi; rollback tự động; xoá snapshot rác; không báo thành công giả.
- WorseQuery: thay signature private API sai (1 tham số) bằng `SandboxAccess.grantReadWrite` (3 tham số đúng), không báo mount thành công khi không có extension.
- Pairing: state machine STOPPED→…→COMPLETED, listener/service chỉ quảng bá sau `.ready`, generation token chặn callback cũ, retry có giới hạn, timeout handshake, một NWBrowser duy nhất, chặn `DefunctConnection`; thêm 7 bước chẩn đoán + debug log riêng.
- Tunnel: `TunnelConfiguration` là nguồn duy nhất cho IP/port; `NetworkUtils` không còn đếm `lo0/127.0.0.1` hay `utun*` không có địa chỉ; `TunnelMonitor` cập nhật liên tục và dừng host khi tunnel mất.
- UI: trạng thái VPN/Tunnel/Listener/Bonjour/Pairing riêng biệt, màu xanh/vàng/đỏ, bỏ đường dẫn hệ thống dài khỏi màn hình chính.

## [1.0.1] — Đại tu iOS 27
- Pairing: thêm `NetworkUtils` kiểm tra LocalDevVPN (utun / 10.7.0.1), cảnh báo khi chưa bật, luồng `beginPairing()` không treo sau mật khẩu khóa máy, đẩy mã PIN lên thông báo, onboarding 3 bước.
- UI: component Liquid Glass dùng chung, áp dụng cho nút chính/tab; tương phản Dark Mode.
- Sandbox: mở rộng đường dẫn quét bundle/data container, fallback worse_query qua App Group, lọc tên hiển thị, thêm nút Respring & Dọn Cache.
- Gestalt: thêm 5 preset (Dynamic Island, AOD, Action Button, Camera Control, Collision SOS); mọi ghi bắt buộc qua `SnapshotEngine.createSnapshot()`.
- Respring: `RespringHelper` với NeoSpring (WKWebView GPU overload) + dự phòng Diagnostics Relay qua LocalDevVPN.
- AI CLI: `ai_cli.py` dùng Groq API (`llama-3.3-70b-versatile` / `gpt-oss-120b`), `ai.py` là shim; thêm provider Groq.
- Build: deployment target iOS 26, slim Python runtime, CI chặn IPA >= 100MB.

## [1.0.0] — 2026-11-19 (M0 scaffold)
- Tạo cấu trúc dự án theo PRD WQTerm
- Thêm WQTerm.entitlements (App Group `group.com.wqterm.app`, get-task-allow)
- Thêm Info.plist với quyền runtime (Face ID, LocalNetwork, Bonjour pairing)
- Thêm GitHub Actions workflow build .ipa không ký
- Scaffold module: Exploit (IOSCompatibility, WorseQuery, SandboxMounter), Security (AuditLogger, SafeMode, FaceID, SensitiveAppGuard), Shell (ShellSession, CommandExecutor), Backup (Encryption, Snapshot, ContainerArchiver), AICLI (Gemini/Claude/Codex adapters), Runtimes (Node/Python RuntimeManager), Pairing (PairingManager, JITManager), Preview (QuickLook, Plist, Hex, Zip), UI Components (WarningBanner, TwoStepConfirmDialog, BlurSensitiveView, KeyboardAccessoryView)
- Thêm Localizable.strings (vi), LICENSE (GPL-3.0), CHANGELOG.md

## [Chưa có bản release]
- M1 Terminal Core (fork a-Shell 2.3.2)
- M2 Sandbox Escape worse_query đầy đủ
- M3 Backup Engine đầy đủ (restore 2 bước, self-backup .wqterm-config.zip)
- M4 AI CLI (Gemini, Claude, Codex) + Node.js arm64 build
- M5 KeyboardAccessoryView
- M6 UI & Security (5 tab, onboarding, SafeMode, FaceID, Audit log)
- M7 Preview (QuickLook, Plist, SQLite, Hex, ZIP)
- M8 Pairing & JIT (StikDebug)
- M9 AI Assistant (NL2Cmd, Error Explainer, Chat)
- M10 Automation & UX (Snippets, File Browser, Recipes)
