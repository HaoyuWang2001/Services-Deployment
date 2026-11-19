#!/usr/bin/env bash
set -euo pipefail

# ===================== 配置项 =====================

# 【需配置】是否清理构建目录
CLEAN_BUILD=false

# 【需配置】网络配置
export PROXY_IP=127.0.0.1
export PROXY_PORT=3128
export http_proxy="http://${PROXY_IP}:${PROXY_PORT}"
export https_proxy=${http_proxy}
export no_proxy=192.168.0.0/16,141.0.0.0/8,10.0.0.0/8,172.16.0.0/12,127.0.0.1,localhost,local,.local

# 【需配置】工作目录和构建目录
SRC_ROOT="/home/w00921547/Mooncake"
BUILD_DIR="${SRC_ROOT}/build"

# 【需配置】GO，要求版本1.25.10
export PATH="/usr/local/go/bin:${PATH}"

# 【需配置】python虚拟环境
VENV="/home/w00921547/venvs/mc-w00921547"
VENV_PIP="$( [[ -n "${VENV:-}" ]] && printf '%s' "${VENV}/bin/pip" || printf 'pip' )"

# 【需配置】节点和目标
NODES=("node1" "node2" "node3")
BIN_TARGETS=(
    "mooncake_master"
    "mooncake_client"
    "stress_cluster_bench"
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
# ==================================================

mkdir -p run
exec 9>run/build.lock
flock -n 9 || { echo "BUILD_SKIPPED: 已有编译在运行"; exit 1; }

if [[ "${CLEAN_BUILD}" == "true" && -d "${BUILD_DIR}" ]]; then
    echo "[INFO] Clean build directory: ${BUILD_DIR}"
    rm -rf "${BUILD_DIR}"
fi

echo ">> Configure CMake (modern -B build style)"
SPDIAG_DIR="/usr/lib64/cmake/SpDiag"
SPDIAG_CLI="/usr/bin/spdiag"
URMA_ROOT="/home/w00921547/gdr/umdk/src/urma/lib/urma/core/include"
UMDK_ROOT="/home/w00921547/gdr/umdk/src/urma/lib/urma/bond/include"
URMA_LIBRARY="/home/w00921547/gdr/umdk/build/urma/lib/urma/core/liburma.so"

# 生成器从 Make 换成 Ninja：旧 build 目录的 CMakeCache 会让 CMake 报生成器不匹配，
# 首次切换时自动清理一次（只删构建产物，不动源码与 outputs/）。
if [[ -f "${BUILD_DIR}/CMakeCache.txt" ]] && ! grep -q '^CMAKE_GENERATOR:INTERNAL=Ninja$' "${BUILD_DIR}/CMakeCache.txt"; then
    echo "[INFO] Generator changed to Ninja, cleaning build dir: ${BUILD_DIR}"
    rm -rf "${BUILD_DIR}"
fi

# -pipe 省临时文件 I/O（384 核并发时收益明显）；若编译机与运行节点 CPU 同代，
# 可再加 -mcpu=native 换运行性能（不同代会 SIGILL，先 lscpu 比对再用）。
export CXXFLAGS="${CXXFLAGS:-} -w -pipe"
export CFLAGS="${CFLAGS:-} -w -pipe"

cmake -B "${BUILD_DIR}" -S . -G Ninja \
  -DUSE_UB=ON \
  -DUSE_CUDA=ON \
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
  -DCMAKE_C_COMPILER_LAUNCHER=ccache \
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -DMOONCAKE_ENABLE_SPDIAG=ON \
  -DSpDiag_DIR="${SPDIAG_DIR}" \
  -DMOONCAKE_SPDIAG_SYSTEM_CLI="${SPDIAG_CLI}" \
  -DURMA_ROOT="${URMA_ROOT}" \
  -DUMDK_ROOT="${UMDK_ROOT}" \
  -DURMA_LIBRARY="${URMA_LIBRARY}" \
  -DYLT_ENABLE_URMA=ON

# ===== 编译参数说明（只影响“怎么编”，不改功能与硬件选项）=====
# -G Ninja                    多核下比 make 调度开销小，编译/链接分开排队；
#                             首次从 Make 切过来时，上面的判断会自动清一次 build 目录。
# -DCMAKE_BUILD_TYPE=Release  优化级别 -O3（RelWithDebInfo 是 -O2 -g）；实测 -O3 比 -O2 快 3-5%。
# -DENABLE_DEBUG_SYMBOLS=OFF  工程在 common.cmake 里向全局 CXXFLAGS 追加 -g，必须关掉它才能彻底
#                             去符号；-g 对运行零收益，只让单个重 TU 编译慢约 1.5 倍、峰值内存
#                             多 20-40%、.o 大二十多倍。需要 gdb 时另建一份带 -g 的构建。
# -pipe                       编译走管道、少落临时文件，384 核并发时省 I/O（见上方 CXXFLAGS）。
# -DCMAKE_C_COMPILER_LAUNCHER=ccache
# -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
#                             增量编译走 ccache，无改动时近乎瞬时；改 flags 会全量失效一次。
# -DBUILD_UNIT_TESTS=OFF      不编单测（约 20 个 TU）；EXAMPLES/BENCHMARK 保留是因为产物里要
#                             带 transfer_engine_bench 与 stress_cluster_bench。
# -DBUILD_SHARED_LIBS=OFF     多数库静态编入，产物按 outputs/{bin,lib} 分发。
# -DCMAKE_SKIP_RPATH=ON       产物不写 RPATH，运行期依赖由节点 LD_LIBRARY_PATH 提供。
# -DCMAKE_DISABLE_FIND_PACKAGE_AWSSDK=ON
#                             不引入 S3 依赖，少编若干 TU 和链接项。
# 可选（默认没开）：-mcpu=native 需编译机与运行节点 CPU 同代，否则节点 SIGILL；
#                   -fuse-ld=lld 可再压链接时间；-flto 提运行性能但显著拉长编译关键路径。

echo ">> Build targets"
export GOPROXY="http://mirrors.aliyun.com/goproxy,direct"
export GOINSECURE="go.etcd.io/etcd"
export GOSUMDB="sum.golang.org"
cmake --build "${BUILD_DIR}" -j"$(nproc)" --target stress_cluster_bench mooncake_master mooncake_client engine store transfer_engine_bench

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
  "${BUILD_DIR}/mooncake-store/benchmarks/stress_cluster_bench" \
  "${BUILD_DIR}/mooncake-store/src/mooncake_master" \
  "${BUILD_DIR}/mooncake-store/src/mooncake_client" \
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

echo "==== Build & Collect & Install Finished ===="
echo "Binaries entry: ${OUTPUT_BIN_DIR}"
echo "Wheel entry: ${OUTPUT_DIST_DIR}"
echo "Binaries symlink entry: ${LINK_BIN}"
echo "Wheel symlink entry: ${LINK_DIST}"

# 如果没有其他节点，结束运行
if [[ ${#NODES[@]} -eq 0 ]]; then
    echo "INFO: NODES is empty, nothing to do. Exiting normally."
    exit 0
fi

# ===================== 远程节点：scp bin/lib/dist =====================
echo "[INFO] SCP bin & dist to nodes: ${NODES[*]}"
for node in "${NODES[@]}"; do
    echo "[INFO] Transfer to ${node}"

    # 确保远端输出目录存在
    ssh "${node}" "mkdir -p '${OUTPUT_DIR}/bin' '${OUTPUT_DIR}/lib' '${OUTPUT_DIR}/dist'" || exit 1

    # 逐个复制 bin 文件，远端文件名添加 .new 后缀
    for bin_name in "${BIN_TARGETS[@]}"; do
        src="${LINK_BIN}/${bin_name}"
        remote_path="${OUTPUT_DIR}/bin/${bin_name}.new"

        if [[ ! -f "${src}" ]]; then
            echo "[ERROR] Source file not found: ${src}" >&2
            exit 1
        fi

        echo "[INFO] ${src} -> ${node}:${remote_path}"
        scp "${src}" "${node}:${remote_path}" || exit 1
    done

    # scp lib 子目录
    echo "[INFO] Copy lib: ${LINK_LIB} -> ${node}:${OUTPUT_DIR}/"
    scp -r "${LINK_LIB}" "${node}:${OUTPUT_DIR}/" || exit

    # scp dist 子目录
    echo "[INFO] Copy dist: ${LINK_DIST} -> ${node}:${OUTPUT_DIR}/"
    scp -r "${LINK_DIST}" "${node}:${OUTPUT_DIR}/" || exit 1
done

echo "[INFO] All bin & dist files transferred successfully."

# ===================== 远程节点：重装wheel =====================
echo "[INFO] Reinstall wheel package on all nodes"
for node in "${NODES[@]}"; do
    echo "[INFO] Reinstall on ${node}"
    ssh "${node}" "
set -euo pipefail
echo \">> Reinstall mooncake-transfer-engine into venv\"
${VENV_PIP} uninstall -y mooncake-transfer-engine
${VENV_PIP} install ${OUTPUT_DIR}/dist/mooncake_transfer_engine-*.whl
"
done

echo "==== Build & Collect & Install Finished ===="
echo "Binaries entry: ${OUTPUT_BIN_DIR}"
echo "Wheel entry: ${OUTPUT_DIST_DIR}"
echo "Binaries symlink entry: ${LINK_BIN}"
echo "Wheel symlink entry: ${LINK_DIST}"
