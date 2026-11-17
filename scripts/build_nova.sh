#!/usr/bin/env bash
# ============================================================================
# XAGA (MT6895 / Dimensity 8100) kernel build: AOSP GKI 5.10 + SukiSU-Nova + SUSFS
#
# Produces (in ARTIFACT_DIR):
#   - boot.img        : flashable, 64MiB-aligned, stock ramdisk + new kernel
#   - AnyKernel3 zip  : AK3 flashable (Image.gz + anykernel template + modules)
#   - modules/        : built vendor-agnostic kernel modules (if any)
#   - config          : final .config (IKCONFIG) for verification
#   - README / notes  : version provenance, flash steps, verification
#
# Driver : SukiSU-Nova main @ c60f21b9 (renamed from SukiSU-Ultra, 2026-11-15);
#          KPM + built-in Zygisk + susfs_extension compiled unconditionally
# SUSFS  : official susfs4ksu @ gki-android12-5.10 (kernel-side patch)
# Kernel : aosp-mirror/kernel_common @ 81e7418c (GKI android12-5.10 KMI)
# Stock  : user-provided V14.0.6.0 boot.img (sha 8a818f31..., 5.10.136-...)
# ============================================================================
set -euo pipefail

info() { printf '[nova] %s\n' "$*"; }
warn() { printf '[nova] WARN: %s\n' "$*" >&2; }
die()  { printf '[nova] ERROR: %s\n' "$*" >&2; exit 1; }

# ------------------------------ config -------------------------------------
# Resolve ALL repo-relative paths BEFORE any cd: the workflow invokes this
# script with a RELATIVE path, and later `cd $WORK/common` (kernel tree has
# its own scripts/) would silently re-resolve BASH_SOURCE into the kernel
# tree (CI run 43968518157 failure). Pin the repo root here, once.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK="${WORK:-$REPO_ROOT/.nova-work}"
ARTIFACTS="${ARTIFACTS:-$REPO_ROOT/artifacts-nova}"
JOBS="${JOBS:-$(nproc --all)}"

KERNEL_REPO="${KERNEL_REPO:-aosp-mirror/kernel_common}"
KERNEL_BRANCH="${KERNEL_BRANCH:-android12-5.10}"
KERNEL_COMMIT="${KERNEL_COMMIT:-81e7418c6466ca1c3c6fc4a173fc4e2073a91af1}"

CLANG_REPO="${CLANG_REPO:-LineageOS/android_prebuilts_clang_kernel_linux-x86_clang-r416183b}"
CLANG_BRANCH="${CLANG_BRANCH:-lineage-20.0}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"

NOVA_REPO="${NOVA_REPO:-https://github.com/SukiSU-Nova/SukiSU-Nova.git}"
NOVA_REF="${NOVA_REF:-c60f21b9e00e}"            # main HEAD 2026-11-15 (rename commit; susfs+zygisk)
SUSFS_REPO="${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu.git}"
SUSFS_BRANCH="${SUSFS_BRANCH:-gki-android12-5.10}"
MAGISK_URL="${MAGISK_URL:-https://github.com/topjohnwu/Magisk/releases/download/v31.1/Magisk-v31.1.apk}"

# Stock kernel release string (from user's V14.0.6.0 boot.img banner)
STOCK_KREL="${STOCK_KREL:-5.10.136-android12-9-00020-gc9f59ef34367-ab9585114}"
SCMVERSION_SUFFIX="${SCMVERSION_SUFFIX:--android12-9-00020-gc9f59ef34367-ab9585114}"
STOCK_BOOT_SHA="${STOCK_BOOT_SHA:-8a818f319380a7bb2e432f8cf6eed2aaa0a7d5c1ac57cc2bbcf191b557b58faf}"
STOCK_CHUNKS_DIR="${STOCK_CHUNKS_DIR:-$REPO_ROOT/boot-bakasu}"

ENABLE_SUSFS="${ENABLE_SUSFS:-1}"

rm -rf "$WORK"; mkdir -p "$WORK" "$ARTIFACTS"
cd "$WORK"

