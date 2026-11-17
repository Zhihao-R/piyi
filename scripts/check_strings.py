#!/usr/bin/env python3
"""检查界面文字有没有漏翻：让编译器提取代码里所有要翻译的句子，和 Localization/en.lproj 里的英文对一遍。
用法：python3 scripts/check_strings.py   （有漏的就列出来，并以非零状态退出）

要翻译的句子怎么写：SwiftUI 里直接写的文字（Text、Button、Label、.help…）自动算；其余显示给人看的写成 String(localized: "…")。
同一句中文在不同地方要翻成不同英文时，用 String(localized: "键名", defaultValue: "中文")。"""
import glob, json, os, plistlib, re, subprocess, sys, tempfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
EN = os.path.join(ROOT, "Localization/en.lproj")

def strings_keys(path):
    text = open(path, encoding="utf-8").read()
    return set(re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=', text, re.M))

def unescape(key):
    return key.encode().decode("unicode_escape").encode("latin-1").decode("utf-8")

with tempfile.TemporaryDirectory() as out:
    build = subprocess.run(["swift", "build", "-Xswiftc", "-emit-localized-strings", "-Xswiftc", "-emit-localized-strings-path", "-Xswiftc", out],
                           cwd=ROOT, capture_output=True, text=True)
    if build.returncode != 0:
        sys.exit(build.stdout + build.stderr)
    found = {}
    for f in glob.glob(f"{out}/*.stringsdata"):
        data = json.load(open(f))
        source = os.path.relpath(data["source"], ROOT)
        for entries in data["tables"].values():
            for e in entries:
                found.setdefault(e["key"], f"{source}:{e['location']['startingLine']}")

# 存在数据里当标识用的中文名（格式、平台、服务商），显示时才翻（displayed），编译器提取不到：从抽取器里按写法找
label = re.compile(r'(?:\.format = |platform: |site: )"([^"]*[\u4e00-\u9fff][^"]*)"')
vendor = re.compile(r'case \.\w+: "([^"]*[\u4e00-\u9fff][^"]*)"')  # 服务商的名字：密钥按它存
sources = [(p, label) for p in glob.glob(os.path.join(ROOT, "Sources/Library/Extract/*.swift"))] + [(os.path.join(ROOT, "Sources/Intelligence/Models/Vendor.swift"), vendor)]
for path, pattern in sources:
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        for name in pattern.findall(line):
            found.setdefault(name, f"{os.path.relpath(path, ROOT)}:{n}")

plurals = set(plistlib.load(open(f"{EN}/Localizable.stringsdict", "rb")))
translated = {unescape(k) for k in strings_keys(f"{EN}/Localizable.strings")} | plurals
missing = {k: where for k, where in found.items() if k not in translated}
# 带数量的句子中文也要有一份，否则中文界面会退回英文
chinese = set(plistlib.load(open(os.path.join(ROOT, "Localization/zh-Hans.lproj/Localizable.stringsdict"), "rb")))
for key in sorted(plurals - chinese):
    missing[key] = "zh-Hans.lproj/Localizable.stringsdict 里缺这一句"
# 同一个键写了两遍时后一条生效，前一条悄悄失效：同一句中文要两种译法时改用 String(localized: "键名", defaultValue: "中文")
en_keys = re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=', open(f"{EN}/Localizable.strings", encoding="utf-8").read(), re.M)
for key in sorted({k for k in en_keys if en_keys.count(k) > 1}):
    missing[unescape(key)] = "en.lproj/Localizable.strings 里这一句写了两遍"
for key, where in sorted(missing.items(), key=lambda kv: kv[1]):
    print(f"{where}: {key}")
print(f"共 {len(found)} 句，没翻译的 {len(missing)} 句")
sys.exit(1 if missing else 0)
