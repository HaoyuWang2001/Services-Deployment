#!/usr/bin/env bash
set -uo pipefail

PACKAGE="mooncake-transfer-engine"
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

case "$(uname -m)" in
    x86_64|aarch64)
        pass "Architecture: $(uname -m)"
        ;;
    *)
        fail "Unexpected architecture: $(uname -m)"
        ;;
esac

section "2. Wheel Installation"

VERSION=$(python3 -m pip show "$PACKAGE" 2>/dev/null |
    awk '/^Version:/ {print $2}')

if [ -n "$VERSION" ]; then
    pass "$PACKAGE $VERSION installed"
else
    fail "$PACKAGE is NOT installed"
fi

echo "[SKIP] wheel 版本号检查暂不执行（实际版本: ${VERSION:-unknown}）"

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