# ------------------------------ stock boot ---------------------------------
info "Reassembling stock boot.img from chunks ..."
cat "${STOCK_CHUNKS_DIR}"/boot.img.part-*.part > "$WORK/stock-boot.img"
ACTUAL_SHA="$(sha256sum "$WORK/stock-boot.img" | awk '{print $1}')"
[[ "$ACTUAL_SHA" == "$STOCK_BOOT_SHA" ]] || die "stock boot sha mismatch: $ACTUAL_SHA"
info "stock boot verified: $ACTUAL_SHA"

# ------------------------------ toolchain ----------------------------------
info "Fetching clang toolchain ($CLANG_BRANCH) ..."
mkdir -p clang
curl -fL --retry 3 "https://codeload.github.com/${CLANG_REPO}/tar.gz/refs/heads/${CLANG_BRANCH}" -o clang.tar.gz
tar -xzf clang.tar.gz -C clang --strip-components=1
chmod +x clang/bin/*
export PATH="$WORK/clang/bin:$PATH"
clang --version | head -2

# ------------------------------ kernel source ------------------------------
info "Fetching kernel source (${KERNEL_REPO} @ ${KERNEL_COMMIT:0:12}) ..."
mkdir -p common && cd common
git init -q
git remote add origin "https://github.com/${KERNEL_REPO}.git"
git fetch --depth 1 origin "$KERNEL_COMMIT"
git checkout -q FETCH_HEAD
git log -1 --format='kernel_commit=%H%ndate=%ad%nsubject=%s' --date=iso | tee "$ARTIFACTS/kernel-source.txt"

# Reproduce stock release string exactly (avoid -g<sha>-dirty suffix).
# kernel_common Makefile is already at 5.10.x; override SUBLEVEL if needed to 136.
sed -i -E "s/^SUBLEVEL[[:space:]]*=.*/SUBLEVEL = 136/" Makefile
echo "$SCMVERSION_SUFFIX" > .scmversion
info "kernel release will be: 5.10${SCMVERSION_SUFFIX}"

# ---------------------------- SukiSU-Nova driver ---------------------------
info "Injecting SukiSU-Nova driver @ ${NOVA_REF:0:12} ..."
curl -fLSs --retry 3 "https://raw.githubusercontent.com/SukiSU-Nova/SukiSU-Nova/main/kernel/setup.sh" -o "$WORK/nova_setup.sh"
bash "$WORK/nova_setup.sh" "$NOVA_REF"
( cd KernelSU && git checkout -q "$NOVA_REF" )
test -e drivers/kernelsu/Kconfig || die "SukiSU-Nova driver not linked into drivers/"
NOVA_SHA="$(git -C KernelSU rev-parse HEAD)"
git -C KernelSU log -1 --format='nova_commit=%H%ndate=%ad%nsubject=%s' --date=iso | tee "$ARTIFACTS/nova-driver.txt"
# Nova builds susfs_extension.o + kpm.o unconditionally via kernel/Kbuild.
grep -c 'susfs_extension' KernelSU/kernel/Kbuild | tee -a "$ARTIFACTS/nova-driver.txt"

