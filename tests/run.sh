#!/usr/bin/env bash
# Runs both test suites. See tests/README.md.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "== Model.js (node --test) =="
node --test tests/

echo
echo "== Python scripts embedded in Service.qml (unittest) =="
python3 -m unittest discover -s tests -v
