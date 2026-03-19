#!/usr/bin/env bash
set -euo pipefail

DRY_RUN=false
[[ "${1:-}" == '--dry-run' ]] && DRY_RUN=true

mkdir -p tmp

# --- Version check ---
VERSION=$(curl -sf https://docs.dragonruby.org/version.txt)
HTTP=$(curl -sf -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$GITHUB_REPOSITORY/releases/tags/$VERSION" || true)
if [[ "$HTTP" == "200" ]]; then
  echo "$VERSION already released."
  exit 0
fi
echo "New version: $VERSION"

# --- Standard downloads (itch.io API v2) ---
ITCH_AUTH=(-H "Authorization: Bearer $ITCH_IO_API_KEY")
OWNED=$(curl -sf "${ITCH_AUTH[@]}" "https://api.itch.io/profile/owned-keys")
GAME_ID=$(echo "$OWNED" | jq 'first(.owned_keys[] | select(.game.url | contains("dragonruby-gtk"))) | .game.id')
KEY_ID=$(echo "$OWNED"  | jq 'first(.owned_keys[] | select(.game.url | contains("dragonruby-gtk"))) | .id')
UPLOADS=$(curl -sf "${ITCH_AUTH[@]}" "https://api.itch.io/games/$GAME_ID/uploads?download_key_id=$KEY_ID")

for PLATFORM in windows-amd64 macos linux-amd64; do
  FILENAME="dragonruby-gtk-${PLATFORM}.zip"
  UPLOAD_ID=$(echo "$UPLOADS" | jq -r ".uploads[] | select(.filename == \"$FILENAME\") | .id")
  echo "Downloading $FILENAME..."
  curl -fsSL "${ITCH_AUTH[@]}" \
    -o "tmp/$FILENAME" \
    "https://api.itch.io/uploads/$UPLOAD_ID/download?download_key_id=$KEY_ID"
done

# --- Pro downloads (dragonruby.org) ---
API=$(curl -sf https://dragonruby.org/api)
for KEY in pro_windows pro_mac pro_linux; do
  case "$KEY" in
    pro_windows) PLATFORM=windows-amd64 ;;
    pro_mac)     PLATFORM=macos ;;
    pro_linux)   PLATFORM=linux-amd64 ;;
  esac
  ENDPOINT=$(echo "$API" | jq -r ".__links__.download.$KEY")
  URL=$(curl -sf -u "$DRAGONRUBY_PRO_USERNAME:$DRAGONRUBY_PRO_PASSWORD" "$ENDPOINT")
  echo "Downloading dragonruby-pro-${PLATFORM}.zip..."
  curl -fsSL -o "tmp/dragonruby-pro-${PLATFORM}.zip" "$URL"
done

# --- Extract and repackage ---
mkdir -p tmp/extract
for PLATFORM in windows-amd64 macos linux-amd64; do
  PREFIX="dragonruby-${PLATFORM}"
  BINARY=$([[ "$PLATFORM" == "windows-amd64" ]] && echo "dragonruby.exe" || echo "dragonruby")
  for EDITION_TIER in "gtk standard" "pro pro"; do
    EDITION="${EDITION_TIER%% *}"
    TIER="${EDITION_TIER##* }"
    ZIP="tmp/dragonruby-${EDITION}-${PLATFORM}.zip"
    unzip -q -o "$ZIP" "${PREFIX}/*" -x '*.DS_Store' -d tmp/extract
    SRC="tmp/extract/$PREFIX"
    OUTPUT="$(pwd)/tmp/dragonruby-for-ci-${VERSION}-${TIER}-${PLATFORM}.zip"
    (cd "$SRC" && zip -j "$OUTPUT" "$BINARY" font.ttf)
    [[ "$TIER" == "pro" ]] && (cd "$SRC" && zip -r "$OUTPUT" include/ -x '*.DS_Store')
  done
done

# --- Upload ---
if [[ "$DRY_RUN" == "false" ]]; then
  AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json")
  RELEASE=$(curl -sf -X POST "${AUTH[@]}" -H "Content-Type: application/json" \
    -d "{\"tag_name\":\"$VERSION\",\"name\":\"$VERSION\"}" \
    "https://api.github.com/repos/$GITHUB_REPOSITORY/releases")
  UPLOAD_URL=$(echo "$RELEASE" | jq -r '.upload_url' | sed 's/{?name,label}//')
  for FILE in tmp/dragonruby-for-ci-*.zip; do
    FNAME=$(basename "$FILE")
    echo "Uploading $FNAME..."
    curl -sf -X POST "${AUTH[@]}" -H "Content-Type: application/zip" \
      --data-binary "@$FILE" "$UPLOAD_URL?name=$FNAME"
  done
fi