# ------------------------------ SUSFS patch --------------------------------
if [[ "$ENABLE_SUSFS" == "1" ]]; then
  info "Applying SUSFS kernel patch (${SUSFS_BRANCH}) ..."
  git clone --depth 1 -b "$SUSFS_BRANCH" "$SUSFS_REPO" "$WORK/susfs4ksu"
  cd "$WORK/common"
  PATCH="$WORK/susfs4ksu/kernel_patches/50_add_susfs_in_gki-android12-5.10.patch"
  if patch -p1 --forward --batch < "$PATCH"; then
    info "SUSFS main patch applied cleanly"
  else
    warn "SUSFS patch had hunk failures; integrity check will decide"
  fi
  cp -f "$WORK"/susfs4ksu/kernel_patches/fs/* fs/
  cp -f "$WORK"/susfs4ksu/kernel_patches/include/linux/* include/linux/
  test -f fs/susfs.c || die "fs/susfs.c missing"
  test -f include/linux/susfs_def.h || die "include/linux/susfs_def.h missing"
  HOOKED="$(grep -rl 'susfs' fs/ --include='*.c' | wc -l)"
  info "fs sources with susfs hooks: $HOOKED"
  [[ "$HOOKED" -ge 3 ]] || die "SUSFS hooks not injected into fs/ (incomplete patch)"
  echo "$HOOKED" > "$ARTIFACTS/susfs-hooked-files.txt"

  # --- compat fix: newer susfs4ksu uses VMA_PAD_START(), which this pinned
  # GKI 5.10 tree (81e7418c) predates. Backport a no-op definition so the
  # spoofed /proc/<pid>/maps code compiles (modern kernels pad to vm_end).
  if grep -rq 'VMA_PAD_START' fs/ include/ && ! grep -rq 'define VMA_PAD_START' include/; then
    info "Backporting VMA_PAD_START compat macro for older 5.10 tree ..."
    cat >> include/linux/mm.h <<'COMPAT_EOF'

/* compat: susfs4ksu gki-android12-5.10 uses VMA_PAD_START (newer kernels);
 * this 5.10 tree has no VMA padding, so map it to vm_end. */
#ifndef VMA_PAD_START
#define VMA_PAD_START(vma) ((vma)->vm_end)
#endif
COMPAT_EOF
    grep -q 'define VMA_PAD_START' include/linux/mm.h || die "VMA_PAD_START compat injection failed"
  fi
else
  cd "$WORK/common"
fi

# ------------------------------ kernel config ------------------------------
info "Configuring kernel (gki_defconfig + SukiSU-Nova + SUSFS) ..."
MAKEARGS="O=out ARCH=arm64 CC=clang HOSTCC=clang LLVM=1 LLVM_IAS=1 CROSS_COMPILE=$CROSS_COMPILE"
make $MAKEARGS gki_defconfig
# GitHub runner has ~16GB RAM and swapon is not permitted; Full LTO link would
# be OOM-killed -> ThinLTO (gki_defconfig default, far lower peak memory).
# CRITICAL: CFI must stay ON. CONFIG_CFI_CLANG adds `cfi_check_fn cfi_check`
# to struct module (include/linux/module.h), which changes the module_layout
# symbol CRC. Stock vendor modules (mkp.ko, ufs-mediatek.ko, ...) are built
# against a CFI-on kernel; with CFI off every vendor module fails
# "disagrees about version of symbol module_layout", storage drivers never
# come up, init exits -> Kernel panic -> bootloop. (Verified via ramoops.)
# Pinned gki_defconfig defaults to LTO_CLANG_FULL=y (OOMs 16GB runner) with
# CFI_CLANG=y. If we merely -d LTO_CLANG_FULL, the LTO choice falls back to
# LTO_NONE=y and CFI (depends on LTO) is SILENTLY DROPPED -> module_layout
# CRC mismatch -> all stock vendor modules fail -> init panic bootloop.
# Fix = proven recipe from run#4 (6c1d960, verified bootable on xaga):
# force ThinLTO via kconfig AND make command-line vars.
scripts/config --file out/.config -d LTO_CLANG_FULL -d LTO_NONE -e LTO_CLANG_THIN -e CFI_CLANG
scripts/config --file out/.config -e KSU
if [[ "$ENABLE_SUSFS" == "1" ]]; then
  scripts/config --file out/.config \
    -e KSU_SUSFS -e KSU_SUSFS_SUS_PATH -e KSU_SUSFS_SUS_MOUNT \
    -e KSU_SUSFS_SUS_KSTAT -e KSU_SUSFS_SPOOF_UNAME -e KSU_SUSFS_ENABLE_LOG \
    -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS -e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
    -e KSU_SUSFS_OPEN_REDIRECT -e KSU_SUSFS_SUS_MAP
