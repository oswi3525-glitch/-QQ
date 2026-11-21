#!/usr/bin/env bash
#
# slim_runtime.sh — cắt gọn Python runtime nhúng để IPA < 100MB.
# Chạy trên macOS sau scripts/fetch_runtime.sh, trước xcodegen.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME="${ROOT_DIR}/WQTerm/Resources/python-runtime"

if [ ! -d "${RUNTIME}" ]; then
  echo "[slim] không thấy python-runtime, bỏ qua."
  exit 0
fi

echo "[slim] trước khi cắt: $(du -sh "${RUNTIME}" | cut -f1)"

STDLIB="${RUNTIME}/Library/lib/python3.9"
if [ -d "${STDLIB}" ]; then
  for heavy in test tests idlelib tkinter lib2to3 ensurepip site-packages \
               distutils curses html/wsgiref unittest; do
    rm -rf "${STDLIB}/${heavy}" 2>/dev/null || true
  done
  find "${STDLIB}" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
  find "${STDLIB}" -type f -name '*.pyc' -delete 2>/dev/null || true
  find "${STDLIB}" -type f -name '*.pyo' -delete 2>/dev/null || true
  find "${STDLIB}" -type d -name 'config-*' -prune -exec rm -rf {} + 2>/dev/null || true
fi

# Bỏ debug symbol / header — không cần khi chạy trên thiết bị.
find "${RUNTIME}" -type d -name 'Headers' -prune -exec rm -rf {} + 2>/dev/null || true
find "${RUNTIME}" -type d -name '*.dSYM' -prune -exec rm -rf {} + 2>/dev/null || true
find "${RUNTIME}" -type d -name 'Modules' -prune -exec rm -rf {} + 2>/dev/null || true

# Strip binary frameworks (macOS strip hỗ trợ -x cho Mach-O arm64).
if command -v strip >/dev/null 2>&1; then
  find "${RUNTIME}" -type f -perm -111 -print0 2>/dev/null \
    | xargs -0 -r strip -x 2>/dev/null || true
  for framework in "${RUNTIME}"/python3_ios.framework "${RUNTIME}"/modules/*.framework; do
    [ -f "${framework}/python3_ios" ] && strip -x "${framework}/python3_ios" 2>/dev/null || true
    binary="$(basename "${framework}")"
    [ -f "${framework}/${binary}" ] && strip -x "${framework}/${binary}" 2>/dev/null || true
  done
fi

echo "[slim] sau khi cắt: $(du -sh "${RUNTIME}" | cut -f1)"
