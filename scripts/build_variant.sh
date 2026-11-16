#!/usr/bin/env bash
# ============================================================================
# XAGA kernel builder with two ordered variants
#   VARIANT=a  : Nova official GKI path (main @ v3.0.0 / c60f21b9), KPM mode,
#                stock kernel name, NO kernel-level SUSFS (handled by userspace).
#   VARIANT=c  : Built on top of A's configuration. Nova `builtin` branch
#                (@ 4bec532dd4) + official susfs4ksu kernel patch adapted for
#                the builtin driver => real kernel-level SUSFS symbols.
#
# Both variants repack a flashable boot.img from the vendored stock chunks.
#
# Usage:  VARIANT=a bash scripts/build_variant.sh
#         VARIANT=c bash scripts/build_variant.sh
# ============================================================================
set -euo pipefail

log()  { echo "[build:$VARIANT] $*"; }
warn() { echo "[build:$VARIANT] WARNING: $*" >&2; }
die()  { echo "[build:$VARIANT] ERROR: $*" >&2; exit 1; }

VARIANT="${VARIANT:-a}"
case "$VARIANT" in a|A) VARIANT=a ;; c|C) VARIANT=c ;; *) die "VARIANT must be 'a' or 'c'" ;; esac

# ----------------------------- configuration -------------------------------
KERNEL_DIR="${KERNEL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-${KERNEL_DIR}/../toolchain}"
CLANG_DIR="${CLANG_DIR:-${TOOLCHAIN_DIR}/clang}"
WORK_DIR="${WORK_DIR:-${KERNEL_DIR}/.ci}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${KERNEL_DIR}/artifacts}"
OUT_DIR="${OUT_DIR:-${KERNEL_DIR}/out}"
DEFCONFIG="${DEFCONFIG:-gki_defconfig}"
JOBS="${JOBS:-$(nproc --all)}"
ENABLE_CCACHE="${ENABLE_CCACHE:-1}"

# Nova pinning: A = main v3.0.0 (latest CI/commit), C = builtin branch (SUSFS driver).
NOVA_REPO="${NOVA_REPO:-https://github.com/SukiSU-Nova/SukiSU-Nova.git}"
NOVA_REF_A="${NOVA_REF_A:-v3.0.0}"          # latest tag = c60f21b9 (2026-11-15)
NOVA_BRANCH_C="${NOVA_BRANCH_C:-builtin}"   # builtin branch = 4bec532dd4
NOVA_REF_C="${NOVA_REF_C:-4bec532dd4}"      # SUSFS-capable driver

# SUSFS sources (official susfs4ksu via maintained mirror + owner's Nova-adapted patch)
SUSFS_REPO="${SUSFS_REPO:-https://github.com/hopez13/Susfs-Mirror.git}"
SUSFS_BRANCH="${SUSFS_BRANCH:-gki-android12-5.10}"
NOVA_SUSFS_PATCH_URL="${NOVA_SUSFS_PATCH_URL:-https://raw.githubusercontent.com/wudixxqq/xaga-kernel-build/main/susfs-patches/50_add_susfs_gki510_NOVA-BUILTIN.patch}"

# Stock kernel identity (measured from user's V14.0.6.0 TLOCNXM boot.img)
STOCK_KREL="${STOCK_KREL:-5.10.136-android12-9-00020-gc9f59ef34367-ab9585114}"
STOCK_LOCALVERSION="${STOCK_LOCALVERSION:--android12-9-00020-gc9f59ef34367-ab9585114}"

