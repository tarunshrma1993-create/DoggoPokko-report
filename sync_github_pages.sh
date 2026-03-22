#!/usr/bin/env bash
# Copy packaged site (dist/) into docs/ for GitHub Pages + add .nojekyll
# Replaces only index.html + assets/ so docs/CNAME and other files are kept.
# GitHub Pages: Settings → Pages → Build from branch → main → /docs
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/dist"
DOCS="$ROOT/docs"

if [[ ! -f "$DIST/index.html" ]]; then
  echo "Missing dist/index.html — run: ./package_for_site.sh" >&2
  exit 1
fi

mkdir -p "$DOCS"
rm -rf "$DOCS/assets"
cp -f "$DIST/index.html" "$DOCS/index.html"
cp -R "$DIST/assets" "$DOCS/assets"
touch "$DOCS/.nojekyll"

echo "OK: site copied to docs/ (CNAME and other files in docs/ were preserved)"
echo "Next: push to GitHub. See GITHUB_PAGES.txt"
