#!/bin/bash
# Exercise FieldPolicy's decision table without a live app.
#
# FieldPolicy.evaluate(_ context:) takes a FieldContext rather than an
# AXUIElement precisely so these can run offline: no Accessibility grant, no
# frontmost app, no UI. Compiles the real sources, so a rule change that breaks
# a case is caught here.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)/policy-checks"
xcrun --toolchain default swiftc -swift-version 5 -parse-as-library -o "$OUT" \
    Sources/Quill/AXSupport.swift \
    Sources/Quill/Settings.swift \
    Sources/Quill/FieldPolicy.swift \
    scripts/policy-checks.swift
"$OUT"
