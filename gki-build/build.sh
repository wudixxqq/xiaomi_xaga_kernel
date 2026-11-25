#!/usr/bin/env bash
# Reproducible xaga (MT6895 / Dimensity 8100) HyperOS2 GKI kernel builder.
#
# Base : ESK v4.0.1 xaga source (android12-5.10 GKI, 5.10.274)
# Root : BakaSU (default, latest CI main) / SukiSU-Nova / FinaSU
# Hide : official susfs4ksu gki-android12-5.10 kernel patches
# Out  : AnyKernel3 zip with zstd Image + vendor_boot/vendor_dlkm modules
#
# The ABI hard gates (ThinLTO + CFI + MODVERSIONS, depmod metadata, kernel
# banner verification) come from the SUSFS adaptation experience in this repo.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=config.env
source "$SCRIPT_DIR/config.env"

WORK="${WORK:-$SCRIPT_DIR/work}"
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/out}"
KERNEL="$WORK/kernel"
SUSFS_DIR="$WORK/susfs4ksu"
ESK_BUILDER="$WORK/esk_builder"
CLANG="$WORK/clang"
KERNEL_OUT="$OUT_DIR/build"
MODULES_INSTALL="$OUT_DIR/modules-install"
MOD_FLAT="$OUT_DIR/modules-flat"
MOD_STAGE="$OUT_DIR/modules-stage"
AK3="$WORK/ak3"
CCACHE_DIR="${CCACHE_DIR:-$SCRIPT_DIR/.ccache}"

ROOT_VARIANT="${ROOT_VARIANT:-bakasu}"
ROOT_REF="${ROOT_REF:-}"
ENABLE_SUSFS="${ENABLE_SUSFS:-1}"
ENABLE_NOMOUNT="${ENABLE_NOMOUNT:-1}"
ENABLE_MODULES="${ENABLE_MODULES:-1}"
USE_CCACHE="${USE_CCACHE:-1}"
STAGE="init"
EXTRA_MAKE=()

