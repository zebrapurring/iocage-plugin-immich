#!/bin/sh

set -eux

IMMICH_REPO_DIR="/usr/local/src/immich"
IMMICH_INSTALL_DIR="/usr/local/share/immich"
IMMICH_SETTINGS_DIR="/usr/local/etc/immich"
IMMICH_MEDIA_DIR="/var/db/immich-media"
IMMICH_REPO_URL="https://github.com/immich-app/immich"
IMMICH_VERSION_TAG="v1.133.1"
POSTGRES_PASSWORD="$(dd if=/dev/urandom bs=1 count=100 status=none | md5 -q)"
VECTORCHORD_VERSION="0.3.0"
FFMPEG_VERSION="v7.1.1-3"    # Taken from https://github.com/immich-app/base-images/blob/main/server/packages/ffmpeg.json
export PYTHON="python3.11"

# Install VectorChord
rustup-init --profile minimal --default-toolchain none -y
export PATH="$HOME/.cargo/bin:$PATH"
vectorchord_staging_dir="$(mktemp -d -t vectorchord)"
git clone --branch "$VECTORCHORD_VERSION" https://github.com/tensorchord/VectorChord "$vectorchord_staging_dir"
cd "$vectorchord_staging_dir"
cargo install cargo-pgrx@"$(sed -n 's/.*pgrx = { version = "\(=.*\)",.*/\1/p' Cargo.toml)" --locked
cargo pgrx init --pg16="$(which pg_config)"
cargo pgrx install --release
cp -a ./sql/upgrade/. "$(pg_config --sharedir)/extension"
cd -
rm -rf "$vectorchord_staging_dir"

# Configure PostgreSQL
/usr/local/etc/rc.d/postgresql oneinitdb
service postgresql onestart
echo "$POSTGRES_PASSWORD" | pw usermod postgres -h 0
su - postgres -c "createdb immich -O postgres"
echo "shared_preload_libraries = 'vchord.so'" >> /var/db/postgres/data16/postgresql.conf
service postgresql onestop

# Install custom ffmpeg
ffmpeg_staging_dir="$(mktemp -d -t jellyfin-ffmpeg)"
git clone --branch "$FFMPEG_VERSION" https://github.com/jellyfin/jellyfin-ffmpeg "$ffmpeg_staging_dir"
cd "$ffmpeg_staging_dir"
ln -s debian/patches patches
quilt push -a
./configure \
    --cc="clang" \
    --extra-cflags="-I/usr/local/include" \
    --extra-ldflags="-L/usr/local/lib" \
    --extra-version="Jellyfin" \
    --disable-doc \
    --disable-ffplay \
    --disable-libxcb \
    --disable-ptx-compression \
    --disable-sdl2 \
    --disable-static \
    --disable-xlib \
    --enable-chromaprint \
    --enable-gmp \
    --enable-gnutls \
    --enable-gpl \
    --enable-libass \
    --enable-libdav1d \
    --enable-libdrm \
    --enable-libfdk-aac \
    --enable-libfontconfig \
    --enable-libfreetype \
    --enable-libfribidi \
    --enable-libharfbuzz \
    --enable-libopenmpt \
    --enable-libopus \
    --enable-libsvtav1 \
    --enable-libvorbis \
    --enable-libvpx \
    --enable-libwebp \
    --enable-libx264 \
    --enable-libx265 \
    --enable-libxml2 \
    --enable-libzimg \
    --enable-libzvbi \
    --enable-lto="auto" \
    --enable-nonfree \
    --enable-opencl \
    --enable-shared \
    --enable-vaapi \
    --enable-version3 \
    --toolchain="hardened"
gmake --jobs "$(nproc)"
gmake install
cd -
rm -rf "$ffmpeg_staging_dir"

# Create immich user
pw groupadd immich -g 372
pw useradd immich -u 372 -g 372 -c "Immich Server Daemon" -d /nonexistent -s /usr/sbin/nologin

# Initialise the Immich repository
if [ ! -d "$IMMICH_REPO_DIR" ]; then
    git clone --branch "$IMMICH_VERSION_TAG" "$IMMICH_REPO_URL" "$IMMICH_REPO_DIR"
fi
rm -rf "$IMMICH_INSTALL_DIR"
mkdir -p "$IMMICH_INSTALL_DIR"

# Build server backend
cp -R "$IMMICH_REPO_DIR/server"/* "$IMMICH_INSTALL_DIR"
cd "$IMMICH_INSTALL_DIR"
npm install --save node-addon-api node-gyp
npm ci --foreground-scripts
npm install --cpu=wasm32 sharp
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
npm --prefix "$IMMICH_INSTALL_DIR/staging/web" install --cpu=wasm32 sharp
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

# Create the media directory
mkdir -p "$IMMICH_MEDIA_DIR"
chown immich:immich "$IMMICH_MEDIA_DIR"

# Configure Immich environment variables
mkdir -p "$IMMICH_SETTINGS_DIR"
cat > "$IMMICH_SETTINGS_DIR/immich_server.env" << EOF
IMMICH_BUILD=""
IMMICH_BUILD_URL=""
IMMICH_BUILD_IMAGE=""
IMMICH_BUILD_IMAGE_URL=""
IMMICH_REPOSITORY="immich-app/immich"
IMMICH_REPOSITORY_URL="$(git -C "$IMMICH_REPO_DIR" remote get-url origin)"
IMMICH_SOURCE_REF=""
IMMICH_SOURCE_COMMIT="$(git -C "$IMMICH_REPO_DIR" rev-parse HEAD)"
IMMICH_SOURCE_URL=""

IMMICH_HOST="0.0.0.0"
IMMICH_PORT="2283"

NO_COLOR=true
IMMICH_ENV="production"
IMMICH_MEDIA_LOCATION="$IMMICH_MEDIA_DIR"
IMMICH_BUILD_DATA="$IMMICH_INSTALL_DIR/build"

DB_HOSTNAME="localhost"
DB_USERNAME="postgres"
DB_DATABASE_NAME="immich"
DB_PASSWORD="$POSTGRES_PASSWORD"

REDIS_HOSTNAME="localhost"
EOF

# Enable system services
sysrc postgresql_enable="YES"
sysrc redis_enable="YES"
sysrc immich_server_enable="YES"
sysrc immich_server_dir="$IMMICH_INSTALL_DIR"

# Start services
service postgresql start
service redis start
service immich_server start

# Clean up
npm cache clean --force
pkg clean --all --yes
rm -r "$IMMICH_REPO_DIR"
rm -rf "$IMMICH_INSTALL_DIR/staging"