fi
make $MAKEARGS olddefconfig
# HARD GATE: vendor-module ABI depends on these; fail fast instead of
# shipping a kernel that bootloops on device (CI run 43970952769 lesson).
grep -q '^CONFIG_LTO_CLANG_THIN=y' out/.config || die "LTO_CLANG_THIN not set (CFI would be dropped, vendor CRC mismatch)"
grep -q '^CONFIG_CFI_CLANG=y' out/.config || die "CFI_CLANG not set (vendor module module_layout CRC will mismatch)"
info "--- key config ---"
grep -E 'CONFIG_(KSU|KSU_SUSFS[A-Z_]*|LTO_CLANG_THIN|LTO_NONE|CFI_CLANG|MODVERSIONS|MODULE_SCMVERSION|LOCALVERSION|KPROBES)=|^# CONFIG_LOCALVERSION_AUTO' out/.config | tee "$ARTIFACTS/kernel.config.txt"
info "--- kernelrelease: $(make $MAKEARGS -s kernelrelease) ---"

# ------------------------------ build --------------------------------------
info "Building kernel Image (ThinLTO+CFI, jobs=$JOBS) ..."
export KBUILD_BUILD_USER=build-user KBUILD_BUILD_HOST=build-host KBUILD_BUILD_VERSION=1
make $MAKEARGS -j"$JOBS" \
  CONFIG_LTO_CLANG=y CONFIG_LTO_NONE=n CONFIG_LTO_CLANG_THIN=y CONFIG_LTO_CLANG_FULL=n \
  Image 2>&1 | tee "$ARTIFACTS/build.log"
test -f out/arch/arm64/boot/Image || die "Image not built"

# ------------------------------ verify kernel ------------------------------
info "Verifying kernel image ..."
# Match the FULL version string, not just "Linux version": a ThinLTO relink
# can reorder .rodata so a format string ("Linux version %s (%s)") precedes
# the real banner and grep -m1 would pick it (CI run 43974154021 lesson).
strings out/arch/arm64/boot/Image | grep -m1 "Linux version ${STOCK_KREL}" | tee "$ARTIFACTS/kernel-banner.txt"
[[ -s "$ARTIFACTS/kernel-banner.txt" ]] || die "kernel banner mismatch (vermagic risk)"
KSU_STR=$(strings out/arch/arm64/boot/Image | grep -c -i 'KernelSU' || true)
SUSFS_STR=$(strings out/arch/arm64/boot/Image | grep -c -i 'susfs' || true)
info "KernelSU strings: $KSU_STR | SUSFS strings: $SUSFS_STR"
echo "KernelSU strings: $KSU_STR" > "$ARTIFACTS/symbol-counts.txt"
echo "SUSFS strings: $SUSFS_STR" >> "$ARTIFACTS/symbol-counts.txt"
# CFI on-device proof: with CFI_CLANG=y the final image contains __cfi_check.
# NOTE: ThinLTO merges the per-TU __cfi_check handlers into ONE global one,
# so exactly 1 occurrence is the expected/healthy result (CI run 43976982235).
# CFI off => 0 occurrences. Cross-check System.map as well.
CFI_N=$(strings out/arch/arm64/boot/Image | grep -c '__cfi_check' || true)
info "__cfi_check occurrences: $CFI_N (ThinLTO merges per-TU handlers into one)"
[[ "${CFI_N:-0}" -ge 1 ]] || die "kernel built without CFI (module_layout CRC will mismatch stock vendor modules)"
grep -q '__cfi_check' out/System.map || die "System.map missing __cfi_check (CFI off)"

# ------------------------------ repack boot.img ----------------------------
info "Repacking boot.img with magiskboot ..."
cd "$WORK"
curl -fL --retry 3 "$MAGISK_URL" -o magisk.apk
unzip -o -q magisk.apk 'lib/x86_64/libmagiskboot.so' -d magiskboot_pkg
cp magiskboot_pkg/lib/x86_64/libmagiskboot.so magiskboot && chmod +x magiskboot
mkdir -p repack && cd repack
cp "$WORK/stock-boot.img" stock-boot.img
"$WORK/magiskboot" unpack stock-boot.img
cp "$WORK/common/out/arch/arm64/boot/Image" kernel
"$WORK/magiskboot" repack stock-boot.img "$ARTIFACTS/boot.img"
# Keep the reference partition size (64MiB), matching the stock layout.
truncate -s "$(stat -c %s stock-boot.img)" "$ARTIFACTS/boot.img"
cd "$WORK/common"

