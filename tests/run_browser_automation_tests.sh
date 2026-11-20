#!/bin/bash
# Hostless verification. Prerequisites: Swift, node + jsdom, Python + SDK test deps.
# Example: NODE_PATH=/tmp/iterm2-browser-dom/node_modules \
#   BROWSER_AUTOMATION_PYTHON=/tmp/iterm2-browser-python/bin/python tests/run_browser_automation_tests.sh
set -euo pipefail
cd "$(dirname "$0")/.."
BROWSER_AUTOMATION_PYTHON="${BROWSER_AUTOMATION_PYTHON:-python3}"
BROWSER_AUTOMATION_SCRATCH=$(mktemp -d /tmp/iterm2-browser-tests.XXXXXX)
trap 'rm -rf "$BROWSER_AUTOMATION_SCRATCH"' EXIT
cp tests/browser_automation_model_tests.swift "$BROWSER_AUTOMATION_SCRATCH/main.swift"
swiftc -warnings-as-errors sources/Browser/Automation/iTermBrowserAutomationRequest.swift \
  "$BROWSER_AUTOMATION_SCRATCH/main.swift" -o "$BROWSER_AUTOMATION_SCRATCH/model"
"$BROWSER_AUTOMATION_SCRATCH/model"
swiftc -warnings-as-errors tests/browser_automation_host_stubs.swift \
  sources/Browser/Automation/iTermBrowserAutomationRequest.swift \
  sources/Browser/Automation/iTermBrowserAutomationBroker.swift \
  tests/browser_automation_broker_tests.swift -o "$BROWSER_AUTOMATION_SCRATCH/broker"
"$BROWSER_AUTOMATION_SCRATCH/broker"
node tests/browser_automation_dom_test.cjs
PYTHONPATH=api/library/python/iterm2 "$BROWSER_AUTOMATION_PYTHON" -m pytest \
  api/library/python/iterm2/tests tests/test_browser_automation.py -q