# boot.img repack
ENABLE_BOOTIMG="${ENABLE_BOOTIMG:-1}"
STOCK_BOOT_IMG="${STOCK_BOOT_IMG:-E:\迅雷云盘\xaga_images_V14.0.6.0.TLOCNXM_20230904.0000.00_13.0_cn_e2a532f260\xaga_images_V14.0.6.0.TLOCNXM_13.0\images\boot.img}"
STOCK_BOOT_SHA256="${STOCK_BOOT_SHA256:-50d5665a81014a9fbc9e22f58acd1f315cf9302ac761fb52251c29f9f98f1429}"
BOOT_CHUNKS_DIR="${BOOT_CHUNKS_DIR:-${KERNEL_DIR}/boot-stock}"
BOOT_OUT_NAME="${BOOT_OUT_NAME:-boot-xaga-nova-${VARIANT}.img}"
AK3_OUT_NAME="${AK3_OUT_NAME:-AnyKernel3-xaga-nova-${VARIANT}.zip}"
MKBOOT_TOOLS_DIR="${MKBOOT_TOOLS_DIR:-${WORK_DIR}/mkboot}"

normalize_path() {
  local p="$1"
  case "$p" in http://*|https://*) printf '%s' "$p"; return 0 ;; esac
  if [[ "$p" =~ ^([A-Za-z]):[\\/](.*)$ ]]; then
    local drive="${BASH_REMATCH[1]}" rest="${BASH_REMATCH[2]}"
    p="/$(echo "$drive" | tr 'A-Z' 'a-z')/${rest//\\//}"
  else
    p="${p//\\//}"
  fi
  printf '%s' "$p"
}

cd "${KERNEL_DIR}"
mkdir -p "${WORK_DIR}" "${ARTIFACT_DIR}"

# ----------------------------- toolchain -----------------------------------
if [[ ! -x "${CLANG_DIR}/bin/clang" ]]; then
  log "Clang not found, downloading toolchain ..."
  mkdir -p "${TOOLCHAIN_DIR}"
  git clone --depth=1 "${CLANG_REPO:-https://github.com/crdroidandroid/android_prebuilts_clang_host_linux-x86_clang-r416183b}" "${CLANG_DIR}"
fi
[[ -x "${CLANG_DIR}/bin/clang" ]] || die "clang unavailable"
export PATH="${CLANG_DIR}/bin:${PATH}"
export CLANG_TRIPLE="${CLANG_TRIPLE:-aarch64-linux-gnu-}"
export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
export ARCH=arm64 SUBARCH=arm64 LLVM=1 LLVM_IAS=1
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-xaga}" KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-xaga-arm64}"
CC_BIN="clang"; CXX_BIN="clang++"
if [[ "${ENABLE_CCACHE}" == "1" ]]; then
  command -v ccache >/dev/null 2>&1 || die "ccache requested but missing"
  CC_BIN="ccache clang"; CXX_BIN="ccache clang++"
fi

# ------------------------- Nova driver integration --------------------------
log "Fetching SukiSU-Nova driver (variant=${VARIANT}) ..."
rm -rf "${KERNEL_DIR}/KernelSU"
if [[ "$VARIANT" == "a" ]]; then
  # A: official main v3.0.0 via setup.sh (latest tag / CI version)
  SETUP_SH="${WORK_DIR}/nova_setup_a.sh"
  curl -fLSs --retry 3 "https://raw.githubusercontent.com/SukiSU-Nova/SukiSU-Nova/main/kernel/setup.sh" -o "${SETUP_SH}" || die "setup.sh download failed"
  grep -q 'setup_kernelsu' "${SETUP_SH}" || die "invalid setup.sh"
  bash "${SETUP_SH}" "${NOVA_REF_A}"
  NOVA_ACTUAL_SHA="$(git -C "${KERNEL_DIR}/KernelSU" rev-parse --short HEAD)"
  NOVA_ACTUAL_TAG="$(git -C "${KERNEL_DIR}/KernelSU" describe --tags --always 2>/dev/null || echo "${NOVA_REF_A}")"
  log "Nova driver: ${NOVA_ACTUAL_TAG} (${NOVA_ACTUAL_SHA})"
