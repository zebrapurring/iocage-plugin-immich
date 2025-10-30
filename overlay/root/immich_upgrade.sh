#!/bin/sh

set -eux

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <version>"
    exit 1
fi

IMMICH_REPO_DIR="/usr/local/src/immich"
IMMICH_INSTALL_DIR="/usr/local/share/immich"
IMMICH_REPO_URL="https://github.com/immich-app/immich"
IMMICH_VERSION_TAG="$1"
export PYTHON="python3.11"

service immich_server stop || true
killall node || true

if [ ! -d "$IMMICH_REPO_DIR" ]; then
    git clone --branch "$IMMICH_VERSION_TAG" "$IMMICH_REPO_URL" "$IMMICH_REPO_DIR"
else
    git -C "$IMMICH_REPO_DIR" fetch
    git -C "$IMMICH_REPO_DIR" checkout --force "$IMMICH_VERSION_TAG"
fi

rm -rf "$IMMICH_INSTALL_DIR"
mkdir -p "$IMMICH_INSTALL_DIR"

# Install Corepack
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
export CI=1
npm install --global corepack@latest
corepack enable pnpm

# Build server backend
cd "$IMMICH_REPO_DIR"
# WA: Fix bcrypt error: `No native build was found for platform=freebsd arch=x64 runtime=node abi=127 uv=1 libc=glibc node=22.14.0`
yq -y -i '
      .ignoredBuiltDependencies |= map(select(. != "bcrypt"))
      | .onlyBuiltDependencies += ["bcrypt"]
      | .onlyBuiltDependencies |= (unique)
      | .packageExtensions.bcrypt.dependencies["node-addon-api"] = "*"
      | .packageExtensions.bcrypt.dependencies["node-gyp"] = "*"
   ' pnpm-workspace.yaml
pnpm install --no-frozen-lockfile
pnpm --filter immich install @img/sharp-wasm32
pnpm --filter immich --frozen-lockfile build
pnpm --filter immich --frozen-lockfile --prod --no-optional deploy "$IMMICH_INSTALL_DIR/server"

# Build web frontend
pnpm --filter @immich/sdk --filter immich-web --frozen-lockfile --force install
pnpm --filter @immich/sdk --filter immich-web build
mkdir -p "$IMMICH_INSTALL_DIR/build"
cp -R ./web/build "$IMMICH_INSTALL_DIR/build/www"

# Build CLI
pnpm --filter @immich/sdk --filter @immich/cli --frozen-lockfile install
pnpm --filter @immich/sdk --filter @immich/cli build
pnpm --filter @immich/cli --prod --no-optional deploy "$IMMICH_INSTALL_DIR/cli"

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

# Clean up
rm -rf "$IMMICH_REPO_DIR"
