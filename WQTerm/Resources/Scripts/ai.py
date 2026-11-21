#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Tương thích ngược cho lệnh `ai`: chuyển tiếp sang ai_cli.py (Groq API)."""

import os
import runpy
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CLI = os.path.join(HERE, "ai_cli.py")

if not os.path.exists(CLI):
    sys.stderr.write("ai: không tìm thấy ai_cli.py trong %s\n" % HERE)
    sys.exit(1)

sys.argv[0] = CLI
runpy.run_path(CLI, run_name="__main__")
