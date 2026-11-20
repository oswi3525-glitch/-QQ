# WQTerm — iOS Shell Framework (a-Shell / ios_system)
#
# Các framework dưới đây là binary arm64 cho iOS lấy từ bản release chính thức
# của holzschu/ios_system (v3.0.6) — cùng tác giả với a-Shell, giấy phép BSD-3.
# Chúng được nhúng dạng folder reference và **load động** lúc chạy, nên build
# unsigned của CI vẫn thành công (không cần ký framework).
#
#   ios_system.framework  — dispatcher: ios_system(const char *cmd)
#   shell.framework       — ls/cp/mv/rm/mkdir/... (file commands)
#   text.framework        — cat/head/tail/wc/grep/sed/... (text commands)
#   files.framework       — file/find/du/df/stat
#   tar.framework         — tar/gzip/bzip2
#   awk.framework         — awk
#
# `CommandRunner` gọi `ios_system()` qua @_silgen_name khi dlopen thành công;
# nếu không, tự động fallback sang BuiltinShell (Swift thuần).
#
# Nguồn: https://github.com/holzschu/ios_system/releases/tag/v3.0.6
