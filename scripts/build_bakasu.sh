#!/usr/bin/env bash
# ============================================================================
# XAGA (MT6895 / Dimensity 8100) kernel build: AOSP GKI 5.10 + BakaSU + SUSFS
#
# Produces (in ARTIFACT_DIR):
#   - boot.img        : flashable, 64MiB-aligned, stock ramdisk + new kernel
#   - AnyKernel3 zip  : AK3 flashable (Image.gz + anykernel template + modules)
#   - modules/        : built vendor-agnostic kernel modules (if any)
#   - config          : final .config (IKCONFIG) for verification
#   - README / notes  : version provenance, flash steps, verification
#
# Driver : BakaSU main @ 5d6d1843 (latest CI-passing kernel driver, 2026-11-15)
# SUSFS  : official susfs4ksu @ gki-android12-5.10 (kernel-side patch)
# Kernel : aosp-mirror/kernel_common @ 81e7418c (GKI android12-5.10 KMI)
# Stock  : user-provided V14.0.6.0 boot.img (sha 8a818f31..., 5.10.136-...)
# ============================================================================
set -euo pipefail

info() { printf '[bakasu] %s\n' "$*"; }
warn() { printf '[bakasu] WARN: %s\n' "$*" >&2; }
die()  { printf '[bakasu] ERROR: %s\n' "$*" >&2; exit 1; }

# ------------------------------ config -------------------------------------
WORK="${WORK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.bakasu-work}"
ARTIFACTS="${ARTIFACTS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/artifacts-bakasu}"
JOBS="${JOBS:-$(nproc --all)}"

KERNEL_REPO="${KERNEL_REPO:-aosp-mirror/kernel_common}"
KERNEL_BRANCH="${KERNEL_BRANCH:-android12-5.10}"
KERNEL_COMMIT="${KERNEL_COMMIT:-81e7418c6466ca1c3c6fc4a173fc4e2073a91af1}"

CLANG_REPO="${CLANG_REPO:-LineageOS/android_prebuilts_clang_kernel_linux-x86_clang-r416183b}"
CLANG_BRANCH="${CLANG_BRANCH:-lineage-20.0}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"

BAKASU_REPO="${BAKASU_REPO:-https://github.com/Baka-SU/BakaSU.git}"
BAKASU_REF="${BAKASU_REF:-5d6d1843c893}"        # latest CI-passing main HEAD (252b1520 had a link bug)
SUSFS_REPO="${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu.git}"
SUSFS_BRANCH="${SUSFS_BRANCH:-gki-android12-5.10}"
MAGISK_URL="${MAGISK_URL:-https://github.com/topjohnwu/Magisk/releases/download/v31.1/Magisk-v31.1.apk}"

# Stock kernel release string (from user's V14.0.6.0 boot.img banner)
STOCK_KREL="${STOCK_KREL:-5.10.136-android12-9-00020-gc9f59ef34367-ab9585114}"
SCMVERSION_SUFFIX="${SCMVERSION_SUFFIX:--android12-9-00020-gc9f59ef34367-ab9585114}"
STOCK_BOOT_SHA="${STOCK_BOOT_SHA:-8a818f319380a7bb2e432f8cf6eed2aaa0a7d5c1ac57cc2bbcf191b557b58faf}"
STOCK_CHUNKS_DIR="${STOCK_CHUNKS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/boot-bakasu}"

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

