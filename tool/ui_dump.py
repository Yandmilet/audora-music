"""真机 UI 取证小工具：dump 当前界面并把带文字的节点写成 UTF-8 清单。

只给本机调试用：uiautomator 的输出在 Windows 控制台上会乱码，所以落到文件里读。
用法: python tool/ui_dump.py [输出文件名]
"""
import re
import subprocess
import sys

out = sys.argv[1] if len(sys.argv) > 1 else "ui_dump.txt"

subprocess.run(["adb", "shell", "uiautomator", "dump", "/sdcard/audora_ui.xml"],
               check=True, capture_output=True)
subprocess.run(["adb", "pull", "/sdcard/audora_ui.xml", "audora_ui.xml"],
               check=True, capture_output=True)

xml = open("audora_ui.xml", encoding="utf-8").read()
lines = []
for m in re.finditer(r"<node([^>]*)>", xml):
    a = dict(re.findall(r'([\w-]*)="([^"]*)"', m.group(1)))
    txt = (a.get("text") or "").strip()
    desc = (a.get("content-desc") or "").strip()
    label = txt or desc
    if not label:
        continue
    lines.append(
        f"{label!r}\tclass={a.get('class','').split('.')[-1]}\t"
        f"clickable={a.get('clickable')}\tbounds={a.get('bounds')}"
    )
open(out, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print(f"wrote {len(lines)} nodes -> {out}")
