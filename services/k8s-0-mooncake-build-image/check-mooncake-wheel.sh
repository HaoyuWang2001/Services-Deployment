#!/bin/bash

set -u

ROOT=/home/Mooncake/outputs

export LD_LIBRARY_PATH="${ROOT}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

# 检查入口文件
ELF_FILES=(
    "${ROOT}/bin/mooncake_client"
    "${ROOT}/bin/mooncake_master"
    "${ROOT}/bin/stress_cluster_bench"
    "${ROOT}/lib/libasio.so"
    "${ROOT}/lib/libetcd_wrapper.so"
)

declare -A VISITED
declare -A MISSING

QUEUE=("${ELF_FILES[@]}")

echo "============================================================"
echo "Mooncake ELF Recursive Dependency Check"
echo "============================================================"

echo "ROOT=${ROOT}"
echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH}"

while [ "${#QUEUE[@]}" -gt 0 ]; do

    CURRENT="${QUEUE[0]}"
    QUEUE=("${QUEUE[@]:1}")

    # 避免重复检查
    if [[ -n "${VISITED[$CURRENT]:-}" ]]; then
        continue
    fi

    VISITED["$CURRENT"]=1

    echo
    echo "------------------------------------------------------------"
    echo "Checking: ${CURRENT}"
    echo "------------------------------------------------------------"

    if [ ! -f "$CURRENT" ]; then
        echo "[ERROR] File not found: $CURRENT"
        MISSING["$CURRENT"]="FILE_NOT_FOUND"
        continue
    fi

    OUTPUT=$(ldd "$CURRENT" 2>&1)
    LDD_STATUS=$?

    echo "$OUTPUT"

    if [ "$LDD_STATUS" -ne 0 ]; then
        echo "[ERROR] ldd failed: $CURRENT"
        MISSING["$CURRENT"]="LDD_FAILED"
        continue
    fi

    # 检查是否有未找到的依赖
    while IFS= read -r line; do
        if [[ "$line" == *"not found"* ]]; then
            echo "[ERROR] Missing dependency: $line"
            MISSING["$line"]=1
        fi
    done <<< "$OUTPUT"

    # 提取已解析的动态库路径
    while IFS= read -r lib; do

        [ -z "$lib" ] && continue

        if [[ -z "${VISITED[$lib]:-}" ]]; then
            QUEUE+=("$lib")
        fi

    done < <(
        echo "$OUTPUT" | awk '
            /=>/ && $3 ~ /^\// {
                print $3
            }

            /^\// && $1 ~ /^\// {
                print $1
            }
        ' | sort -u
    )

done

echo
echo "============================================================"
echo "Final Result"
echo "============================================================"

echo "Total ELF files checked: ${#VISITED[@]}"

MISSING_COUNT=0

for item in "${!MISSING[@]}"; do
    MISSING_COUNT=$((MISSING_COUNT + 1))
done

if [ "$MISSING_COUNT" -eq 0 ]; then
    echo "[SUCCESS] All ELF dependencies resolved."
    exit 0
else
    echo "[FAILED] Missing dependencies detected:"
    for item in "${!MISSING[@]}"; do
        echo "  $item"
    done
    exit 1
fi
[root@2d99a05fd338 home]# cat check-mooncake-wheel.sh

#!/usr/bin/env bash
set -uo pipefail

PACKAGE="mooncake-transfer-engine"
EXPECTED_VERSION="0.3.12.post1"
SITE="/usr/local/lib64/python3.11/site-packages"
MOONCAKE_DIR="${SITE}/mooncake"
PRIVATE_LIB_DIR="${SITE}/mooncake_transfer_engine.libs"

FAILED=0
CHECKED_ELF=0

pass() {
    echo "[PASS] $*"
}

fail() {
    echo "[FAIL] $*"
    FAILED=$((FAILED + 1))
}

section() {
    echo
    echo "============================================================"
    echo "$*"
    echo "============================================================"
}

section "1. System Environment"