log()  { printf '\033[1;34m[%s] %s\033[0m\n' "$ROOT_VARIANT" "$*"; }
ok()   { printf '\033[1;32m[+] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

trap 'printf "\033[1;31m[x] FAILED at stage=%s line=%s cmd=%s\033[0m\n" "$STAGE" "$LINENO" "$BASH_COMMAND" >&2' ERR

fresh_dir() { rm -rf "$1"; mkdir -p "$1"; }

clone_pinned() {
    local url="$1" ref="$2" dest="$3"
    fresh_dir "$dest"
    git init -q "$dest"
    git -C "$dest" remote add origin "$url"
    git -C "$dest" fetch -q --depth 1 origin "$ref"
    git -C "$dest" checkout -q FETCH_HEAD
    git -C "$dest" rev-parse HEAD
}

resolve_ref() {
    local url="$1" ref="$2" sha
    if [[ -z "$ref" ]]; then
        printf '%s' ''
        return 0
    fi
    sha="$(git ls-remote "$url" "$ref" 2>/dev/null | awk 'NR==1 {print $1}' || true)"
    if [[ -n "$sha" ]]; then printf '%s' "$sha"; else printf '%s' "$ref"; fi
}

cfg() { "$KERNEL/scripts/config" --file "$KERNEL_OUT/.config" "$@"; }

ensure_susfs_kconfig() {
    local kcfg
    for kcfg in \
        "$KERNEL/KernelSU/kernel/Kconfig" \
        "$KERNEL/KernelSU/Kconfig" \
        "$KERNEL/FinaSU/kernel/Kconfig" \
        "$KERNEL/drivers/kernelsu/Kconfig"; do
        if [[ -f "$kcfg" ]]; then
            if ! grep -q '^config KSU_SUSFS$' "$kcfg"; then
                cat >> "$kcfg" <<'SUSFS_KCFG'

config KSU_SUSFS
	bool "SUSFS kernel-side support (susfs4ksu patch)"
	depends on KSU
	default y

config KSU_SUSFS_SUS_PATH
	bool "SUSFS: hide paths"
	depends on KSU_SUSFS
	default y
config KSU_SUSFS_SUS_MOUNT
	bool "SUSFS: hide mounts"
	depends on KSU_SUSFS
	default y
config KSU_SUSFS_SUS_KSTAT
	bool "SUSFS: spoof stat"
	depends on KSU_SUSFS
	default y
config KSU_SUSFS_SPOOF_UNAME
	bool "SUSFS: spoof uname"
	depends on KSU_SUSFS
	default y
config KSU_SUSFS_ENABLE_LOG
	bool "SUSFS: logging"
	depends on KSU_SUSFS
	default y
config KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
	bool "SUSFS: hide symbols"
	depends on KSU_SUSFS
	default y
config KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
	bool "SUSFS: spoof cmdline/bootconfig"
	depends on KSU_SUSFS
	default y
config KSU_SUSFS_OPEN_REDIRECT
	bool "SUSFS: open redirect"
	depends on KSU_SUSFS
	default y
config KSU_SUSFS_SUS_MAP
	bool "SUSFS: hide maps"
	depends on KSU_SUSFS
	default y
config KSU_SUSFS_PRIORITY_UID_FILTER
	bool "SUSFS: priority uid filter"
	depends on KSU_SUSFS
	default n
SUSFS_KCFG
                log "Injected SUSFS Kconfig symbols into $kcfg"
            fi
            return 0
        fi
    done
    die "No KernelSU Kconfig found for SUSFS symbols"
}

patch_fuzz() {
    local dir="$1" patch_file="$2"
    patch -p1 --forward --fuzz=3 --no-backup-if-mismatch -d "$dir" < "$patch_file"
}

# ---------------------------------------------------------------------------
# 0. Prepare workspace and resolve pinned revisions
# ---------------------------------------------------------------------------
STAGE="prepare"
mkdir -p "$WORK" "$OUT_DIR"
case "$ROOT_VARIANT" in
    bakasu)
        ROOT_REPO="https://github.com/Baka-SU/BakaSU"
        SETUP_URL="https://raw.githubusercontent.com/Baka-SU/BakaSU/main/kernel/setup.sh"
        ROOT_REF_DEFAULT="main"
        DRIVER_DIR="KernelSU"
        ;;
    sukisu)
        ROOT_REPO="https://github.com/SukiSU-Nova/SukiSU-Nova"
        SETUP_URL="https://raw.githubusercontent.com/SukiSU-Nova/SukiSU-Nova/main/kernel/setup.sh"
        ROOT_REF_DEFAULT="c60f21b9e00e"
        DRIVER_DIR="KernelSU"
        ;;
    finasu)
        ROOT_REPO="https://github.com/LyraVoid/FinaSU"
        SETUP_URL="https://raw.githubusercontent.com/LyraVoid/FinaSU/master/kernel/setup.sh"
        ROOT_REF_DEFAULT="06d71e8a08bb"
        DRIVER_DIR="FinaSU"
        ;;
    *) die "Unknown ROOT_VARIANT: $ROOT_VARIANT (bakasu|sukisu|finasu)" ;;
esac

ROOT_REF="${ROOT_REF:-$ROOT_REF_DEFAULT}"
ROOT_COMMIT="$(resolve_ref "$ROOT_REPO.git" "$ROOT_REF")"
[[ -n "$ROOT_COMMIT" ]] || die "Cannot resolve $ROOT_VARIANT ref: $ROOT_REF"

log "variant=$ROOT_VARIANT root_ref=$ROOT_REF root_commit=${ROOT_COMMIT:0:12}"
log "kernel=$KERNEL_REF susfs=$SUSFS_REF ak3=$AK3_REF"

# ---------------------------------------------------------------------------
# 1. Fetch kernel source, helper builder and AnyKernel3 template
# ---------------------------------------------------------------------------
STAGE="fetch-sources"
KERNEL_COMMIT="$(clone_pinned "$KERNEL_REPO" "$KERNEL_REF" "$KERNEL")"
ESK_BUILDER_COMMIT="$(clone_pinned "$ESK_BUILDER_REPO" "$ESK_BUILDER_REF" "$ESK_BUILDER")"
AK3_COMMIT="$(clone_pinned "$AK3_REPO" "$AK3_REF" "$AK3")"
SUSFS_COMMIT="$(clone_pinned "$SUSFS_REPO" "$SUSFS_REF" "$SUSFS_DIR")"
ok "kernel=${KERNEL_COMMIT:0:12} builder=${ESK_BUILDER_COMMIT:0:12} ak3=${AK3_COMMIT:0:12} susfs=${SUSFS_COMMIT:0:12}"

