#!/usr/bin/env bash
# Copy packaged site (dist/) into docs/ for GitHub Pages + add .nojekyll
# GitHub Pages: Settings → Pages → Build from branch → main → /docs
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/dist"
DOCS="$ROOT/docs"

if [[ ! -f "$DIST/index.html" ]]; then
  echo "Missing dist/index.html — run: ./package_for_site.sh" >&2
  exit 1
fi

rm -rf "$DOCS"
mkdir -p "$DOCS"
cp -R "$DIST"/* "$DOCS/"
# Stops GitHub from running Jekyll (avoids broken static sites)
touch "$DOCS/.nojekyll"

echo "OK: site copied to docs/"
echo "Next: push to GitHub and enable Pages (branch main, folder /docs). See GITHUB_PAGES.txt"
