#!/usr/bin/env bash
# Regenerate report, build dist/, and upload to GoDaddy FTP if .env has GODADDY_FTP_* set.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
ruby run_report.rb
./package_for_site.sh
ruby upload_site.rb