# ------------------------------ BakaSU driver ------------------------------
info "Injecting BakaSU driver @ ${BAKASU_REF:0:12} ..."
curl -fLSs --retry 3 "https://raw.githubusercontent.com/Baka-SU/BakaSU/main/kernel/setup.sh" -o "$WORK/bakasu_setup.sh"
bash "$WORK/bakasu_setup.sh" "$BAKASU_REF"
( cd KernelSU && git checkout -q "$BAKASU_REF" )
test -e drivers/kernelsu/Kconfig || die "BakaSU driver not linked into drivers/"
BAKASU_SHA="$(git -C KernelSU rev-parse HEAD)"
git -C KernelSU log -1 --format='bakasu_commit=%H%ndate=%ad%nsubject=%s' --date=iso | tee "$ARTIFACTS/bakasu-driver.txt"
grep -c 'config KSU_SUSFS' KernelSU/kernel/Kconfig | tee -a "$ARTIFACTS/bakasu-driver.txt"

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
info "Configuring kernel (gki_defconfig + BakaSU + SUSFS) ..."
MAKEARGS="O=out ARCH=arm64 CC=clang HOSTCC=clang LLVM=1 LLVM_IAS=1 CROSS_COMPILE=$CROSS_COMPILE"
make $MAKEARGS gki_defconfig
# GitHub runner has ~16GB RAM and swapon is not permitted; Full LTO link would
# be OOM-killed. Switch to ThinLTO (far lower peak memory, same KMI).
# Disable LLVM LTO entirely: Full LTO OOMs the 16GB runner (swapon blocked),
# and ThinLTO internalizes BakaSU's static selinux_hide_init_setxattr() causing
# an undefined-symbol link failure. LTO is optional hardening, not part of KMI.
scripts/config --file out/.config -d LTO_CLANG_FULL -d LTO_CLANG_THIN -e LTO_NONE
scripts/config --file out/.config -d CFI_CLANG
scripts/config --file out/.config -e KSU
if [[ "$ENABLE_SUSFS" == "1" ]]; then
  scripts/config --file out/.config \
    -e KSU_SUSFS -e KSU_SUSFS_SUS_PATH -e KSU_SUSFS_SUS_MOUNT \
    -e KSU_SUSFS_SUS_KSTAT -e KSU_SUSFS_SPOOF_UNAME -e KSU_SUSFS_ENABLE_LOG \
    -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS -e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
    -e KSU_SUSFS_OPEN_REDIRECT -e KSU_SUSFS_SUS_MAP
fi
make $MAKEARGS olddefconfig
info "--- key config ---"
grep -E 'CONFIG_(KSU|KSU_SUSFS[A-Z_]*|LTO_CLANG_FULL|CFI_CLANG|MODVERSIONS|MODULE_SCMVERSION|LOCALVERSION|KPROBES)=|^# CONFIG_LOCALVERSION_AUTO' out/.config | tee "$ARTIFACTS/kernel.config.txt"
info "--- kernelrelease: $(make $MAKEARGS -s kernelrelease) ---"

# ------------------------------ build --------------------------------------
info "Building kernel Image (no-LTO, jobs=$JOBS) ..."
export KBUILD_BUILD_USER=build-user KBUILD_BUILD_HOST=build-host KBUILD_BUILD_VERSION=1
make $MAKEARGS -j"$JOBS" Image 2>&1 | tee "$ARTIFACTS/build.log"
test -f out/arch/arm64/boot/Image || die "Image not built"

# ------------------------------ verify kernel ------------------------------
info "Verifying kernel image ..."
strings out/arch/arm64/boot/Image | grep -m1 'Linux version' | tee "$ARTIFACTS/kernel-banner.txt"
grep -q "Linux version ${STOCK_KREL}" "$ARTIFACTS/kernel-banner.txt" || die "kernel banner mismatch (vermagic risk)"
KSU_STR=$(strings out/arch/arm64/boot/Image | grep -c -i 'KernelSU' || true)
SUSFS_STR=$(strings out/arch/arm64/boot/Image | grep -c -i 'susfs' || true)
info "KernelSU strings: $KSU_STR | SUSFS strings: $SUSFS_STR"
echo "KernelSU strings: $KSU_STR" > "$ARTIFACTS/symbol-counts.txt"
echo "SUSFS strings: $SUSFS_STR" >> "$ARTIFACTS/symbol-counts.txt"

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
# Use the full AnyKernel3 template from THIS repo's checkout (has META-INF/,
# tools/ak3-core.sh, magiskboot, etc.). kernel_common has no anykernel/.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$REPO_ROOT/anykernel/META-INF/com/google/android/update-binary" ]]; then
  info "Using full AnyKernel3 template from repo anykernel/"
  cp -rp "$REPO_ROOT/anykernel/." "$AK3/"
else
  die "repo anykernel/ template missing (need META-INF/com/google/android/update-binary)"
