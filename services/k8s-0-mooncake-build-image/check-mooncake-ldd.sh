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