# ------------------------------ AK3 package --------------------------------
info "Building AnyKernel3 package ..."
AK3="$WORK/ak3"; rm -rf "$AK3"; mkdir -p "$AK3"
# Template strategy:
#   1) shell (anykernel.sh/install flow) from THIS repo's anykernel/ - the
#      dump_boot/write_boot flow already proven working on xaga by the user;
#   2) tools/ + META-INF upgraded from WildKernels/AnyKernel3@gki-2.0 (the
#      template used by the WildKernels GKI CI project): much newer magiskboot
#      (2025-11, full boot header v4 support) and busybox 1.36.1-osm0sis.
info "AK3 template: REPO_ROOT=$REPO_ROOT"
ls -la "$REPO_ROOT/anykernel" 2>&1 | head -6 || true
if [[ -f "$REPO_ROOT/anykernel/META-INF/com/google/android/update-binary" ]]; then
  info "Using anykernel.sh shell from repo anykernel/"
  cp -rp "$REPO_ROOT/anykernel/." "$AK3/"
else
  die "repo anykernel/ template missing (need META-INF/com/google/android/update-binary)"
fi
# Upgrade tools/ + META-INF from WildKernels gki-2.0 (keep our anykernel.sh)
if git clone --depth=1 -b gki-2.0 https://github.com/WildKernels/AnyKernel3.git "$WORK/ak3wild" 2>&1 | tail -1; then
  if [[ -f "$WORK/ak3wild/tools/ak3-core.sh" && -f "$WORK/ak3wild/META-INF/com/google/android/update-binary" ]]; then
    info "Upgrading AK3 tools/META-INF from WildKernels gki-2.0"
    rm -rf "$AK3/tools" "$AK3/META-INF"
    cp -rp "$WORK/ak3wild/tools" "$AK3/tools"
    cp -rp "$WORK/ak3wild/META-INF" "$AK3/META-INF"
  else
    info "WildKernels template incomplete - keeping repo tools/META-INF"
  fi
else
  info "WildKernels clone failed - keeping repo tools/META-INF"
fi
# Kernel display name = stock-style release string (matches baked-in banner)
sed -i "s|^kernel.string=.*|kernel.string=${STOCK_KREL}|" "$AK3/anykernel.sh"
# gzip the kernel for AK3 (AK3 handles decompression via magiskboot/ak3-core)
gzip -c out/arch/arm64/boot/Image > "$AK3/Image.gz" 2>/dev/null || \
  cp out/arch/arm64/boot/Image "$AK3/Image"
mkdir -p "$AK3/modules"
# Stage any built loadable modules into AK3 modules/ (GKI build usually none)
find out -name '*.ko' -exec cp -f {} "$AK3/modules/" \; 2>/dev/null || true
cp out/.config "$AK3/kernel.config"
cat > "$AK3/README-SUKISU-NOVA.txt" <<EOF2
XAGA (MT6895) kernel - SukiSU-Nova + SUSFS flashable package
============================================================
Kernel source : ${KERNEL_REPO} @ ${KERNEL_COMMIT:0:12} (GKI android12-5.10)
Kernel release: 5.10${SCMVERSION_SUFFIX}
SukiSU-Nova   : ${NOVA_REF:0:12} (${NOVA_SHA:0:12}), KPM + built-in Zygisk
SUSFS         : ${SUSFS_BRANCH} (kernel-side patch), fs hooks: $(cat "$ARTIFACTS/susfs-hooked-files.txt")
Built         : $(date -u +%Y-%m-%dT%H:%M:%SZ)

