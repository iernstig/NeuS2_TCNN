#!/usr/bin/env bash
set -euo pipefail

CUDA_VERSION="${CUDA_VERSION:-12.8.1}"
UBUNTU_VERSION="${UBUNTU_VERSION:-20.04}"
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"
TORCH_VERSION="${TORCH_VERSION:-2.10.0}"
CUDA_INDEX="${CUDA_INDEX:-cu128}"

# --- check 0: does CUDA_VERSION (nvcc) match CUDA_INDEX (torch's runtime)? ---
CUDA_MAJOR_MINOR=$(echo "$CUDA_VERSION" | cut -d. -f1,2)
INDEX_MAJOR_MINOR="${CUDA_INDEX:2:2}.${CUDA_INDEX:4}"

echo "Checking CUDA_VERSION=${CUDA_VERSION} matches CUDA_INDEX=${CUDA_INDEX}..."

if [ "$CUDA_MAJOR_MINOR" != "$INDEX_MAJOR_MINOR" ] && [ -z "${ALLOW_CUDA_MISMATCH:-}" ]; then
  echo "ERROR: base image CUDA is ${CUDA_MAJOR_MINOR} but CUDA_INDEX=${CUDA_INDEX} implies ${INDEX_MAJOR_MINOR}." >&2
  echo "Set matching values (e.g. CUDA_VERSION=12.8.1 CUDA_INDEX=cu128), or ALLOW_CUDA_MISMATCH=1 to override." >&2
  exit 1
fi
echo "OK: CUDA toolkit and torch runtime versions agree (${CUDA_MAJOR_MINOR})."

# --- check 1: does the nvidia/cuda base image tag exist? ---
BASE_TAG="${CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION}"
echo "Checking nvidia/cuda:${BASE_TAG} on Docker Hub..."

STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  "https://hub.docker.com/v2/repositories/nvidia/cuda/tags/${BASE_TAG}")

if [ "$STATUS" != "200" ]; then
  echo "ERROR: nvidia/cuda:${BASE_TAG} not found (HTTP ${STATUS})." >&2
  echo "Close matches for CUDA_VERSION=${CUDA_VERSION}:" >&2
  curl -fsSL "https://hub.docker.com/v2/repositories/nvidia/cuda/tags?page_size=100&name=${CUDA_VERSION}" \
    | grep -oE '"name":"[^"]*devel[^"]*"' \
    | sed -E 's/"name":"([^"]*)"/\1/' \
    | sed 's/^/  - /' >&2
  exit 1
fi
echo "OK: nvidia/cuda:${BASE_TAG} exists."

# --- check 2: does the requested torch version exist on this CUDA index? ---
CP_TAG="cp$(echo "$PYTHON_VERSION" | tr -d '.')"
INDEX_URL="https://download.pytorch.org/whl/${CUDA_INDEX}/torch/"
echo "Checking torch==${TORCH_VERSION} availability for ${CP_TAG} on ${CUDA_INDEX}..."

PAGE=$(curl -fsSL "$INDEX_URL") || {
  echo "ERROR: couldn't reach ${INDEX_URL} — is CUDA_INDEX=${CUDA_INDEX} valid?" >&2
  exit 1
}

AVAILABLE=$(echo "$PAGE" \
  | grep -oE "torch-[0-9]+\.[0-9]+\.[0-9]+(\+[a-zA-Z0-9]+)?-${CP_TAG}-${CP_TAG}-[a-zA-Z0-9_.]+\.whl" \
  | sed -E 's/^torch-([0-9]+\.[0-9]+\.[0-9]+).*/\1/' | sort -Vu)

if ! echo "$AVAILABLE" | grep -qx "$TORCH_VERSION"; then
  echo "ERROR: torch==${TORCH_VERSION} not found for ${CP_TAG} on ${CUDA_INDEX}." >&2
  echo "Available versions:" >&2
  echo "$AVAILABLE" | sed 's/^/  - /' >&2
  exit 1
fi
echo "OK: torch==${TORCH_VERSION} is available."

# --- build ---
IMAGE_TAG="torchhull-build:${TORCH_VERSION}-${CUDA_INDEX}-ubuntu${UBUNTU_VERSION}"

docker build \
  --build-arg CUDA_VERSION="${CUDA_VERSION}" \
  --build-arg UBUNTU_VERSION="${UBUNTU_VERSION}" \
  --build-arg PYTHON_VERSION="${PYTHON_VERSION}" \
  --build-arg TORCH_VERSION="${TORCH_VERSION}" \
  --build-arg CUDA_INDEX="${CUDA_INDEX}" \
  -t "${IMAGE_TAG}" .

CID=$(docker create "${IMAGE_TAG}")
mkdir -p ./dist
docker cp "${CID}:/src/bindings/torch/dist/." ./dist/
docker rm "${CID}" > /dev/null

echo "Built:"
ls ./dist/*.whl