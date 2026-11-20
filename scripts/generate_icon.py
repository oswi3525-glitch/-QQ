#!/usr/bin/env python3
"""Chuyển đổi logo.svg thành icon-1024.png cho App Icon của WQTerm (iOS)."""

import os
import cairosvg

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SVG_PATH = os.path.join(
    BASE_DIR, "WQTerm", "Resources", "Assets.xcassets", "AppIcon.appiconset", "logo.svg"
)
PNG_PATH = os.path.join(
    BASE_DIR, "WQTerm", "Resources", "Assets.xcassets", "AppIcon.appiconset", "icon-1024.png"
)

cairosvg.svg2png(url=SVG_PATH, write_to=PNG_PATH, output_width=1024, output_height=1024)
print(f"[generate_icon] Đã tạo {PNG_PATH} (1024x1024)")