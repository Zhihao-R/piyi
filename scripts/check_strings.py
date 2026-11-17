#!/usr/bin/env python3
"""Check for untranslated interface text: have the compiler extract every string to translate from the code, and compare against the English in Localization/en.lproj.
Usage: python3 scripts/check_strings.py   (lists anything missing and exits with a non-zero status)

How to mark text for translation: text written directly in SwiftUI (Text, Button, Label, .help, …) counts automatically; any other user-facing text is written as String(localized: "…").
When the same Chinese phrase needs different English in different places, use String(localized: "key", defaultValue: "中文")."""
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

# Chinese names stored in data as identifiers (formats, platforms, providers), translated only when shown (displayed), which the compiler can't extract: find them in the extractors by how they're written
label = re.compile(r'(?:\.format = |platform: |site: )"([^"]*[\u4e00-\u9fff][^"]*)"')
vendor = re.compile(r'case \.\w+: "([^"]*[\u4e00-\u9fff][^"]*)"')  # provider names: keys are stored by them
sources = [(p, label) for p in glob.glob(os.path.join(ROOT, "Sources/Library/Extract/*.swift"))] + [(os.path.join(ROOT, "Sources/Intelligence/Models/Vendor.swift"), vendor)]
for path, pattern in sources:
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        for name in pattern.findall(line):
            found.setdefault(name, f"{os.path.relpath(path, ROOT)}:{n}")

plurals = set(plistlib.load(open(f"{EN}/Localizable.stringsdict", "rb")))
translated = {unescape(k) for k in strings_keys(f"{EN}/Localizable.strings")} | plurals
missing = {k: where for k, where in found.items() if k not in translated}
# Sentences with counts need a Chinese entry too, otherwise the Chinese interface falls back to English
chinese = set(plistlib.load(open(os.path.join(ROOT, "Localization/zh-Hans.lproj/Localizable.stringsdict"), "rb")))
for key in sorted(plurals - chinese):
    missing[key] = "missing from zh-Hans.lproj/Localizable.stringsdict"
# When a key is written twice the later entry wins and the earlier one silently stops working: when the same Chinese needs two translations, use String(localized: "key", defaultValue: "Chinese") instead
en_keys = re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=', open(f"{EN}/Localizable.strings", encoding="utf-8").read(), re.M)
for key in sorted({k for k in en_keys if en_keys.count(k) > 1}):
    missing[unescape(key)] = "listed twice in en.lproj/Localizable.strings"
for key, where in sorted(missing.items(), key=lambda kv: kv[1]):
    print(f"{where}: {key}")
print(f"{len(found)} strings, {len(missing)} untranslated")
sys.exit(1 if missing else 0)