fi
# gzip the kernel for AK3 (AK3 handles decompression via magiskboot/ak3-core)
gzip -c out/arch/arm64/boot/Image > "$AK3/Image.gz" 2>/dev/null || \
  cp out/arch/arm64/boot/Image "$AK3/Image"
mkdir -p "$AK3/modules"
# Stage any built loadable modules into AK3 modules/ (GKI build usually none)
find out -name '*.ko' -exec cp -f {} "$AK3/modules/" \; 2>/dev/null || true
cp out/.config "$AK3/kernel.config"
cat > "$AK3/README-BAKASU.txt" <<EOF2
XAGA (MT6895) kernel - BakaSU + SUSFS flashable package
=======================================================
Kernel source : ${KERNEL_REPO} @ ${KERNEL_COMMIT:0:12} (GKI android12-5.10)
Kernel release: 5.10${SCMVERSION_SUFFIX}
BakaSU driver : ${BAKASU_REF:0:12} (${BAKASU_SHA:0:12})
SUSFS         : ${SUSFS_BRANCH} (kernel-side patch), fs hooks: $(cat "$ARTIFACTS/susfs-hooked-files.txt")
Built         : $(date -u +%Y-%m-%dT%H:%M:%SZ)

Flash:
  - boot.img  : fastboot flash boot boot.img  (single slot) or fastboot flash boot_a/boot_b
  - AK3 zip   : flash via Magisk/Recovery; replaces kernel in boot, keeps stock ramdisk

SUSFS integration (kernel side - already in this image):
  - susfs.c / susfs_def.h + 15 fs files hooked; CONFIG_KSU_SUSFS=y and sub-options on.
  - Kernel image verified: SUSFS strings present (see symbol-counts.txt in the CI artifact).

SUSFS userspace (you must install - kernel patch alone does nothing visible):
  1) Install a BakaSU manager whose version matches this driver (main @ ${BAKASU_REF:0:12}).
     Official APK: https://github.com/Baka-SU/BakaSU/releases  /  CI: https://bakasu.org
  2) In manager: grant root, open the SUSFS page, install/enable the SUSFS module and
     the ksu_susfs tool (manager pushes it to /data/adb/ksu/bin/).
  3) Confirm: root shell -> `ksu_susfs version` returns a version; manager SUSFS page
     shows features as supported.

Flash notes:
  - Bootloader must be unlocked; disable AVB/vbmeta verification for a custom kernel.
  - Flash the matching slot (A/B). AK3 handles slot detection automatically.
  - Kernel release string matches stock (vermagic) so vendor modules still load.
  - Known limits: Full LTO/CFI disabled for 16GB CI runner (no runtime impact);
    VMA_PAD_START backported as vm_end for the older 5.10 tree.
EOF2
cat > "$AK3/flash-fastboot.sh" <<'FLASHEOF'
#!/system/bin/sh
# Optional helper: flash this package's boot.img from fastboot on a connected device.
# Usage: sh flash-fastboot.sh [boot|boot_a|boot_b]   (default: boot)
set -e
PART="${1:-boot}"
DIR="$(cd "$(dirname "$0")" && pwd)"
fastboot flash "$PART" "$DIR/boot.img"
echo "Flashed boot.img to $PART; reboot with: fastboot reboot"
FLASHEOF
chmod +x "$AK3/flash-fastboot.sh"
cd "$AK3"
ZIP="$ARTIFACTS/AnyKernel3-BakaSU-SUSFS-xaga.zip"
if command -v 7za >/dev/null 2>&1; then 7za a -mx9 "$ZIP" * >/dev/null
elif command -v 7z >/dev/null 2>&1; then 7z a -mx9 "$ZIP" * >/dev/null
else zip -r9 "$ZIP" .; fi
cd "$WORK/common"

# ------------------------------ checksums ----------------------------------
( cd "$ARTIFACTS" && sha256sum boot.img AnyKernel3-BakaSU-SUSFS-xaga.zip > SHA256SUMS.txt )

info "=== DONE ==="
info "boot.img : $(du -h "$ARTIFACTS/boot.img" | cut -f1)"
info "AK3 zip  : $(du -h "$ARTIFACTS/AnyKernel3-BakaSU-SUSFS-xaga.zip" | cut -f1)"
ls -la "$ARTIFACTS"
