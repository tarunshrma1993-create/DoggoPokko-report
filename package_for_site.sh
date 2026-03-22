#!/usr/bin/env bash
# Build a folder you can upload to GoDaddy hosting (public_html).
# Usage: ./package_for_site.sh
#   (run `ruby run_report.rb` first if engagement_report.html is stale)

set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="${DIST:-$ROOT/dist}"

if [[ ! -f "$ROOT/engagement_report.html" ]]; then
  echo "Missing engagement_report.html — run: ruby run_report.rb" >&2
  exit 1
fi

rm -rf "$DIST"
mkdir -p "$DIST"

cp "$ROOT/engagement_report.html" "$DIST/index.html"
cp -R "$ROOT/assets" "$DIST/assets"

echo "Built: $DIST"
echo "Upload the *contents* of this folder into your GoDaddy site root:"
echo "  - cPanel / Web Hosting: usually public_html/"
echo "  - Put index.html and the assets/ folder there (same level)."
echo "Then open https://doggopokko.com/ — the report will load as the home page."
echo ""
echo "Or run ./ship.sh to regenerate the report, rebuild dist/, and FTP-upload (if GODADDY_FTP_* are in .env)."