else
  # C: builtin branch driver with kernel-level SUSFS support. setup.sh from
  # builtin defaults to cloning the builtin branch; pin to NOVA_REF_C afterwards.
  SETUP_SH="${WORK_DIR}/nova_setup_c.sh"
  curl -fLSs --retry 3 "https://raw.githubusercontent.com/SukiSU-Nova/SukiSU-Nova/${NOVA_BRANCH_C}/kernel/setup.sh" -o "${SETUP_SH}" || die "builtin setup.sh download failed"
  bash "${SETUP_SH}" "${NOVA_REF_C}"
  # setup.sh checks out the ref; explicitly确认 we are on the SUSFS-capable builtin commit
  ( cd "${KERNEL_DIR}/KernelSU" && git checkout -q "${NOVA_REF_C}" )
  NOVA_ACTUAL_SHA="$(git -C "${KERNEL_DIR}/KernelSU" rev-parse --short HEAD)"
  NOVA_ACTUAL_TAG="builtin@${NOVA_REF_C}"
  # sanity: builtin Kconfig must expose SUSFS options
  grep -q "config KSU_SUSFS" "${KERNEL_DIR}/KernelSU/kernel/Kconfig" \
    || die "builtin driver missing CONFIG_KSU_SUSFS — wrong Nova ref"
  log "Nova driver: ${NOVA_ACTUAL_TAG} (${NOVA_ACTUAL_SHA})"
fi
[[ -d "${KERNEL_DIR}/KernelSU" ]] || die "KernelSU setup failed"

# Record the exact driver identity for the final report
printf 'VARIANT=%s\nNOVA_TAG=%s\nNOVA_SHA=%s\nKERNEL_NAME=%s\nDATE=%s\n' \
  "$VARIANT" "$NOVA_ACTUAL_TAG" "$NOVA_ACTUAL_SHA" "$STOCK_KREL" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > "${ARTIFACT_DIR}/build-${VARIANT}-identity.txt"

# ------------------------- kernel identity (stock name) --------------------
log "Setting kernel release name to stock: ${STOCK_KREL}"
KMAKEFILE="${KERNEL_DIR}/Makefile"
# Substitute SUBLEVEL so uname -r base becomes 5.10.136 (matching stock).
sed -i -E "s/^SUBLEVEL[[:space:]]*=.*/SUBLEVEL = 136/" "${KMAKEFILE}"

DEFCONFIG_FILE="${KERNEL_DIR}/arch/arm64/configs/${DEFCONFIG}"
[[ -f "${DEFCONFIG_FILE}" ]] || die "defconfig not found"

setcfg() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "${DEFCONFIG_FILE}"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "${DEFCONFIG_FILE}"
  elif grep -q "^# ${key} is not set" "${DEFCONFIG_FILE}"; then
    sed -i "s|^# ${key} is not set|${key}=${val}|" "${DEFCONFIG_FILE}"
  else
    echo "${key}=${val}" >> "${DEFCONFIG_FILE}"
  fi
}

# Common base (both variants): KSU on, stock localversion, KPM/LKM support.
setcfg CONFIG_KSU y
setcfg CONFIG_KPM y
setcfg CONFIG_KALLSYMS y
setcfg CONFIG_KALLSYMS_ALL y
setcfg CONFIG_LOCALVERSION "\"${STOCK_LOCALVERSION}\""
# Remove auto localversion so uname matches stock exactly
sed -i '/^CONFIG_LOCALVERSION_AUTO=/d' "${DEFCONFIG_FILE}"

if [[ "$VARIANT" == "a" ]]; then
  # A: purge legacy SUSFS dead configs (main Kconfig has none), keep clean.
  sed -i '/^CONFIG_KSU_SUSFS/d;/^CONFIG_KSU_MANUAL_HOOK/d' "${DEFCONFIG_FILE}" || true
  log "Variant A: clean official Nova config (no kernel SUSFS; userspace module)."