KERNEL_VERSION="$(make -s -C "$KERNEL" kernelversion)"
[[ "$KERNEL_VERSION" == 5.10.* ]] || die "Unexpected kernel version: $KERNEL_VERSION"

# ---------------------------------------------------------------------------
# 2. Toolchain (pinned AOSP clang r614150, same as ESK v4.0.1)
# ---------------------------------------------------------------------------
STAGE="toolchain"
if [[ ! -x "$CLANG/bin/clang" ]]; then
    mkdir -p "$CLANG"
    CLANG_URL="$(python3 - "$CLANG_RELEASE_API" <<'PY'
import json, sys, urllib.request
with urllib.request.urlopen(sys.argv[1], timeout=60) as r:
    data = json.load(r)
for a in data.get("assets", []):
    if a["name"].startswith("clang-r") and a["name"].endswith(".tar.gz"):
        print(a["browser_download_url"])
        break
PY
)"
    [[ -n "$CLANG_URL" ]] || die "No clang-r*.tar.gz asset found in $CLANG_RELEASE_API"
    log "Downloading clang: $CLANG_URL"
    curl -fL --retry 5 --retry-delay 3 -o "$WORK/clang.tar.gz" "$CLANG_URL"
    tar -xzf "$WORK/clang.tar.gz" -C "$CLANG"
    rm -f "$WORK/clang.tar.gz"
fi
export PATH="$CLANG/bin:$PATH"
"$CLANG/bin/clang" --version | head -2

if [[ "$USE_CCACHE" == "1" ]]; then
    mkdir -p "$CCACHE_DIR"
    export CCACHE_DIR CCACHE_BASEDIR="$REPO_ROOT" CCACHE_COMPILERCHECK=content CCACHE_MAXSIZE=2G
    CC_VAL="ccache $CLANG/bin/clang"
else
    CC_VAL="$CLANG/bin/clang"
fi

MAKEARGS=(O="$KERNEL_OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1 LD=ld.lld CROSS_COMPILE=aarch64-linux-gnu-)

# ---------------------------------------------------------------------------
# 3. Inject root driver
# ---------------------------------------------------------------------------
STAGE="root-driver"
log "Injecting $ROOT_VARIANT driver @ ${ROOT_COMMIT:0:12}"
curl -fsSL --retry 3 "$SETUP_URL" -o "$WORK/root_setup.sh"
(
    cd "$KERNEL"
    bash "$WORK/root_setup.sh" "$ROOT_COMMIT"
)
[[ -d "$KERNEL/$DRIVER_DIR" ]] || die "Driver directory $DRIVER_DIR missing after setup.sh"
git -C "$KERNEL/$DRIVER_DIR" checkout -q "$ROOT_COMMIT" 2>/dev/null || true
DRIVER_COMMIT="$(git -C "$KERNEL/$DRIVER_DIR" rev-parse HEAD)"
[[ "$DRIVER_COMMIT" == "$ROOT_COMMIT" ]] || die "Driver checkout mismatch: $DRIVER_COMMIT != $ROOT_COMMIT"
log "driver checkout = ${DRIVER_COMMIT:0:12}"

case "$ROOT_VARIANT" in
    finasu)
        grep -q '^config KSU_SUSFS$' "$KERNEL/$DRIVER_DIR/kernel/Kconfig" || die "FinaSU Kconfig missing KSU_SUSFS"
        test -f "$KERNEL/$DRIVER_DIR/kernel/extension/susfs.c" || die "FinaSU extension/susfs.c missing"
        ;;
    sukisu)
        NOVA_PIN="c60f21b9e00e"
        [[ "$ROOT_REF" == "$NOVA_PIN"* || "$ROOT_COMMIT" == "$NOVA_PIN"* ]] \
            || die "SukiSU-Nova SUSFS glue is pinned to $NOVA_PIN; re-port required for $ROOT_COMMIT"
        NOVA_PATCH="$REPO_ROOT/patches/novasus_10_enable_susfs_for_ksu.patch"
        [[ -f "$NOVA_PATCH" ]] || die "Missing $NOVA_PATCH"
        patch_fuzz "$KERNEL/$DRIVER_DIR" "$NOVA_PATCH" || die "SukiSU KSU-side SUSFS patch failed"
        grep -q '^config KSU_SUSFS$' "$KERNEL/$DRIVER_DIR/kernel/Kconfig" || die "SukiSU KSU-side patch missing KSU_SUSFS"
        ;;
    bakasu)
        test -f "$KERNEL/drivers/kernelsu/Kconfig" || die "BakaSU driver not linked into drivers/"
        ;;
