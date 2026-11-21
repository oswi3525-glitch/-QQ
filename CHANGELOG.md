# WQTerm — CHANGELOG

## [Unreleased] — Đại tu iOS 27
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
