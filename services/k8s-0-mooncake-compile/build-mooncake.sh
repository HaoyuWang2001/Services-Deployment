#!/usr/bin/env bash
set -euo pipefail

# ===================== 配置项 =====================

export CLEAN_BUILD=${CLEAN_BUILD:-true} # 应当显示指定

# 代理（可选）：PROXY_IP 为空 → 不覆盖代理，沿用容器自身网络/代理配置
PROXY_IP="${PROXY_IP:-}"
PROXY_PORT="${PROXY_PORT:-3128}"
if [[ -n "${PROXY_IP}" ]]; then
    export http_proxy="http://${PROXY_IP}:${PROXY_PORT}"
    export https_proxy="${http_proxy}"
fi
export no_proxy=192.168.0.0/16,141.0.0.0/8,10.0.0.0/8,172.16.0.0/12,127.0.0.1,localhost,local,.local

SRC_ROOT=${SRC_ROOT:-"/workspace/Mooncake"}
BUILD_DIR="${SRC_ROOT}/build"

export PATH="/usr/local/go/bin:${PATH}"

VENV=""
VENV_PIP="$( [[ -n "${VENV:-}" ]] && printf '%s' "${VENV}/bin/pip" || printf 'pip' )"

BIN_TARGETS=(
    "mooncake_master"
    "mooncake_client"
    "stress_clutser_bench"
)
SO_TARGETS=(
    "libasio.so"
    "libetcd_wrapper.so"
)

# ===================== 编译 Mooncake =====================
echo ">> Enter source root: ${SRC_ROOT}"
cd "${SRC_ROOT}"

COMMIT_ID=$(git rev-parse --short HEAD)
OUTPUT_DIR="${SRC_ROOT}/outputs"
OUTPUT_BIN_DIR="${OUTPUT_DIR}/mooncake-${COMMIT_ID}-aarch64-linux/bin"
OUTPUT_LIB_DIR="${OUTPUT_DIR}/mooncake-${COMMIT_ID}-aarch64-linux/lib"
OUTPUT_DIST_DIR="${OUTPUT_DIR}/mooncake-${COMMIT_ID}-aarch64-linux/dist"
WHEEL_SRC_DIR="${SRC_ROOT}/mooncake-wheel/dist"
LINK_BIN="${OUTPUT_DIR}/bin"
LINK_LIB="${OUTPUT_DIR}/lib"
LINK_DIST="${OUTPUT_DIR}/dist"

mkdir -p run
exec 9>run/build.lock
flock -n 9 || { echo "BUILD_SKIPPED: 已有编译在运行"; exit 1; }

if [[ "${CLEAN_BUILD}" == "true" && -d "${BUILD_DIR}" ]]; then
    echo "[INFO] Clean build directory: ${BUILD_DIR}"
    rm -rf "${BUILD_DIR}"
fi

echo ">> Configure CMake (modern -B build style, Ninja+ccache 加速)"
SPDIAG_DIR="/usr/lib64/cmake/SpDiag"
SPDIAG_CLI="/usr/bin/spdiag"
URMA_ROOT="/usr/include/ub/umdk/urma"
UMDK_ROOT="/usr/include/ub/umdk/urma"
URMA_LIBRARY="/usr/lib64/liburma.so"

# -pipe：编译走管道、少落临时文件，多核并发时省 I/O（参考 ssh-0-mooncake-compile）
export CXXFLAGS="${CXXFLAGS:-} -w -pipe"
export CFLAGS="${CFLAGS:-} -w -pipe"

# 生成器优先 Ninja（多核调度开销小于 Make）；容器未装 ninja 则回退默认(Make)
GEN_ARGS=""
if command -v ninja >/dev/null 2>&1; then
    GEN_ARGS="-G Ninja"
    # 旧 build 目录的 CMakeCache 生成器与 Ninja 不匹配会报错，首次切换时自动清理一次
    if [[ -f "${BUILD_DIR}/CMakeCache.txt" ]] && \
       ! grep -q '^CMAKE_GENERATOR:INTERNAL=Ninja$' "${BUILD_DIR}/CMakeCache.txt"; then
        echo "[INFO] Generator changed to Ninja, cleaning build dir: ${BUILD_DIR}"
        rm -rf "${BUILD_DIR}"
    fi
    echo "[INFO] 使用 Ninja 生成器"
else
    echo "[WARN] 容器未安装 ninja，回退到默认生成器（Make）"
fi

# 增量编译优先走 ccache；未安装则跳过（每次全量）
CCACHE_ARGS=""
if command -v ccache >/dev/null 2>&1; then
    CCACHE_ARGS="-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache"
    echo "[INFO] 使用 ccache 加速增量编译"
else
    echo "[WARN] 容器未安装 ccache，跳过（每次全量编译）"
fi