esac

# ---------------------------------------------------------------------------
# 4. Apply SUSFS kernel-side patches
# ---------------------------------------------------------------------------
STAGE="susfs"
if [[ "$ENABLE_SUSFS" == "1" ]]; then
    SUSFS_PATCH="$(find "$SUSFS_DIR/kernel_patches" -maxdepth 1 -name '50_add_susfs_in_gki-android*-*.patch' | head -n1)"
    [[ -n "$SUSFS_PATCH" ]] || die "SUSFS main patch not found"
    log "Applying SUSFS patch: $(basename "$SUSFS_PATCH")"
    patch_fuzz "$KERNEL" "$SUSFS_PATCH" || die "SUSFS main patch failed to apply"
    cp -f "$SUSFS_DIR"/kernel_patches/fs/* "$KERNEL/fs/"
    cp -f "$SUSFS_DIR"/kernel_patches/include/linux/* "$KERNEL/include/linux/"
    [[ -f "$KERNEL/fs/susfs.c" && -f "$KERNEL/include/linux/susfs_def.h" ]] || die "SUSFS files missing after patch"
    HOOKED="$(grep -rl 'susfs' "$KERNEL/fs/" --include='*.c' | wc -l)"
    [[ "$HOOKED" -ge 3 ]] || die "SUSFS hooks not injected into fs/ ($HOOKED files)"
    echo "$HOOKED" > "$OUT_DIR/susfs-hooked-files.txt"
    log "SUSFS hooks in $HOOKED fs source files"

    if grep -rq 'VMA_PAD_START' "$KERNEL/fs" "$KERNEL/include" && ! grep -rq 'define VMA_PAD_START' "$KERNEL/include"; then
        cat >> "$KERNEL/include/linux/mm.h" <<'COMPAT'
/* compat: susfs4ksu gki-android12-5.10 uses VMA_PAD_START on newer trees. */
#ifndef VMA_PAD_START
#define VMA_PAD_START(vma) ((vma)->vm_end)
#endif
COMPAT
    fi
    ensure_susfs_kconfig

    if [[ "$ROOT_VARIANT" == "finasu" ]] && ! grep -q 'ksu_handle_sys_reboot' "$KERNEL/kernel/reboot.c"; then
        log "Injecting FinaSU reboot dispatch hook"
        python3 - "$KERNEL/kernel/reboot.c" <<'PYREBOOT'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8", newline="").read()
decl = '''/* FinaSU: susfs command + install-fd dispatch via SYS_reboot */
#ifdef CONFIG_KSU
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);
#endif

'''
a1 = 'SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,\n\t\tvoid __user *, arg)\n{'
assert a1 in s, "reboot.c SYSCALL_DEFINE4 anchor missing"
s = s.replace(a1, decl + a1, 1)
a2 = '''\tstruct pid_namespace *pid_ns = task_active_pid_ns(current);
\tchar buffer[256];
\tint ret = 0;
'''
hook = '''
#ifdef CONFIG_KSU
\t{
\t\tvoid __user *ksu_arg = arg;
\t\tif (ksu_handle_sys_reboot(magic1, magic2, cmd, &ksu_arg) == 0)
\t\t\treturn 0;
\t}
#endif
'''
assert a2 in s, "reboot.c local-decls anchor missing"
s = s.replace(a2, a2 + hook, 1)
io.open(p, "w", encoding="utf-8", newline="").write(s)
print("reboot hook injected")
PYREBOOT
        grep -q 'ksu_handle_sys_reboot(magic1, magic2, cmd' "$KERNEL/kernel/reboot.c" || die "reboot hook injection failed"
    fi
