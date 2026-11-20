#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""WQTerm AI CLI — gọi LiteRouter bằng `requests`.

Vì sao dùng `requests` thay vì `openai`:
    Package `openai` phụ thuộc pydantic-core (Rust C-extension) — không build
    được cho Python nhúng trong a-Shell trên iOS. `requests` là pure-Python
    (trừ urllib3 đã có sẵn trong a-Shell), nên chạy ổn định.

Cách dùng:
    ai "tóm tắt file này"
    ai --file Info.plist "giải thích các key quan trọng"
    cat file.txt | ai "phân tích log này"
    ai --model deepseek-v4.1-flash-1017 "xin chào"

Cấu hình (thứ tự ưu tiên):
    1. Biến môi trường LITEROUTER_API_KEY / OPENAI_API_KEY
    2. File $WQTERM_HOME/.ai_key
    3. File ~/.ai_key
"""

import argparse
import json
import os
import sys

DEFAULT_ENDPOINT = "https://literouter.fun/api/v1/chat/completions"
DEFAULT_MODEL = "deepseek-v4.1-flash-1017"
MAX_FILE_BYTES = 256 * 1024
TIMEOUT_SECONDS = 120

SYSTEM_PROMPT = (
    "Bạn là trợ lý kỹ thuật của WQTerm trên iOS. "
    "Trả lời ngắn gọn, chính xác, dùng Markdown khi hữu ích."
)


def fail(message: str, code: int = 1) -> "NoReturn":
    sys.stderr.write("ai: " + message + "\n")
    sys.exit(code)


def read_api_key() -> str:
    for name in ("LITEROUTER_API_KEY", "OPENAI_API_KEY", "WQTERM_AI_KEY"):
        value = os.environ.get(name, "").strip()
        if value:
            return value

    home = os.environ.get("WQTERM_HOME") or os.path.expanduser("~")
    for candidate in (
        os.path.join(home, ".ai_key"),
        os.path.join(os.path.expanduser("~"), ".ai_key"),
    ):
        try:
            with open(candidate, "r", encoding="utf-8") as handle:
                value = handle.read().strip()
                if value:
                    return value
        except OSError:
            continue
    return ""


def read_file(path: str) -> str:
    try:
        with open(path, "rb") as handle:
            data = handle.read(MAX_FILE_BYTES + 1)
    except OSError as error:
        fail("không đọc được %s: %s" % (path, error))

    truncated = len(data) > MAX_FILE_BYTES
    data = data[:MAX_FILE_BYTES]

    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        text = data.decode("utf-8", errors="replace")

    if truncated:
        text += "\n… (đã cắt bớt, file lớn hơn %d bytes)" % MAX_FILE_BYTES
    return text


def build_prompt(args: argparse.Namespace) -> str:
    parts = []

    if args.file:
        parts.append("Nội dung file `%s`:\n```\n%s\n```" % (args.file, read_file(args.file)))

    question = " ".join(args.question).strip()
    if question:
        parts.append(question)

    if not sys.stdin.isatty():
        piped = sys.stdin.read(MAX_FILE_BYTES)
        if piped.strip():
            parts.append("Dữ liệu từ stdin:\n```\n%s\n```" % piped.strip())

    if not parts:
        fail("cần câu hỏi, --file, hoặc dữ liệu từ stdin", code=2)

    return "\n\n".join(parts)


def call_api(endpoint: str, model: str, api_key: str, prompt: str) -> str:
    try:
        import requests
    except ImportError:
        fail("thiếu thư viện 'requests'. Chạy: pip install requests")

    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": prompt},
        ],
        "temperature": 0.4,
        "stream": False,
    }
    headers = {
        "Content-Type": "application/json",
        "Authorization": "Bearer " + api_key,
        "User-Agent": "WQTerm-CLI/1.0 (iOS)",
    }

    try:
        response = requests.post(
            endpoint, headers=headers, data=json.dumps(payload), timeout=TIMEOUT_SECONDS
        )
    except Exception as error:  # noqa: BLE001 — requests ném nhiều loại lỗi
        fail("lỗi mạng: %s" % error)

    if response.status_code < 200 or response.status_code >= 300:
        body = (response.text or "").strip()
        fail("HTTP %d: %s" % (response.status_code, body[:500]))

    try:
        document = response.json()
    except ValueError:
        fail("phản hồi không phải JSON: %s" % (response.text or "")[:300])

    choices = document.get("choices") or []
    if not choices:
        message = (document.get("error") or {}).get("message", "")
        fail("không có 'choices' trong phản hồi. %s" % message)

    first = choices[0]
    message = first.get("message") or {}
    content = message.get("content") or first.get("text") or ""
    if not content.strip():
        fail("phản hồi rỗng")
    return content.strip()


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="ai", description="Hỏi AI qua LiteRouter (LiteRouter/OpenAI-compatible)."
    )
    parser.add_argument("question", nargs="*", help="câu hỏi (có thể để trống nếu dùng --file)")
    parser.add_argument("-f", "--file", help="gửi kèm nội dung file (tối đa 256KB)")
    parser.add_argument(
        "-m",
        "--model",
        default=os.environ.get("WQTERM_AI_MODEL", DEFAULT_MODEL),
        help="model (mặc định %s)" % DEFAULT_MODEL,
    )
    parser.add_argument(
        "-e",
        "--endpoint",
        default=os.environ.get("WQTERM_AI_ENDPOINT", DEFAULT_ENDPOINT),
        help="endpoint chat completions",
    )
    args = parser.parse_args()

    api_key = read_api_key()
    if not api_key:
        fail(
            "chưa có API key. Đặt LITEROUTER_API_KEY hoặc ghi key vào ~/.ai_key",
            code=2,
        )

    print(call_api(args.endpoint, args.model, api_key, build_prompt(args)))


if __name__ == "__main__":
    main()
