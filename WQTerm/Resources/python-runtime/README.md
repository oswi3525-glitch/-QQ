# Python 3 runtime (iOS arm64)

Thư mục này **không** chứa binary trong repo (217MB). CI chạy
`scripts/fetch_runtime.sh` để tải gói CPython chính thức của a-Shell, trích đúng
slice `ios-arm64` rồi đặt vào đây trước khi `xcodegen generate`.

Cấu trúc sau khi script chạy:

```
python-runtime/
├── Library/lib/python3.9/      # stdlib (~36MB)
├── Library/bin/python3         # launcher
├── python3_ios.framework/      # CPython engine (arm64)
└── modules/*.framework         # 316 extension module (arm64)
```

`RuntimeManager` copy cấu trúc này sang `Documents/.terminal/RuntimeManager/python-ios/`
lần đầu chạy, cấp quyền thực thi, rồi thêm vào `PATH` qua `setup_env.sh`.

Nguồn: https://github.com/holzschu/a-shell/releases/tag/cpython_05_22 (BSD/MIT).
