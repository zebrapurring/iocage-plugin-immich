#!/bin/sh

set -eux

IMMICH_REPO_DIR="/usr/local/src/immich"
IMMICH_INSTALL_DIR="/usr/local/share/immich"
IMMICH_MEDIA_DIR="/mnt/media"
IMMICH_REPO_URL="https://github.com/immich-app/immich"
IMMICH_VERSION_TAG="v1.117.0"
POSTGRES_PASSWORD="$(dd if=/dev/urandom bs=1 count=100 status=none | md5 -q)"

# Configure PostgreSQL
/usr/local/etc/rc.d/postgresql oneinitdb
service postgresql onestart
echo "$POSTGRES_PASSWORD" | pw usermod postgres -h 0
su - postgres -c "createdb immich -O postgres"
echo "shared_preload_libraries = '/usr/local/lib/postgresql/vector.so'" >> /var/db/postgres/data16/postgresql.conf
service postgresql onestop

# Create immich user
pw groupadd immich -g 372
pw useradd immich -u 372 -g 372 -c "Immich Server Daemon" -m -s /usr/sbin/nologin

# Initialise the Immich repository
if [ ! -d "$IMMICH_REPO_DIR" ]; then
    git clone "$IMMICH_REPO_URL" "$IMMICH_REPO_DIR"
fi
git -C "$IMMICH_REPO_DIR" checkout "$IMMICH_VERSION_TAG"
rm -rf "$IMMICH_INSTALL_DIR"
mkdir -p "$IMMICH_INSTALL_DIR"

# Build server backend
cp -R "$IMMICH_REPO_DIR/server"/* "$IMMICH_INSTALL_DIR"
cd "$IMMICH_INSTALL_DIR"
npm ci
npm install --cpu=wasm32 sharp
npm run build
npm prune --omit=dev --omit=optional
npm link && npm install -g @immich/cli

# Build web frontend
mkdir -p "$IMMICH_INSTALL_DIR/staging/open-api"
cp -R "$IMMICH_REPO_DIR/open-api/typescript-sdk" "$IMMICH_INSTALL_DIR/staging/open-api/"
npm --prefix "$IMMICH_INSTALL_DIR/staging/open-api/typescript-sdk" ci
npm --prefix "$IMMICH_INSTALL_DIR/staging/open-api/typescript-sdk" run build
npm --prefix "$IMMICH_INSTALL_DIR/staging/open-api/typescript-sdk" prune --omit=dev --omit=optional
cp -R "$IMMICH_REPO_DIR/web" "$IMMICH_INSTALL_DIR/staging/"
patch -p1 "$IMMICH_INSTALL_DIR/staging/web/package.json" << EOF
diff --git a/web/package.json b/web/package.json
index f4ba5e6c9..5b0104e9b 100644
--- a/web/package.json
+++ b/web/package.json
@@ -86,6 +86,12 @@
     "svelte-maplibre": "^0.9.13",
     "thumbhash": "^0.1.1"
   },
+  "overrides": {
+    "@sveltejs/kit": {
+      "rollup": "npm:@rollup/wasm-node@latest"
+    },
+    "rollup": "npm:@rollup/wasm-node@latest"
+  },
   "volta": {
     "node": "20.17.0"
   }
EOF
rm "$IMMICH_INSTALL_DIR/staging/web/package-lock.json"
npm --prefix "$IMMICH_INSTALL_DIR/staging/web" install
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
cat > "$IMMICH_INSTALL_DIR/.env" << EOF
IMMICH_BUILD=""
IMMICH_BUILD_URL=""
IMMICH_BUILD_IMAGE=""
IMMICH_BUILD_IMAGE_URL=""
IMMICH_REPOSITORY="immich-app/immich"
IMMICH_REPOSITORY_URL="$(git -C "$IMMICH_REPO_DIR" remote get-url origin)"
IMMICH_SOURCE_REF=""
IMMICH_SOURCE_COMMIT="$(git -C "$IMMICH_REPO_DIR" rev-parse HEAD)"
IMMICH_SOURCE_URL=""

NO_COLOR=true
IMMICH_ENV="production"
IMMICH_MEDIA_LOCATION="$IMMICH_MEDIA_DIR"
IMMICH_BUILD_DATA="$IMMICH_INSTALL_DIR/build"

DB_HOSTNAME="localhost"
DB_USERNAME="postgres"
DB_DATABASE_NAME="immich"
DB_PASSWORD="$POSTGRES_PASSWORD"
DB_VECTOR_EXTENSION="pgvector"

REDIS_HOSTNAME="localhost"
EOF

# Modify Syslogd configuration to include debug levels
sed -i "" "s/daemon\.info/daemon.*/" /etc/syslog.conf
service syslogd restart

# Enable system services
sysrc postgresql_enable="YES"
sysrc redis_enable="YES"
sysrc immich_enable="YES"
sysrc immich_dir="$IMMICH_INSTALL_DIR"

# Start services
service postgresql start
service redis start
service immich start

# Clean up
npm cache clean --force
rm -r "$IMMICH_REPO_DIR"
pkg clean --all
