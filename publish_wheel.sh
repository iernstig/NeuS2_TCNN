#!/usr/bin/env bash
# publish_wheel.sh — upload a wheel and regenerate that package's index.html
#
# Prerequisites: `az login` with write access to the storage account
# (anonymous public access only covers reads — writes still need real auth).
#
# Usage:
#   ./publish_wheel.sh <path-to-wheel>
#
# Examples:
#   ./publish_wheel.sh dist/tinycudann-1.6+torch2100cu128-cp312-cp312-manylinux_2_28_x86_64.whl

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <path-to-wheel>" >&2
  exit 1
fi

PACKAGE="tinycudann-neus2"
WHEEL_PATH="$1"

ACCOUNT="${AZURE_STORAGE_ACCOUNT:-wirevision}"
CONTAINER="${AZURE_STORAGE_CONTAINER:-wt-static}"
PREFIX="py-wheels/${PACKAGE}"

if [ ! -f "$WHEEL_PATH" ]; then
  echo "ERROR: wheel not found at ${WHEEL_PATH}" >&2
  exit 1
fi

WHEEL_NAME=$(basename "$WHEEL_PATH")
BLOB_NAME="${PREFIX}/${WHEEL_NAME}"

echo "Uploading ${WHEEL_NAME} to ${CONTAINER}/${BLOB_NAME}..."

# --if-none-match '*' makes the upload fail if this exact blob name already
# exists, instead of silently overwriting it — wheel filenames are immutable.
if ! az storage blob upload \
  --account-name "$ACCOUNT" \
  --container-name "$CONTAINER" \
  --name "$BLOB_NAME" \
  --file "$WHEEL_PATH" \
  --content-type "application/octet-stream" \
  --auth-mode login \
  --if-none-match '*'; then
  echo "ERROR: upload failed — see above." >&2
  echo "If this is because the blob already exists: filenames are immutable," >&2
  echo "bump the local version tag (e.g. +torch2110cu128) and rebuild instead of re-publishing the same name." >&2
  exit 1
fi
echo "OK: uploaded."

echo "Regenerating index.html for ${PACKAGE}..."

RAW_JSON=$(az storage blob list \
  --account-name "$ACCOUNT" \
  --container-name "$CONTAINER" \
  --prefix "${PREFIX}/" \
  --auth-mode login \
  -o json)

WHEELS=$(echo "$RAW_JSON" \
  | grep -oE '"name": *"[^"]*\.whl"' \
  | sed -E 's/"name": *"([^"]*)"/\1/' \
  | sed "s|^${PREFIX}/||" \
  | sort)

if [ -z "$WHEELS" ]; then
  echo "ERROR: no wheels found under ${PREFIX}/ right after uploading — aborting index regeneration." >&2
  exit 1
fi

INDEX_FILE=$(mktemp)
{
  echo "<!DOCTYPE html><html><body>"
  while IFS= read -r w; do
    echo "<a href=\"${w}\">${w}</a><br>"
  done <<< "$WHEELS"
  echo "</body></html>"
} > "$INDEX_FILE"

az storage blob upload \
  --account-name "$ACCOUNT" \
  --container-name "$CONTAINER" \
  --name "${PREFIX}/index.html" \
  --file "$INDEX_FILE" \
  --content-type "text/html" \
  --auth-mode login \
  --overwrite

rm -f "$INDEX_FILE"

echo "OK: index.html updated. ${PACKAGE} now lists $(echo "$WHEELS" | wc -l | tr -d ' ') wheel(s):"
echo "$WHEELS" | sed 's/^/  - /'
echo ""
echo "Index URL: https://${ACCOUNT}.blob.core.windows.net/${CONTAINER}/${PREFIX}/index.html"