# 加速相关选项（参考 ssh-0-mooncake-compile）：
#   -DCMAKE_BUILD_TYPE=Release        -O3（RelWithDebInfo 为 -O2 -g），实测快 3-5%
#   -DENABLE_DEBUG_SYMBOLS=OFF        关掉 common.cmake 强加的 -g，去符号省编译时间/内存/.o 体积
cmake -B "${BUILD_DIR}" -S . ${GEN_ARGS} ${CCACHE_ARGS} \
  -DUSE_UB=ON \
  -DUSE_CUDA=OFF \
  -DUSE_URING=ON \
  -DUSE_HTTP=ON \
  -DUSE_ETCD=ON \
  -DSTORE_USE_ETCD=ON \
  -DWITH_TE=ON \
  -DWITH_STORE=ON \
  -DWITH_STORE_RUST=OFF \
  -DWITH_P2P_STORE=OFF \
  -DWITH_STORE_GO=OFF \
  -DBUILD_BENCHMARK=ON \
  -DBUILD_UNIT_TESTS=OFF \
  -DBUILD_EXAMPLES=ON \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_DEBUG_SYMBOLS=OFF \
  -DCMAKE_SKIP_RPATH=ON \
  -DCMAKE_DISABLE_FIND_PACKAGE_AWSSDK=ON \
  -DMOONCAKE_ENABLE_SPDIAG=ON \
  -DSpDiag_DIR="${SPDIAG_DIR}" \
  -DMOONCAKE_SPDIAG_SYSTEM_CLI="${SPDIAG_CLI}" \
  -DURMA_ROOT="${URMA_ROOT}" \
  -DUMDK_ROOT="${UMDK_ROOT}" \
  -DURMA_LIBRARY="${URMA_LIBRARY}" \
  -DYLT_ENABLE_URMA=OFF

echo ">> Build targets"
export GOPROXY="http://mirrors.aliyun.com/goproxy,direct"
export GOINSECURE="go.etcd.io/etcd"
export GOSUMDB="sum.golang.org"
cmake --build "${BUILD_DIR}" -j"$(nproc)" --target mooncake_master mooncake_client engine store transfer_engine_bench stress_cluster_bench

echo ">> Build python wheel"
if [[ -n "${VENV}" ]]; then
    if [[ ! -f "${VENV}/bin/activate" ]]; then
        echo "ERROR: Python virtual environment not found: ${VENV}" >&2
        exit 1
    fi
    (
        source "${VENV}/bin/activate"
        bash scripts/build_wheel.sh
    )
else
    bash scripts/build_wheel.sh
fi

# ==================== 收集二进制、动态库、whl =====================
echo ">> Copy binaries to ${OUTPUT_BIN_DIR}"
mkdir -p "${OUTPUT_BIN_DIR}"
cp -f \
  "${BUILD_DIR}/mooncake-store/src/mooncake_master" \
  "${BUILD_DIR}/mooncake-store/src/mooncake_client" \
  "${BUILD_DIR}/mooncake-store/benchmarks/stress_cluster_bench" \
  "${OUTPUT_BIN_DIR}/"

mkdir -p "${OUTPUT_LIB_DIR}"
cp -f \
  "${BUILD_DIR}/mooncake-common/libasio.so" \
  "${BUILD_DIR}/mooncake-common/etcd/libetcd_wrapper.so" \
  "${OUTPUT_LIB_DIR}/"

mkdir -p "${OUTPUT_DIST_DIR}"
cp -f \
  "${WHEEL_SRC_DIR}"/mooncake_transfer_engine-*.whl "${OUTPUT_DIST_DIR}/"

# ===================== 创建软链接 =====================
echo "[INFO] Prepare outputs dir & symlinks"
mkdir -p "${LINK_BIN}" "${LINK_LIB}" "${LINK_DIST}"

for bin_name in "${BIN_TARGETS[@]}"; do
    src_bin="${OUTPUT_BIN_DIR}/${bin_name}"
    link_path="${LINK_BIN}/${bin_name}"
    if [[ -f "${src_bin}" ]]; then
        rm -f "${link_path}"
        ln -s "${src_bin}" "${link_path}"
        echo "[INFO] Create symlink: ${link_path} -> ${src_bin}"
    else
        echo "[WARN] Binary not found: ${src_bin}, skip link"
    fi
done

echo "[INFO] Prepare lib symlinks"
for so_name in "${SO_TARGETS[@]}"; do
    src_so="${OUTPUT_LIB_DIR}/${so_name}"
    link_path="${LINK_LIB}/${so_name}"
    if [[ -f "${src_so}" ]]; then
        rm -f "${link_path}"
        ln -s "${src_so}" "${link_path}"
        echo "[INFO] Create symlink: ${link_path} -> ${src_so}"
    else
        echo "[WARN] Shared library not found: ${src_so}, skip link"
    fi
done

echo "[INFO] Collect wheel package to ${LINK_DIST}"
if [[ -d "${WHEEL_SRC_DIR}" ]]; then
    WHEEL_FILE=$(ls -1 "${OUTPUT_DIST_DIR}"/mooncake_transfer_engine-*.whl | head -n1)
    WHEEL_LINK="${LINK_DIST}"/$(basename "${WHEEL_FILE}")
    mkdir -p "${LINK_DIST}"
    rm -f "${LINK_DIST}"/*.whl
    ln -s "${WHEEL_FILE}" "${WHEEL_LINK}"
    echo "[INFO] Wheel symlink: ${WHEEL_LINK} -> ${WHEEL_FILE}"
else
    echo "[WARN] mooncake-wheel/dist dir not found, skip wheel collect"
fi

echo ">> Reinstall mooncake-transfer-engine into local venv"
${VENV_PIP} uninstall -y mooncake-transfer-engine
${VENV_PIP} install mooncake-wheel/dist/mooncake_transfer_engine-*.whl

echo "==== Build & Distribute & Install Finished ===="
echo "Binaries entry: ${OUTPUT_BIN_DIR}"
echo "Wheel entry: ${OUTPUT_DIST_DIR}"
echo "Binaries symlink entry: ${LINK_BIN}"
echo "Wheel symlink entry: ${LINK_DIST}/mooncake_transfer_engine-latest.whl"
