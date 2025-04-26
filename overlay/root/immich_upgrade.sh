#!/bin/sh

set -eux

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <version>"
    exit 1
fi

IMMICH_REPO_DIR="/usr/local/src/immich"
IMMICH_INSTALL_DIR="/usr/local/share/immich"
IMMICH_VERSION_TAG="$1"
export PYTHON="python3.11"

service immich_server stop || true
killall node || true

git -C "$IMMICH_REPO_DIR" fetch
git -C "$IMMICH_REPO_DIR" checkout --force "$IMMICH_VERSION_TAG"

rm -rf "$IMMICH_INSTALL_DIR"
mkdir -p "$IMMICH_INSTALL_DIR"

# Build server backend
cp -R "$IMMICH_REPO_DIR/server"/* "$IMMICH_INSTALL_DIR"
cd "$IMMICH_INSTALL_DIR"
npm ci
# Build sharp from source to enable HEIC support
# WA: fix error `Override for sharp@^0.34.0 conflicts with direct dependency`
jq 'del(.overrides.sharp)' package.json > package.json.patched && mv package.json.patched package.json
sharp_version="$(jq -r '.dependencies.sharp' package.json | tr -d '^')"
npm install --save node-addon-api node-gyp
npm install --cpu=wasm32 --foreground-scripts --build-from-source "sharp@$sharp_version"
npm run build
npm link && npm install -g @immich/cli

# Build web frontend
mkdir -p "$IMMICH_INSTALL_DIR/staging/open-api"
cp -R "$IMMICH_REPO_DIR/open-api/typescript-sdk" "$IMMICH_INSTALL_DIR/staging/open-api/"
cp -R "$IMMICH_REPO_DIR/i18n" "$IMMICH_INSTALL_DIR/staging/"
npm --prefix "$IMMICH_INSTALL_DIR/staging/open-api/typescript-sdk" ci
npm --prefix "$IMMICH_INSTALL_DIR/staging/open-api/typescript-sdk" run build
npm --prefix "$IMMICH_INSTALL_DIR/staging/open-api/typescript-sdk" prune --omit=dev --omit=optional
cp -R "$IMMICH_REPO_DIR/web" "$IMMICH_INSTALL_DIR/staging/"
npm --prefix "$IMMICH_INSTALL_DIR/staging/web" ci
npm --prefix "$IMMICH_INSTALL_DIR/staging/web" run build
npm --prefix "$IMMICH_INSTALL_DIR/staging/web" prune --omit=dev --omit=optional
mkdir "$IMMICH_INSTALL_DIR/build"
mv "$IMMICH_INSTALL_DIR/staging/web/build" "$IMMICH_INSTALL_DIR/build/www"

# Populate geodata
mkdir "$IMMICH_INSTALL_DIR/build/geodata"
curl -o "$IMMICH_INSTALL_DIR/build/geodata/cities500.zip" https://download.geonames.org/export/dump/cities500.zip
unzip "$IMMICH_INSTALL_DIR/build/geodata/cities500.zip" -d "$IMMICH_INSTALL_DIR/build/geodata" && rm "$IMMICH_INSTALL_DIR/build/geodata/cities500.zip"
curl -o "$IMMICH_INSTALL_DIR/build/geodata/admin1CodesASCII.txt" https://download.geonames.org/export/dump/admin1CodesASCII.txt
curl -o "$IMMICH_INSTALL_DIR/build/geodata/admin2Codes.txt" https://download.geonames.org/export/dump/admin2Codes.txt
curl -o "$IMMICH_INSTALL_DIR/build/geodata/ne_10m_admin_0_countries.geojson" https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson/ne_10m_admin_0_countries.geojson
date -u +"%Y-%m-%dT%H:%M:%S%z" | tr -d "\n" > "$IMMICH_INSTALL_DIR/build/geodata/geodata-date.txt"
chmod 444 "$IMMICH_INSTALL_DIR/build/geodata"/*

# Generate empty build lockfile
echo "{}" > "$IMMICH_INSTALL_DIR/build/build-lock.json"

service immich_server start