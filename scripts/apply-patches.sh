#!/usr/bin/env bash
# Apply the dxgkrnl DRM integration to a WSL2 kernel tree.
# Usage: ./scripts/apply-patches.sh /path/to/WSL2-Linux-Kernel

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PATCHES_DIR="$SCRIPT_DIR/../patches"
SRC_FILE="$SCRIPT_DIR/../src/dxgdrm.c"
DXG_REL="drivers/hv/dxgkrnl"

usage() {
    echo "Usage: $0 /path/to/WSL2-Linux-Kernel" >&2
    exit 2
}
die() {
    echo "[ERROR] $*" >&2
    exit 1
}

[[ $# -eq 1 ]] || usage
KERNEL_DIR="$(cd -- "$1" && pwd)"
[[ -f "$KERNEL_DIR/$DXG_REL/dxgkrnl.h" ]] || die "No dxgkrnl source found in $KERNEL_DIR"
[[ -s "$SRC_FILE" ]] || die "Missing or empty source file: $SRC_FILE"
compgen -G "$PATCHES_DIR/*.patch" >/dev/null || die "No patch files found in $PATCHES_DIR"

command -v patch >/dev/null 2>&1 || die "The 'patch' command is required"

cd "$KERNEL_DIR"
echo "Kernel tree: $KERNEL_DIR"

for patch_file in "$PATCHES_DIR"/*.patch; do
    name="$(basename "$patch_file")"
    if patch -p1 --dry-run --forward < "$patch_file" >/dev/null 2>&1; then
        echo "[APPLY] $name"
        patch -p1 --forward < "$patch_file"
    elif patch -p1 --dry-run --reverse < "$patch_file" >/dev/null 2>&1; then
        echo "[SKIP]  $name (already applied)"
    else
        die "$name cannot be applied cleanly and is not already applied. Stopping rather than treating a conflict as success."
    fi
done

install -m 0644 "$SRC_FILE" "$KERNEL_DIR/$DXG_REL/dxgdrm.c"
echo "[OK]    Installed dxgdrm.c"

echo "Checking expected integration points..."
grep -Eq 'struct drm_device[[:space:]]*\*drm_dev' "$KERNEL_DIR/$DXG_REL/dxgkrnl.h" || die "drm_dev field missing from dxgkrnl.h"
grep -Eq 'dxg_drm_init_adapter\(' "$KERNEL_DIR/$DXG_REL/dxgadapter.c" || die "DRM init hook missing from dxgadapter.c"
grep -Eq 'dxg_drm_destroy_adapter\(' "$KERNEL_DIR/$DXG_REL/dxgadapter.c" || die "DRM teardown hook missing from dxgadapter.c"
grep -Eq '^struct dxgprocess \*dxgglobal_get_current_process' "$KERNEL_DIR/$DXG_REL/dxgmodule.c" || die "current-process helper is not externally visible in dxgmodule.c"
grep -Eq 'dxgdrm\.o' "$KERNEL_DIR/$DXG_REL/Makefile" || die "dxgdrm.o missing from dxgkrnl Makefile"

# Ensure the copied source has the corrected ioctl routing expected by this fork.
grep -Fq 'dxgk_unlocked_ioctl(&dxg_file, cmd, arg)' "$KERNEL_DIR/$DXG_REL/dxgdrm.c" || die "Corrected DXG ioctl routing not found in dxgdrm.c"
grep -Fq 'return drm_ioctl(filp, cmd, arg);' "$KERNEL_DIR/$DXG_REL/dxgdrm.c" || die "DRM ioctl fallback not found in dxgdrm.c"

echo "[OK] DRM integration patches and source file are present."