else
    log "SUSFS disabled by ENABLE_SUSFS=0"
fi

if [[ "$ENABLE_NOMOUNT" == "1" ]]; then
    STAGE="nomount"
    curl -fsSL --retry 3 "$NOMOUNT_SETUP_URL" -o "$WORK/nomount_setup.sh" || warn "NoMount setup download failed; skipping"
    if [[ -f "$WORK/nomount_setup.sh" ]]; then
        ( cd "$KERNEL" && bash "$WORK/nomount_setup.sh" ) || warn "NoMount setup failed; continuing without it"
    fi
fi

# ---------------------------------------------------------------------------
# 5. Kernel configuration with ABI hard gates
# ---------------------------------------------------------------------------
STAGE="config"
config_dir="$KERNEL/arch/arm64/configs"
overlays=()
for overlay in $DEFCONFIG_OVERLAYS; do
    [[ -f "$config_dir/$overlay" ]] || die "Missing defconfig overlay: $overlay"
    overlays+=("$config_dir/$overlay")
done
KCONFIG_CONFIG="$config_dir/$KERNEL_DEFCONFIG" "$KERNEL/scripts/kconfig/merge_config.sh" -m -r \
    "$config_dir/$KERNEL_DEFCONFIG" "${overlays[@]}" >/dev/null
mkdir -p "$KERNEL_OUT"
make -C "$KERNEL" "${MAKEARGS[@]}" CC="$CC_VAL" HOSTCC="$CC_VAL" "$KERNEL_DEFCONFIG" >/dev/null

cfg -e KSU -e MODULES -e MODVERSIONS -e KPROBES -e KALLSYMS -e KALLSYMS_ALL
cfg -d LTO_CLANG_FULL -d LTO_NONE -e LTO_CLANG_THIN -e CFI_CLANG -d LOCALVERSION_AUTO
if [[ "$ENABLE_SUSFS" == "1" ]]; then
    cfg -e KSU_SUSFS -e KSU_SUSFS_SUS_PATH -e KSU_SUSFS_SUS_MOUNT -e KSU_SUSFS_SUS_KSTAT \
        -e KSU_SUSFS_SPOOF_UNAME -e KSU_SUSFS_ENABLE_LOG -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
        -e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG -e KSU_SUSFS_OPEN_REDIRECT -e KSU_SUSFS_SUS_MAP
fi
if [[ "$ROOT_VARIANT" == "finasu" ]]; then
    cfg -e EXT4_FS -e HEADERS_INSTALL -e THREAD_INFO_IN_TASK
    cfg -e KSU_HOOK_TRACEPOINT -d KSU_HOOK_SUSFS_INLINE
    if [[ "$ENABLE_SUSFS" == "1" ]]; then cfg -e KSU_SUSFS_PRIORITY_UID_FILTER; fi
    EXTRA_MAKE+=(KSU_REQUIRE_PREINIT=1
                 KSU_EXPECTED_SIZE=0x2cc
                 KSU_EXPECTED_HASH=2d89b50aaf1db013c2b6738f973f48b62ea21a3a8d7216bfec3521065d448458)
fi
if [[ -n "$KERNEL_LOCALVERSION" ]]; then
    cfg --set-str LOCALVERSION "$KERNEL_LOCALVERSION"
fi
if [[ "$ENABLE_NOMOUNT" == "1" ]] && grep -q '^config NOMOUNT' "$KERNEL/drivers/Kconfig" "$KERNEL/drivers/nomount/Kconfig" 2>/dev/null; then
    cfg -e NOMOUNT
fi
make -C "$KERNEL" "${MAKEARGS[@]}" CC="$CC_VAL" HOSTCC="$CC_VAL" olddefconfig >/dev/null