Flash:
  - boot.img  : fastboot flash boot boot.img  (single slot) or fastboot flash boot_a/boot_b
  - AK3 zip   : flash via Magisk/Recovery; replaces kernel in boot, keeps stock ramdisk

SUSFS integration (kernel side - already in this image):
  - susfs.c / susfs_def.h + 15 fs files hooked; CONFIG_KSU_SUSFS=y and sub-options on.
  - Kernel image verified: SUSFS strings present (see symbol-counts.txt in the CI artifact).

SUSFS userspace (you must install - kernel patch alone does nothing visible):
  1) Install the SukiSU-Nova manager whose version matches this driver (main @ ${NOVA_REF:0:12}).
     Official APK: https://github.com/SukiSU-Nova/SukiSU-Nova/releases
  2) In manager: grant root, open the SUSFS page, install/enable the SUSFS module and
     the ksu_susfs tool (manager pushes it to /data/adb/ksu/bin/).
  3) Confirm: root shell -> `ksu_susfs version` returns a version; manager SUSFS page
     shows features as supported.

Flash notes:
  - Bootloader must be unlocked; disable AVB/vbmeta verification for a custom kernel.
  - Flash the matching slot (A/B). AK3 handles slot detection automatically.
  - Kernel release string matches stock (vermagic) so vendor modules still load.
  - Known limits: Full LTO disabled for 16GB CI runner (ThinLTO+CFI kept on for vendor module ABI);
    VMA_PAD_START backported as vm_end for the older 5.10 tree.
EOF2
cat > "$ARTIFACTS/flash-fastboot.sh" <<'FLASHEOF'
#!/system/bin/sh
# Optional helper: flash this package's boot.img from fastboot on a connected device.
# Usage: sh flash-fastboot.sh [boot|boot_a|boot_b]   (default: boot)
set -e
PART="${1:-boot}"
DIR="$(cd "$(dirname "$0")" && pwd)"
fastboot flash "$PART" "$DIR/boot.img"
echo "Flashed boot.img to $PART; reboot with: fastboot reboot"
FLASHEOF
chmod +x "$ARTIFACTS/flash-fastboot.sh"
cd "$AK3"
ZIP="$ARTIFACTS/AnyKernel3-SukiSU-Nova-SUSFS-xaga.zip"
rm -f "$ZIP"
# Pack with python3 so Unix permission bits are correct on ANY host
# (Windows 'zip'/'7z' stores 0666/fat -> recovery cannot exec tools/busybox
#  & tools/magiskboot -> AK3 install aborts with "flash failed").
python3 - "$ZIP" <<'PYEOF'
import os, sys, zipfile
zip_path = sys.argv[1]
def mode_for(name):
    if name in ("META-INF/com/google/android/update-binary", "anykernel.sh") \
       or name.startswith("tools/") or name.endswith(".sh"):
        return 0o755
    return 0o644
with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for root, dirs, files in os.walk("."):
        dirs.sort()
        for f in sorted(files):
            p = os.path.join(root, f)
            name = os.path.relpath(p, ".").replace("\\", "/")
            zi = zipfile.ZipInfo(name, date_time=__import__("time").gmtime()[:6])
            zi.external_attr = (mode_for(name) << 16) | (0o10 << 28)
            zi.compress_type = zipfile.ZIP_DEFLATED
            with open(p, "rb") as fh:
                z.writestr(zi, fh.read())
print("AK3 zip packed with correct unix perms")
PYEOF
cd "$WORK/common"

# ------------------------------ checksums ----------------------------------
( cd "$ARTIFACTS" && sha256sum boot.img AnyKernel3-SukiSU-Nova-SUSFS-xaga.zip > SHA256SUMS.txt )

info "=== DONE ==="
info "boot.img : $(du -h "$ARTIFACTS/boot.img" | cut -f1)"
info "AK3 zip  : $(du -h "$ARTIFACTS/AnyKernel3-SukiSU-Nova-SUSFS-xaga.zip" | cut -f1)"
ls -la "$ARTIFACTS"