else
  # C: apply official susfs4ksu kernel patches adapted for Nova builtin driver.
  log "Variant C: applying SUSFS kernel patch (NOVA-BUILTIN adapted) ..."
  if [[ ! -d "${WORK_DIR}/susfs4ksu/.git" ]]; then
    git clone --depth=1 -b "${SUSFS_BRANCH}" "${SUSFS_REPO}" "${WORK_DIR}/susfs4ksu"
  fi
  # Kernel-side SUSFS core files
  cp -rf "${WORK_DIR}/susfs4ksu/kernel_patches/fs/." "${KERNEL_DIR}/fs/"
  cp -rf "${WORK_DIR}/susfs4ksu/kernel_patches/include/linux/." "${KERNEL_DIR}/include/linux/"
  # Nova-builtin-adapted integration patch (28 files: fs/mm/selinux hooks)
  SUSFS_PATCH="${WORK_DIR}/50_add_susfs_gki510_NOVA-BUILTIN.patch"
  curl -fLSs --retry 3 "${NOVA_SUSFS_PATCH_URL}" -o "${SUSFS_PATCH}" || die "SUSFS patch download failed"
  ( cd "${KERNEL_DIR}" && patch -p1 --forward < "${SUSFS_PATCH}" ) || die "SUSFS patch failed on ${STOCK_KREL} tree"
  # Full SUSFS config set (from owner's gki-susfs.config)
  for cfg in \
    "CONFIG_KSU_SUSFS=y" "CONFIG_KSU_SUSFS_SUS_PATH=y" "CONFIG_KSU_SUSFS_SUS_MOUNT=y" \
    "CONFIG_KSU_SUSFS_SUS_KSTAT=y" "CONFIG_KSU_SUSFS_SPOOF_UNAME=y" "CONFIG_KSU_SUSFS_ENABLE_LOG=y" \
    "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y" "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y" \
    "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y" "CONFIG_KSU_SUSFS_SUS_MAP=y" "CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER=y"; do
    setcfg "${cfg%%=*}" "${cfg##*=}"
  done
  log "Variant C: SUSFS config injected."
fi

sed -i 's/check_defconfig//' "${KERNEL_DIR}/build.config.gki" || true

# ----------------------------- build ---------------------------------------
log "Building (jobs=${JOBS}) ..."
rm -rf "${OUT_DIR}"; mkdir -p "${OUT_DIR}"
MAKE_ARGS=(CC="${CC_BIN}" CXX="${CXX_BIN}" LLVM=1 LLVM_IAS=1 O=out)
make "${MAKE_ARGS[@]}" "${DEFCONFIG}"
make "${MAKE_ARGS[@]}" -j"${JOBS}" \
  CONFIG_LOCALVERSION_AUTO=n \
  CONFIG_MEDIATEK_CPUFREQ_DEBUG=m CONFIG_MTK_IPI=m \
  CONFIG_MTK_TINYSYS_MCUPM_SUPPORT=m CONFIG_MTK_MBOX=m CONFIG_RPMSG_MTK=m \
  CONFIG_LTO_CLANG=y CONFIG_LTO_NONE=n CONFIG_LTO_CLANG_THIN=y CONFIG_LTO_CLANG_FULL=n \
  2>&1 | tee "${KERNEL_DIR}/kernel-${VARIANT}.log"

# ----------------------------- packaging -----------------------------------
ZIMAGE_DIR="${OUT_DIR}/arch/arm64/boot"
[[ -f "${ZIMAGE_DIR}/Image.gz" ]] || die "Image.gz not found"
STAGE_DIR="${WORK_DIR}/pack-${VARIANT}"
rm -rf "${STAGE_DIR}"; mkdir -p "${STAGE_DIR}"
cp -fp "${ZIMAGE_DIR}/Image.gz" "${STAGE_DIR}/"
cp -rp "${KERNEL_DIR}/anykernel/." "${STAGE_DIR}/"
AK3="${ARTIFACT_DIR}/${AK3_OUT_NAME}"
if command -v 7za >/dev/null 2>&1; then ( cd "${STAGE_DIR}" && 7za a -mx9 "${AK3}" * >/dev/null )
elif command -v 7z >/dev/null 2>&1; then ( cd "${STAGE_DIR}" && 7z a -mx9 "${AK3}" * >/dev/null )
else ( cd "${STAGE_DIR}" && zip -r9 "${AK3}" . ); fi
( cd "${ARTIFACT_DIR}" && sha256sum "${AK3_OUT_NAME}" > "${AK3_OUT_NAME}.sha256" )