grep -q '^CONFIG_LTO_CLANG_THIN=y' "$KERNEL_OUT/.config" || die "LTO_CLANG_THIN not set (CFI/vendor CRC risk)"
grep -q '^CONFIG_CFI_CLANG=y' "$KERNEL_OUT/.config" || die "CFI_CLANG not set (stock vendor modules will fail)"
grep -q '^CONFIG_MODVERSIONS=y' "$KERNEL_OUT/.config" || die "MODVERSIONS not set"
grep -q '^CONFIG_KSU=y' "$KERNEL_OUT/.config" || die "CONFIG_KSU dropped"
if [[ "$ENABLE_SUSFS" == "1" ]]; then
    grep -q '^CONFIG_KSU_SUSFS=y' "$KERNEL_OUT/.config" || die "CONFIG_KSU_SUSFS dropped by olddefconfig"
fi
KERNEL_RELEASE="$(make -s -C "$KERNEL" "${MAKEARGS[@]}" kernelrelease)"
log "kernelrelease=$KERNEL_RELEASE"

grep -E 'CONFIG_(KSU|KSU_SUSFS[A-Z_]*|LTO_CLANG_THIN|LTO_NONE|CFI_CLANG|MODVERSIONS|KPROBES|KALLSYMS_ALL)=|^# CONFIG_LOCALVERSION_AUTO' \
    "$KERNEL_OUT/.config" > "$OUT_DIR/kernel.config.txt" || true

# ---------------------------------------------------------------------------
# 6. Build kernel + modules
# ---------------------------------------------------------------------------
STAGE="build"
export KBUILD_BUILD_USER="$BUILD_USER" KBUILD_BUILD_HOST="$BUILD_HOST"
export KBUILD_BUILD_TIMESTAMP="$KBUILD_BUILD_TIMESTAMP"
export SOURCE_DATE_EPOCH="$(date -u -d "$KBUILD_BUILD_TIMESTAMP" +%s)"
make -C "$KERNEL" "${MAKEARGS[@]}" CC="$CC_VAL" HOSTCC="$CC_VAL" -j"$JOBS" \
    "${EXTRA_MAKE[@]}" Image modules 2>&1 | tee "$OUT_DIR/build.log"
[[ -f "$KERNEL_OUT/arch/arm64/boot/Image" ]] || die "Image not produced"
if [[ "$ENABLE_MODULES" == "1" ]]; then
    fresh_dir "$MODULES_INSTALL"
    make -C "$KERNEL" "${MAKEARGS[@]}" CC="$CC_VAL" HOSTCC="$CC_VAL" \
        INSTALL_MOD_PATH="$MODULES_INSTALL" modules_install >> "$OUT_DIR/build.log" 2>&1
fi
ok "Kernel built"

# ---------------------------------------------------------------------------
# 7. Verify compiled image
# ---------------------------------------------------------------------------
STAGE="verify"
# Do not use `strings | grep -m1` here: with pipefail, grep -m1 closes the pipe
# early and strings exits 141, turning a successful match into a false failure.
python3 - "$KERNEL_OUT/arch/arm64/boot/Image" "$KERNEL_RELEASE" "$OUT_DIR/kernel-banner.txt" <<'PYBANNER'
import re, sys
image, release, output = sys.argv[1:4]
data = open(image, "rb").read()
needle = b"Linux version " + release.encode()
i = data.find(needle)
if i < 0:
    sys.exit("kernel banner mismatch: %s not found" % release)
end = data.find(b"\x00", i)
line = data[i:end if end > i else i + 300].decode("utf-8", "replace")
open(output, "w", encoding="utf-8").write(line + "\n")
print(line)
PYBANNER
KSU_STR="$(strings "$KERNEL_OUT/arch/arm64/boot/Image" | grep -c -i 'KernelSU' || true)"
SUSFS_STR="$(strings "$KERNEL_OUT/arch/arm64/boot/Image" | grep -c -i 'susfs' || true)"
CFI_N="$(strings "$KERNEL_OUT/arch/arm64/boot/Image" | grep -c '__cfi_check' || true)"
printf 'KernelSU strings: %s\nSUSFS strings: %s\n__cfi_check: %s\n' "$KSU_STR" "$SUSFS_STR" "$CFI_N" \
    > "$OUT_DIR/symbol-counts.txt"
