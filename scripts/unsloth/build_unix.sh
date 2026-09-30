#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright 2026-present the Unsloth AI Inc. team. All rights reserved.
#
# Configure + build audiocpp_server for one Unsloth prebuilt flavour on Linux or
# macOS. The CI jobs call exactly this script, so a local run reproduces them.
#
# usage: build_unix.sh <src_dir> <build_dir> <flavour>
#   flavour: cpu | cpu-portable | vulkan | cuda | metal
# env:
#   AUDIOCPP_VERSION    version string compiled into --version (required)
#   CUDA_ARCHS          CMAKE_CUDA_ARCHITECTURES for flavour=cuda (required there)
#   JOBS                parallel build jobs (default: all cores)
#   MACOS_METAL         ON|OFF for flavour=metal (default ON; the Intel slice sets OFF)
#   MACOS_DEPLOYMENT    CMAKE_OSX_DEPLOYMENT_TARGET (default 13.3)
#   EXTRA_CMAKE_ARGS    appended verbatim (word-split)
#
# Every flavour links eSpeak-ng statically (GPL-3.0-or-later; data beside the
# server as espeak-ng-data.bin), compiles the model specs in, and leaves the
# native model manager OFF: Studio downloads models itself, so the server needs
# no TLS stack (the Etherll recipe linked the host libssl.so.3 on Linux CUDA).
set -euo pipefail

SRC="${1:?source dir}"
BUILD="${2:?build dir}"
FLAVOUR="${3:?flavour}"
: "${AUDIOCPP_VERSION:?AUDIOCPP_VERSION must be set}"
OS="$(uname -s)"
if [ -z "${JOBS:-}" ]; then
  if [ "$OS" = Darwin ]; then JOBS="$(sysctl -n hw.logicalcpu)"; else JOBS="$(nproc)"; fi
fi

args=(
  -S "$SRC" -B "$BUILD"
  -DCMAKE_BUILD_TYPE=Release
  -DAUDIOCPP_VERSION="$AUDIOCPP_VERSION"
  -DAUDIOCPP_STATIC_ESPEAK=ON
  -DAUDIOCPP_DEPLOYMENT_BUILD=ON
  -DAUDIOCPP_BUILD_NATIVE_MODEL_MANAGER=OFF
  -DENGINE_BUILD_TESTS=OFF
  -DENGINE_ENABLE_LLAMAFILE=ON
  -DENGINE_ENABLE_CUDA_GRAPHS=ON
  # Never -march=native on a CI runner: the bundle would SIGILL on older CPUs.
  # With GGML_NATIVE off ggml builds its x86 baseline (AVX2/FMA/F16C) or the
  # compiler's default armv8-a.
  -DENGINE_ENABLE_NATIVE_CPU=OFF
  -DENGINE_ENABLE_HIP=OFF
)
if command -v ninja >/dev/null 2>&1; then args+=(-G Ninja); fi

if [ "$OS" = Linux ]; then
  # glibc floor = the build host's (ubuntu-22.04 on CI); the C++ runtime is
  # linked in so the bundle does not need a newer libstdc++ than the host has.
  args+=(
    "-DCMAKE_EXE_LINKER_FLAGS=-static-libstdc++ -static-libgcc"
    "-DCMAKE_SHARED_LINKER_FLAGS=-static-libstdc++ -static-libgcc"
    # The dlopen'd ggml CPU variants are CMake MODULE libraries, linked with
    # these flags rather than the SHARED ones.
    "-DCMAKE_MODULE_LINKER_FLAGS=-static-libstdc++ -static-libgcc"
    "-DCMAKE_BUILD_RPATH=\$ORIGIN"
    "-DCMAKE_INSTALL_RPATH=\$ORIGIN"
  )
fi

case "$FLAVOUR" in
  cpu)
    args+=(-DENGINE_ENABLE_CUDA=OFF -DENGINE_ENABLE_VULKAN=OFF -DENGINE_ENABLE_METAL=OFF)
    ;;
  cpu-portable)
    # Every ggml CPU variant as a dlopen'd module picked at runtime by CPUID,
    # so the bundle runs (fast) from SSE4.2-era CPUs to AVX-512 ones.
    args+=(-DENGINE_ENABLE_CUDA=OFF -DENGINE_ENABLE_VULKAN=OFF -DENGINE_ENABLE_METAL=OFF
           -DENGINE_ENABLE_CPU_ALL_VARIANTS=ON)
    ;;
  vulkan)
    args+=(-DENGINE_ENABLE_CUDA=OFF -DENGINE_ENABLE_VULKAN=ON -DENGINE_ENABLE_METAL=OFF)
    ;;
  cuda)
    : "${CUDA_ARCHS:?CUDA_ARCHS must be set for the cuda flavour}"
    # Lean: cudart / cuBLAS / cuFFT are linked dynamically and NOT shipped
    # (Studio loads them from torch's nvidia-* wheels, like llama.cpp's CUDA
    # bundles). NCCL off: it only serves multi-GPU tensor parallelism, and
    # linking it made the server fail to start on hosts without libnccl.so.2.
    args+=(-DENGINE_ENABLE_CUDA=ON -DENGINE_ENABLE_VULKAN=OFF -DENGINE_ENABLE_METAL=OFF
           -DGGML_CUDA_NCCL=OFF -DGGML_STATIC=OFF
           "-DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCHS}")
    if [ -n "${CUDAHOSTCXX:-}" ]; then args+=("-DCMAKE_CUDA_HOST_COMPILER=${CUDAHOSTCXX}"); fi
    ;;
  metal)
    [ "$OS" = Darwin ] || { echo "metal flavour is macOS only" >&2; exit 1; }
    metal="${MACOS_METAL:-ON}"
    args+=(-DENGINE_ENABLE_CUDA=OFF -DENGINE_ENABLE_VULKAN=OFF
           "-DENGINE_ENABLE_METAL=${metal}" "-DGGML_METAL=${metal}"
           -DGGML_METAL_EMBED_LIBRARY=ON
           -DENGINE_ENABLE_OPENMP=OFF -DGGML_OPENMP=OFF
           "-DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOS_DEPLOYMENT:-13.3}"
           "-DCMAKE_INSTALL_RPATH=@loader_path" -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON)
    ;;
  *)
    echo "unknown flavour '$FLAVOUR' (cpu|cpu-portable|vulkan|cuda|metal)" >&2; exit 1 ;;
esac

# shellcheck disable=SC2206
[ -n "${EXTRA_CMAKE_ARGS:-}" ] && args+=(${EXTRA_CMAKE_ARGS})

echo "cmake ${args[*]}"
cmake "${args[@]}"
cmake --build "$BUILD" --config Release --parallel "$JOBS" --target audiocpp_server

BIN="$BUILD/bin"
[ -x "$BIN/audiocpp_server" ] || { echo "build produced no $BIN/audiocpp_server" >&2; exit 1; }
[ -s "$BIN/espeak-ng-data.bin" ] || { echo "build staged no espeak-ng-data.bin" >&2; exit 1; }
if [ "$FLAVOUR" = cuda ] && [ "$OS" = Linux ]; then
  # Proof the lean contract held at link time, before packaging even starts.
  if find "$BIN" -maxdepth 1 -type f \( -name 'audiocpp_server' -o -name '*.so*' \) -print0 \
      | xargs -0 readelf -d 2>/dev/null | grep -E 'NEEDED.*libnccl'; then
    echo "NCCL is linked; the lean CUDA bundle must not need libnccl" >&2; exit 1
  fi
fi
echo "built $BIN/audiocpp_server ($FLAVOUR)"