# ------------------------- boot.img repack ---------------------------------
if [[ "${ENABLE_BOOTIMG}" == "1" ]]; then
  STOCK_BOOT_PATH="$(normalize_path "${STOCK_BOOT_IMG}")"
  if [[ ! -f "${STOCK_BOOT_PATH}" ]]; then
    chunkdir="$(normalize_path "${BOOT_CHUNKS_DIR}")"
    if [[ "$(ls "${chunkdir}"/boot.img.part-* 2>/dev/null | wc -l)" -gt 0 ]]; then
      cat "${chunkdir}"/boot.img.part-*.part > "${WORK_DIR}/boot-stock.img"
      STOCK_BOOT_PATH="${WORK_DIR}/boot-stock.img"
    fi
  fi
  [[ -f "${STOCK_BOOT_PATH}" ]] || die "no stock boot.img available"
  mkdir -p "${MKBOOT_TOOLS_DIR}/gki"; rm -f "${MKBOOT_TOOLS_DIR}/gki/__init__.py"
  for f in mkbootimg.py unpack_bootimg.py gki/generate_gki_certificate.py; do
    [[ -s "${MKBOOT_TOOLS_DIR}/$f" ]] && continue
    curl -sSL --retry 3 "https://android.googlesource.com/platform/system/tools/mkbootimg/+/refs/heads/main/$f?format=TEXT" \
      | base64 -d > "${MKBOOT_TOOLS_DIR}/$f" 2>/dev/null || true
    grep -qiE "error 404|<html|cannot find" "${MKBOOT_TOOLS_DIR}/$f" 2>/dev/null && rm -f "${MKBOOT_TOOLS_DIR}/$f"
  done
  UNPACK="${WORK_DIR}/unpack-${VARIANT}"; rm -rf "${UNPACK}"; mkdir -p "${UNPACK}"
  out="$(python3 "${MKBOOT_TOOLS_DIR}/unpack_bootimg.py" --boot_img="${STOCK_BOOT_PATH}" --out="${UNPACK}" 2>&1)" || die "boot unpack failed"
  hv="$(echo "$out" | grep -oE 'header version: [0-9]+' | grep -oE '[0-9]+' | head -1)"; hv="${hv:-4}"
  osv="$(echo "$out" | grep -oE 'os version: [0-9.]+' | grep -oE '[0-9.]+' | head -1)"; osv="${osv:-12.0.0}"
  ospl="$(echo "$out" | grep -oE 'os patch level: [0-9-]+' | grep -oE '[0-9-]+' | head -1)"
  case "$ospl" in *-*) : ;; ????) ospl="$ospl-05" ;; *) ospl="2023-07-05" ;; esac
  extra=(); [[ -f "${UNPACK}/dtb" ]] && extra+=(--dtb "${UNPACK}/dtb")
  [[ -f "${UNPACK}/ramdisk" ]] && extra+=(--ramdisk "${UNPACK}/ramdisk")
  python3 "${MKBOOT_TOOLS_DIR}/mkbootimg.py" --kernel "${ZIMAGE_DIR}/Image.gz" \
    --header_version "$hv" --os_version "$osv" --os_patch_level "$ospl" \
    "${extra[@]}" --output "${ARTIFACT_DIR}/${BOOT_OUT_NAME}" || die "mkbootimg failed"
  ( cd "${ARTIFACT_DIR}" && sha256sum "${BOOT_OUT_NAME}" > "${BOOT_OUT_NAME}.sha256" )
  log "boot.img: ${ARTIFACT_DIR}/${BOOT_OUT_NAME} ($(du -h "${ARTIFACT_DIR}/${BOOT_OUT_NAME}" | cut -f1))"
fi

log "=== variant ${VARIANT} complete ==="
log "Nova: ${NOVA_ACTUAL_TAG} (${NOVA_ACTUAL_SHA}) | Kernel: ${STOCK_KREL}"
ls -la "${ARTIFACT_DIR}"
