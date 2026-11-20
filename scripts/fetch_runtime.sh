#!/usr/bin/env bash
#
# fetch_runtime.sh — tải Python 3 runtime cho iOS và trích phần arm64.
#
# Vì sao cần: Module 5 yêu cầu Terminal có **Python 3 thật** (không chỉ lệnh giả).
# Gói chính thức của a-Shell (`cpython_05_22/pythonInstall.tar.gz`, 258MB) chứa
# toàn bộ CPython 3.9 đã build cho iOS. Repo không giữ gói này (quá lớn); CI tải
# về, trích đúng phần thiết bị cần rồi nhúng vào `WQTerm.app/python-runtime/`.
#
# Cấu trúc sau khi chạy:
#   WQTerm/Resources/python-runtime/
#     Library/lib/python3.9/...          # stdlib (~36MB)
#     Library/bin/python3                # launcher
#     python3_ios.framework/             # CPython engine (arm64)
#     modules/*.so                       # extension modules (arm64)
#
# Idempotent: nếu thư mục đích đã có `python3_ios.framework` thì bỏ qua.

set -euo pipefail

VERSION="${PYTHON_RUNTIME_VERSION:-cpython_05_22}"
ARCHIVE_URL="https://github.com/holzschu/a-shell/releases/download/${VERSION}/pythonInstall.tar.gz"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${ROOT_DIR}/WQTerm/Resources/python-runtime"
WORK_DIR="${TMPDIR:-/tmp}/wqterm-python-runtime"

if [ -d "${DEST}/python3_ios.framework" ] && [ -d "${DEST}/Library/lib/python3.9" ]; then
  echo "[python-runtime] đã có sẵn, bỏ qua."
  du -sh "${DEST}"
  exit 0
fi

echo "[python-runtime] tải ${VERSION} (khoảng 258MB)..."
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}/extract"

curl -fL --retry 3 --retry-delay 5 -o "${WORK_DIR}/pythonInstall.tar.gz" "${ARCHIVE_URL}"

echo "[python-runtime] trích phần cần thiết..."
tar -xzf "${WORK_DIR}/pythonInstall.tar.gz" -C "${WORK_DIR}/extract" \
  --exclude='*/ios-arm64_x86_64-simulator/*' \
  --exclude='*/ios-arm64_x86_64-maccatalyst/*' \
  --exclude='*/macos-*/*' \
  --exclude='*.dSYM*' \
  --exclude='*/Library/share/*' \
  --exclude='*/Library/include/*' \
  --exclude='*/site-packages/*' \
  'cpython/Library/lib/python3.9' \
  'cpython/Library/bin/python3' \
  'cpython/XcFrameworks' 2>/dev/null || true

mkdir -p "${DEST}/Library/lib" "${DEST}/Library/bin" "${DEST}/modules"

# stdlib
if [ -d "${WORK_DIR}/extract/cpython/Library/lib/python3.9" ]; then
  cp -R "${WORK_DIR}/extract/cpython/Library/lib/python3.9" "${DEST}/Library/lib/"
fi
if [ -f "${WORK_DIR}/extract/cpython/Library/bin/python3" ]; then
  cp "${WORK_DIR}/extract/cpython/Library/bin/python3" "${DEST}/Library/bin/python3"
  chmod 755 "${DEST}/Library/bin/python3"
fi

# CPython engine (arm64 slice)
ENGINE="${WORK_DIR}/extract/cpython/XcFrameworks/python3_ios.xcframework/ios-arm64/python3_ios.framework"
if [ -d "${ENGINE}" ]; then
  cp -R "${ENGINE}" "${DEST}/"
fi

# Extension modules: mỗi xcframework đóng góp 1 .framework arm64
for framework in "${WORK_DIR}"/extract/cpython/XcFrameworks/*.xcframework/ios-arm64/*.framework; do
  [ -d "${framework}" ] || continue
  cp -R "${framework}" "${DEST}/modules/" 2>/dev/null || true
done

rm -rf "${WORK_DIR}"

if [ ! -d "${DEST}/python3_ios.framework" ]; then
  echo "[python-runtime] CẢNH BÁO: không tìm thấy python3_ios.framework — runtime sẽ thiếu." >&2
fi

echo "[python-runtime] xong:"
du -sh "${DEST}"
