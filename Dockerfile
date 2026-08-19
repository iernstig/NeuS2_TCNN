# syntax=docker/dockerfile:1.7

ARG CUDA_VERSION=12.8.1
ARG UBUNTU_VERSION=20.04
FROM nvidia/cuda:${CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION}

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

ARG PYTHON_VERSION=3.12
ARG TORCH_VERSION=2.10.0
ARG CUDA_INDEX=cu128

ENV DEBIAN_FRONTEND=noninteractive
ENV CUDA_HOME=/usr/local/cuda
ENV CUDACXX=/usr/local/cuda/bin/nvcc
ENV TORCH_CUDA_ARCH_LIST="7.5;8.6;8.9;9.0"
ENV CMAKE_CUDA_ARCHITECTURES="75;86;89;90"
ENV TCNN_CUDA_ARCHITECTURES="75,86,89,90"
ENV UV_CACHE_DIR=/root/.cache/uv
ENV VIRTUAL_ENV=/opt/venv
ENV PATH=/opt/venv/bin:/usr/local/cuda/bin:$PATH

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .

# the buildable package lives in bindings/torch, not the repo root
WORKDIR /src/bindings/torch

RUN uv venv --python "${PYTHON_VERSION}" "$VIRTUAL_ENV" \
    && uv pip install --python "$VIRTUAL_ENV/bin/python" setuptools wheel build numpy ninja cmake \
    && uv pip install --python "$VIRTUAL_ENV/bin/python" \
         --index-url "https://download.pytorch.org/whl/${CUDA_INDEX}" \
         "torch==${TORCH_VERSION}" \
    && uv cache clean

RUN rm -rf dist build *.egg-info \
    && python -m build --wheel --no-isolation \
    && TORCH_TAG=$(echo "${TORCH_VERSION}" | tr -d '.') \
    && LOCAL_TAG="torch${TORCH_TAG}${CUDA_INDEX}" \
    && python - "$LOCAL_TAG" <<'PYEOF'
import re, shutil, subprocess, sys
from pathlib import Path

suffix = "+" + sys.argv[1]
wheel_path = next(Path("dist").glob("*.whl"))

subprocess.run(["wheel", "unpack", str(wheel_path), "-d", "dist/_unpacked"], check=True)
extracted = next(Path("dist/_unpacked").iterdir())
name, base_version = extracted.name.rsplit("-", 1)
new_dir = extracted.with_name(f"{name}-{base_version}{suffix}")
shutil.move(str(extracted), str(new_dir))

dist_info = next(new_dir.glob("*.dist-info"))
shutil.move(str(dist_info), str(dist_info.with_name(f"{name}-{base_version}{suffix}.dist-info")))

metadata = next(new_dir.glob("*.dist-info")) / "METADATA"
text = re.sub(r"^Version: .*$", f"Version: {base_version}{suffix}", metadata.read_text(), count=1, flags=re.M)
metadata.write_text(text)

subprocess.run(["wheel", "pack", str(new_dir), "-d", "dist"], check=True)
wheel_path.unlink()
PYEOF