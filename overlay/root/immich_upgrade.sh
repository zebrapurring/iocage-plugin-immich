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
#pnpm install --no-frozen-lockfile
pnpm install --frozen-lockfile
pnpm --filter @immich/plugin-sdk --filter immich build
pnpm --filter immich --prod --no-optional deploy "$IMMICH_INSTALL_DIR/server"

# Build web frontend
pnpm --filter @immich/sdk --filter immich-web --force install --frozen-lockfile
pnpm --filter @immich/sdk --filter immich-web build
mkdir -p "$IMMICH_INSTALL_DIR/build"
cp -R ./web/build "$IMMICH_INSTALL_DIR/build/www"

# Build CLI
pnpm --filter @immich/sdk --filter @immich/cli install --frozen-lockfile
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

# Generate empty plugins manifest
mkdir -p "$IMMICH_INSTALL_DIR/build/corePlugin"
echo 'H4sIAI2pU2kAA71WsW7bMBDd/RWEpgRw0qBjNyNNCgNNWyBGOxQZaPFksaFIlaQcG0H+vUdSpmRJtSMEzmLIunfkvbvHRz1PCEkkLSD5RBJeFDzNL1KlIZm6wBq04Uq62MfLq8ur8NZyKzx+7vHkOuIZmFTz0tY5LkCelH7MhHoiKS3pkgtuORiSKU1Cesiklc2Vbi26AFpgyMWeqCkw8ozP+K+kNnc4xo39UIpqxeWlR2D4JSRkXFisHFG/fU7IxEABuAv7VtMNsFsuwL+Z7lCR360HkOWWIBTkHqhDtYZSY8CadgbBejEiSWW4XBELG0sKatPc/cMmaFhVgmoCm1KDcd02zSamKkulLbBrJV2mp5T4TZKHBpXmUNDYocBhW3oKavkHUhtXdP3TqgTthrCXETrrKu28bi1mrMaqW4sNdWLhGAZisInsrQqsCV1RLo1tOtpa7KW9cuLxi7D1qIJAVoVvVIpdc7slU5L4ctwDbGja6l4kkdFKWLdok3WYJ9ZAVBYZxqEiVWwwCrz4P7eUGrgHafAwrA/wWyolgMp+JbtiMyoMHK7zV46iR2nG+kyuKsHIEoir4sLEMtrVxudW3djDvxXXwHxzd2p5mLRTavjRE+fneuzEEbuHes2R66S87wHKamLdQGs5qjXddufJLRT9nGM6byt9fjf7cuPU/XP++eZ7nElvhEN9nAl0Z2BN+8xIJTS0x2vhB/q0kgeVUHYgwzJAIAOLo0Im3YxhFdSoE/ioX3jOTiWDMcP9irekdylfU7ThI647k9s3mJLV1RFPugtXgdwSf0WeuYzzcGl4XREqhA8ZcuYt7nysOcURdCSJvw/hIwFvAX/ZHvlICLCZRu9cDzlWL9KlqtZ4qnIIPuUGQLsZY03qNacrlH1L10qjrIbOVy/Um5F+bBVO8ZutTnGDqmTWW+CdzXa3/ymFeo/MI+1Gpg37I/oc4Ye10BhbqJlYVsWQ1hhzAuqEu3buQDg25yZebsSUkPKMozHS/cxDA5uS0xmkL2PO3vqhSfXKCdMtRuafRzrEroYBf5i8TCb/ADCpEVYYDQAA' | base64 -d | gunzip > "$IMMICH_INSTALL_DIR/build/corePlugin/manifest.json"

service immich_server start

# Clean up
pnpm cache delete
rm -rf "$IMMICH_REPO_DIR"