python3 --version || fail "Python unavailable"
uname -m
ldd --version | head -n 1

if [ "$(uname -m)" = "aarch64" ]; then
    pass "Architecture: aarch64"
else
    fail "Unexpected architecture"
fi

section "2. Wheel Installation"

VERSION=$(python3 -m pip show "$PACKAGE" 2>/dev/null |
    awk '/^Version:/ {print $2}')

if [ "$VERSION" = "$EXPECTED_VERSION" ]; then
    pass "$PACKAGE $VERSION installed"
else
    fail "Expected version $EXPECTED_VERSION, actual: ${VERSION:-NOT INSTALLED}"
fi

section "3. Python Dependencies"

if python3 -m pip check; then
    pass "Python dependencies are consistent"
else
    fail "pip check failed"
fi

section "4. Python Module Import"

python3 - <<'PY'
import importlib
import sys
import traceback

modules = [
    "mooncake",
    "mooncake.engine",
    "mooncake.store",
]

failed = False

for name in modules:
    print(f"\n----- {name} -----")
    try:
        module = importlib.import_module(name)
        print("[PASS] Import successful")
        print("Path:", module.__file__)
    except Exception:
        failed = True
        print("[FAIL] Import failed")
        traceback.print_exc()

sys.exit(1 if failed else 0)
PY

if [ $? -eq 0 ]; then
    pass "All Mooncake modules imported"
else
    fail "Python module import failed"
fi

section "5. Required System RPM Packages"

for pkg in libcurl numactl-libs liburing; do
    if rpm -q "$pkg" >/dev/null 2>&1; then
        pass "$pkg: $(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' "$pkg")"
    else
        fail "$pkg is not installed"
    fi
done

section "6. Shared Library Cache"

for lib in libcurl.so.4 libnuma.so.1 liburing.so.2; do
    if ldconfig -p | grep -Fq "$lib"; then
        pass "$lib found"
    else
        fail "$lib not found in ldconfig cache"
    fi
done

section "7. ELF Dependency Inspection"

if [ ! -d "$MOONCAKE_DIR" ]; then
    fail "Mooncake package directory not found: $MOONCAKE_DIR"
else
    declare -A VISITED=()
    declare -A MISSING=()

    while IFS= read -r -d '' file; do
        if ! file "$file" 2>/dev/null | grep -q ELF; then
            continue
        fi

        real_file=$(readlink -f "$file")

        if [ -n "${VISITED[$real_file]+x}" ]; then
            continue
        fi

        VISITED["$real_file"]=1
        CHECKED_ELF=$((CHECKED_ELF + 1))

        output=$(ldd "$real_file" 2>&1)
        status=$?

        if [ "$status" -ne 0 ]; then
            echo "[FAIL] ldd error: $real_file"
            echo "$output"
            MISSING["$real_file"]="ldd execution failed"
            continue
        fi

        while IFS= read -r line; do
            if [[ "$line" == *"not found"* ]]; then
                echo "[FAIL] $real_file"
                echo "       $line"
                MISSING["$real_file"]+="${line}; "
            fi
        done <<< "$output"

    done < <(find "$MOONCAKE_DIR" "$PRIVATE_LIB_DIR" \
        -type f -print0 2>/dev/null)

    if [ "$CHECKED_ELF" -eq 0 ]; then
        fail "No ELF files found"
    else
        pass "Inspected $CHECKED_ELF ELF files"
    fi

    if [ "${#MISSING[@]}" -eq 0 ]; then
        pass "All ELF dependencies resolved"
    else
        fail "Missing ELF dependencies detected"
    fi
fi

section "8. Final Result"

echo "ELF files checked: $CHECKED_ELF"
echo "Failed checks: $FAILED"

if [ "$FAILED" -eq 0 ]; then
    echo
    echo "[SUCCESS] Mooncake Wheel runtime dependency check passed."
    exit 0
else
    echo
    echo "[FAILED] Mooncake Wheel runtime dependency check failed."
    exit 1
fi