[[ "$KSU_STR" -ge 10 ]] || die "KernelSU strings missing from image"
if [[ "$ENABLE_SUSFS" == "1" ]]; then
    [[ "$SUSFS_STR" -ge 5 ]] || die "SUSFS strings missing from image ($SUSFS_STR)"
fi
[[ "$CFI_N" -ge 1 ]] || die "CFI disabled in final image (vendor module CRC mismatch)"
grep -q '__cfi_check' "$KERNEL_OUT/System.map" || die "System.map missing __cfi_check"

# ---------------------------------------------------------------------------
# 8. Stage vendor modules (ESK xaga module load lists)
# ---------------------------------------------------------------------------
STAGE="modules"
if [[ "$ENABLE_MODULES" == "1" ]]; then
    fresh_dir "$MOD_FLAT"; fresh_dir "$MOD_STAGE"
    src="$MODULES_INSTALL/lib/modules/$KERNEL_RELEASE"
    [[ -d "$src" ]] || die "Installed modules missing: $src"
    while IFS= read -r -d '' f; do
        name="$(basename "$f")"
        [[ ! -e "$MOD_FLAT/$name" ]] || die "Duplicate module basename: $name"
        cp -p "$f" "$MOD_FLAT/$name"
        "$CLANG/bin/llvm-strip" --strip-debug "$MOD_FLAT/$name" 2>/dev/null || true
    done < <(find "$src" -type f -name '*.ko' -print0)

    depmod_stage() {
        local payload="$1" root="$MOD_STAGE/depmod-root"
        fresh_dir "$root/lib/modules/0.0"
        cp -p "$MOD_FLAT"/*.ko "$root/lib/modules/0.0/" 2>/dev/null || true
        cp -p "$src"/modules.{order,builtin,builtin.modinfo} "$root/lib/modules/0.0/" 2>/dev/null || true
        depmod -b "$root" 0.0
        mkdir -p "$payload/lib/modules"
        cp -p "$root"/lib/modules/0.0/modules.{alias,dep,softdep} "$payload/lib/modules/" 2>/dev/null || true
        sed -i -e 's|\([^: ]*lib/modules/[^: ]*\)|/\1|g' "$payload/lib/modules/modules.dep" 2>/dev/null || true
        rm -rf "$root"
    }

    vb="$MOD_STAGE/vendor_boot/lib/modules"; mkdir -p "$vb"
    missing=0
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        if [[ -f "$MOD_FLAT/$name" ]]; then cp -p "$MOD_FLAT/$name" "$vb/"; else warn "vendor_boot module missing: $name"; missing=$((missing+1)); fi
    done < <(sort -u "$ESK_BUILDER/targets/xaga/modules.load.vendor_boot" "$ESK_BUILDER/targets/xaga/modules.load.recovery")
    cp -p "$ESK_BUILDER/targets/xaga/modules.load.vendor_boot" "$vb/modules.load"
    cp -p "$ESK_BUILDER/targets/xaga/modules.load.recovery" "$vb/modules.load.recovery"
    depmod_stage "$MOD_STAGE/vendor_boot"
    log "vendor_boot staged ($missing missing entries)"

    dl="$MOD_STAGE/vendor_dlkm/lib/modules"; mkdir -p "$dl"
    cp -p "$MOD_FLAT"/*.ko "$dl/" 2>/dev/null || true
    cp -p "$ESK_BUILDER/targets/xaga/modules.load" "$dl/modules.load"
    depmod_stage "$MOD_STAGE/vendor_dlkm"
    mkdir -p "$AK3/config"
    : > "$AK3/config/vendor_dlkm_fs_config"
    for f in "$dl"/*.ko; do
        printf 'vendor_dlkm/lib/modules/%s 0 0 0644\n' "$(basename "$f")" >> "$AK3/config/vendor_dlkm_fs_config"
    done
    tar -C "$MOD_STAGE" -cvpf - vendor_dlkm vendor_boot | xz -9e -T0 > "$AK3/module.tar.xz"
    ok "module.tar.xz created"
fi

# ---------------------------------------------------------------------------
# 9. Package AnyKernel3 and write metadata
# ---------------------------------------------------------------------------
STAGE="package"
VARIANT_TAG="${ROOT_VARIANT^^}"
if [[ "$ENABLE_SUSFS" == "1" ]]; then VARIANT_TAG="${VARIANT_TAG}-SUSFS"; fi
KERNEL_SHORT="${KERNEL_COMMIT:0:12}"
PACKAGE_NAME="${KERNEL_NAME}-${TARGET_NAME}-${KERNEL_VERSION}-${VARIANT_TAG}-${KERNEL_SHORT}"
cd "$AK3"
sed -i "s|^kernel\.string=.*|kernel.string=${KERNEL_RELEASE} [${VARIANT_TAG}]|" anykernel.sh
cp -p "$KERNEL_OUT/arch/arm64/boot/Image" .
"$CLANG/bin/zstd" --version >/dev/null 2>&1 || true
zstd -19 -T0 --no-progress -f -o Image.zst Image
sha256sum Image.zst > Image.zst.sha256
cp -p "$KERNEL_OUT/.config" kernel.config
cat > "README-${ROOT_VARIANT}.txt" <<EOF
${PACKAGE_NAME}
Kernel : ${KERNEL_REPO} @ ${KERNEL_COMMIT}
Root   : ${ROOT_REPO} @ ${DRIVER_COMMIT}
SUSFS  : ${SUSFS_REF} @ ${SUSFS_COMMIT}
AK3    : ${AK3_REPO} @ ${AK3_COMMIT}
Toolchain: $(clang --version | head -n1)
Built  : $(date -u +%Y-%m-%dT%H:%M:%SZ)

Flash with Kernel Flasher / FKM / recovery. The package keeps the stock
ramdisk and replaces boot, vendor_boot ramdisk modules and vendor_dlkm modules.
Manager must match the selected root variant.
EOF
find . -type f -name 'placeholder' -delete 2>/dev/null || true
ZIP="$OUT_DIR/${PACKAGE_NAME}-AnyKernel3.zip"
rm -f "$ZIP"
python3 - "$ZIP" <<'PYZIP'
import os, sys, time, zipfile
out = sys.argv[1]
def mode(n):
    if n in ("META-INF/com/google/android/update-binary", "anykernel.sh") or n.startswith("tools/") or n.endswith(".sh"):
        return 0o755
    return 0o644
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for root, dirs, files in os.walk("."):
        dirs.sort()
        for f in sorted(files):
            p = os.path.join(root, f)
            name = os.path.relpath(p, ".").replace("\\", "/")
            zi = zipfile.ZipInfo(name, date_time=time.gmtime()[:6])
            zi.external_attr = (mode(name) << 16) | (0o10 << 28)
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, open(p, "rb").read())
print("AK3 packed with unix permissions")
PYZIP
cd "$REPO_ROOT"
( cd "$OUT_DIR" && sha256sum "${PACKAGE_NAME}-AnyKernel3.zip" > SHA256SUMS.txt )
cat > "$OUT_DIR/build.env" <<EOF
PACKAGE_NAME=${PACKAGE_NAME}
KERNEL_RELEASE=${KERNEL_RELEASE}
KERNEL_VERSION=${KERNEL_VERSION}
ROOT_VARIANT=${ROOT_VARIANT}
ROOT_REF=${ROOT_REF}
ROOT_COMMIT=${ROOT_COMMIT}
SUSFS_REF=${SUSFS_REF}
SUSFS_COMMIT=${SUSFS_COMMIT}
KERNEL_COMMIT=${KERNEL_COMMIT}
AK3_COMMIT=${AK3_COMMIT}
ZIP_SHA256=$(awk '{print $1}' "$OUT_DIR/SHA256SUMS.txt")
EOF
ok "DONE: $OUT_DIR/${PACKAGE_NAME}-AnyKernel3.zip"
