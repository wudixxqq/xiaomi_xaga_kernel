#!/usr/bin/env bash
# ============================================================================
# XAGA Kernel CI build script
# Target : Poco X4 GT / Redmi K50i / Note 11T Pro (XAGA / MT6895, 5.10 GKI)
# Based on buildebug.sh, reworked for non-interactive CI:
#   - no interactive menuconfig
#   - all paths are env-driven (no hardcoded /clang)
#   - idempotent defconfig injection
#   - strict patch handling (set STRICT_PATCH=0 to tolerate failures)
# Usage : bash scripts/build_ci.sh
# ============================================================================
set -euo pipefail

log()  { echo "[build] $*"; }
die()  { echo "[build] ERROR: $*" >&2; exit 1; }

# ----------------------------- configuration -------------------------------
KERNEL_DIR="${KERNEL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-${KERNEL_DIR}/../toolchain}"   # parent of kernel, holds clang/
WORK_DIR="${WORK_DIR:-${KERNEL_DIR}/.ci}"                      # third-party repos + patches
ARTIFACT_DIR="${ARTIFACT_DIR:-${KERNEL_DIR}/artifacts}"
OUT_DIR="${OUT_DIR:-${KERNEL_DIR}/out}"

CLANG_DIR="${CLANG_DIR:-${TOOLCHAIN_DIR}/clang}"
DEFCONFIG="${DEFCONFIG:-gki_defconfig}"
JOBS="${JOBS:-$(nproc --all)}"
LOCALVERSION="${LOCALVERSION:--Android12-9-v$(date +%Y%m%d-%H)}"

# Feature toggles (set to 0 / false to disable)
ENABLE_KSU="${ENABLE_KSU:-1}"        # SukiSU-Ultra (KernelSU) + SUSFS + SukiSU_patch
ENABLE_CCACHE="${ENABLE_CCACHE:-1}"
STRICT_PATCH="${STRICT_PATCH:-1}"    # 1 = abort on patch failure; 0 = log & continue

KSU_SETUP_URL="${KSU_SETUP_URL:-https://raw.githubusercontent.com/ShirkNeko/SukiSU-Ultra/main/kernel/setup.sh}"
KSU_BRANCH="${KSU_BRANCH:-susfs-main}"
SUSFS_REPO="${SUSFS_REPO:-https://github.com/shirkneko/susfs4ksu.git}"
SUSFS_BRANCH="${SUSFS_BRANCH:-gki-android12-5.10}"
SUKISU_PATCH_REPO="${SUKISU_PATCH_REPO:-https://github.com/ShirkNeko/SukiSU_patch.git}"
CLANG_REPO="${CLANG_REPO:-https://github.com/crdroidandroid/android_prebuilts_clang_host_linux-x86_clang-r416183b}"

cd "${KERNEL_DIR}"
mkdir -p "${WORK_DIR}" "${ARTIFACT_DIR}"

# ----------------------------- toolchain -----------------------------------
if [[ ! -x "${CLANG_DIR}/bin/clang" ]]; then
  log "Clang not found at ${CLANG_DIR}, downloading toolchain ..."
  mkdir -p "${TOOLCHAIN_DIR}"
  git clone --depth=1 "${CLANG_REPO}" "${CLANG_DIR}"
fi
[[ -x "${CLANG_DIR}/bin/clang" ]] || die "clang unavailable at ${CLANG_DIR}/bin/clang"

export PATH="${CLANG_DIR}/bin:${PATH}"
export CLANG_TRIPLE="${CLANG_TRIPLE:-aarch64-linux-gnu-}"
export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
export ARCH=arm64
export SUBARCH=arm64
export LLVM=1
export LLVM_IAS=1
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-xaga-ci}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-xaga-arm64}"

CC_BIN="clang"
CXX_BIN="clang++"
if [[ "${ENABLE_CCACHE}" == "1" || "${ENABLE_CCACHE}" == "true" ]]; then
  command -v ccache >/dev/null 2>&1 || die "ccache requested but not installed"
  CC_BIN="ccache clang"
  CXX_BIN="ccache clang++"
fi

# ------------------------- KernelSU / SUSFS --------------------------------
apply_patch() {
  local patch_file="$1" shift_count="${2:--p1}" fuzz="${3:-}"
  [[ -f "${patch_file}" ]] || die "patch not found: ${patch_file}"
  if [[ -n "${fuzz}" ]]; then
    patch ${shift_count} -F "${fuzz}" --forward < "${patch_file}" && return 0
  else
    patch ${shift_count} --forward < "${patch_file}" && return 0
  fi
  if [[ "${STRICT_PATCH}" == "1" ]]; then
    die "patch failed: ${patch_file} (set STRICT_PATCH=0 to continue)"
  else
    log "WARNING: patch failed but STRICT_PATCH=0, continuing: ${patch_file}"
  fi
}

if [[ "${ENABLE_KSU}" == "1" || "${ENABLE_KSU}" == "true" ]]; then
  log "Setting up SukiSU-Ultra (${KSU_BRANCH}) ..."
  rm -rf "${KERNEL_DIR}/KernelSU"
  curl -LSs "${KSU_SETUP_URL}" | bash -s "${KSU_BRANCH}"
  [[ -d "${KERNEL_DIR}/KernelSU" ]] || die "KernelSU setup failed"

  KSU_VERSION=$(( $(git -C "${KERNEL_DIR}/KernelSU" rev-list --count main) + 10606 ))
  log "KSU_VERSION=${KSU_VERSION}"
  sed -i "s/DKSU_VERSION=12800/DKSU_VERSION=${KSU_VERSION}/" \
    "${KERNEL_DIR}/KernelSU/kernel/Makefile"

  log "Fetching susfs4ksu (${SUSFS_BRANCH}) and SukiSU_patch ..."
  if [[ ! -d "${WORK_DIR}/susfs4ksu/.git" ]]; then
    git clone --depth=1 -b "${SUSFS_BRANCH}" "${SUSFS_REPO}" "${WORK_DIR}/susfs4ksu"
  fi
  if [[ ! -d "${WORK_DIR}/SukiSU_patch/.git" ]]; then
    git clone --depth=1 "${SUKISU_PATCH_REPO}" "${WORK_DIR}/SukiSU_patch"
  fi

  log "Applying SUSFS / hook patches ..."
  cp -f "${WORK_DIR}/susfs4ksu/kernel_patches/50_add_susfs_in_gki-android12-5.10.patch" "${KERNEL_DIR}/"
  cp -f "${WORK_DIR}/SukiSU_patch/hooks/new_hooks.patch" "${KERNEL_DIR}/"
  cp -rf "${WORK_DIR}"/susfs4ksu/kernel_patches/fs/* "${KERNEL_DIR}/fs/"
  cp -rf "${WORK_DIR}"/susfs4ksu/kernel_patches/include/linux/* "${KERNEL_DIR}/include/linux/"

  apply_patch "${KERNEL_DIR}/50_add_susfs_in_gki-android12-5.10.patch" -p1

  cp -f "${WORK_DIR}/SukiSU_patch/69_hide_stuff.patch" "${KERNEL_DIR}/"
  apply_patch "${KERNEL_DIR}/69_hide_stuff.patch" -p1 3
  apply_patch "${KERNEL_DIR}/new_hooks.patch" -p1

  log "Injecting CONFIG_KSU_* options into ${DEFCONFIG} ..."
  DEFCONFIG_FILE="${KERNEL_DIR}/arch/arm64/configs/${DEFCONFIG}"
  [[ -f "${DEFCONFIG_FILE}" ]] || die "defconfig not found: ${DEFCONFIG_FILE}"
  declare -A KSU_CONFIGS=(
    [CONFIG_KSU]=y
    [CONFIG_KSU_SUSFS_SUS_SU]=n
    [CONFIG_KSU_MANUAL_HOOK]=y
    [CONFIG_KSU_SUSFS]=y
    [CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT]=y
    [CONFIG_KSU_SUSFS_SUS_PATH]=y
    [CONFIG_KSU_SUSFS_SUS_MOUNT]=y
    [CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT]=y
    [CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT]=y
    [CONFIG_KSU_SUSFS_SUS_KSTAT]=y
    [CONFIG_KSU_SUSFS_SUS_OVERLAYFS]=n
    [CONFIG_KSU_SUSFS_TRY_UMOUNT]=y
    [CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT]=y
    [CONFIG_KSU_SUSFS_SPOOF_UNAME]=y
    [CONFIG_KSU_SUSFS_ENABLE_LOG]=y
    [CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS]=y
    [CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG]=y
    [CONFIG_KSU_SUSFS_OPEN_REDIRECT]=y
  )
  for key in "${!KSU_CONFIGS[@]}"; do
    val="${KSU_CONFIGS[$key]}"
    if grep -q "^${key}=" "${DEFCONFIG_FILE}"; then
      sed -i "s|^${key}=.*|${key}=${val}|" "${DEFCONFIG_FILE}"
    else
      echo "${key}=${val}" >> "${DEFCONFIG_FILE}"
    fi
  done
else
  log "ENABLE_KSU=0: skipping KernelSU / SUSFS integration"
fi

# Disable the defconfig consistency check that conflicts with runtime patches
sed -i 's/check_defconfig//' "${KERNEL_DIR}/build.config.gki" || true

# ----------------------------- build ---------------------------------------
log "Building ${DEFCONFIG} with ${JOBS} jobs ..."
rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"
MAKE_ARGS=(CC="${CC_BIN}" CXX="${CXX_BIN}" LLVM=1 LLVM_IAS=1 O=out)

make "${MAKE_ARGS[@]}" "${DEFCONFIG}"

make "${MAKE_ARGS[@]}" -j"${JOBS}" \
  LOCALVERSION="${LOCALVERSION}" \
  CONFIG_LOCALVERSION_AUTO=n \
  CONFIG_MEDIATEK_CPUFREQ_DEBUG=m \
  CONFIG_MTK_IPI=m \
  CONFIG_MTK_TINYSYS_MCUPM_SUPPORT=m \
  CONFIG_MTK_MBOX=m \
  CONFIG_RPMSG_MTK=m \
  CONFIG_LTO_CLANG=y \
  CONFIG_LTO_NONE=n \
  CONFIG_LTO_CLANG_THIN=y \
  CONFIG_LTO_CLANG_FULL=n \
  2>&1 | tee "${KERNEL_DIR}/kernel.log"

# ----------------------------- packaging -----------------------------------
ZIMAGE_DIR="${OUT_DIR}/arch/arm64/boot"
[[ -f "${ZIMAGE_DIR}/Image.gz" ]] || die "Image.gz not found in ${ZIMAGE_DIR}"

KVER="$(grep -m1 '^# Linux/' "${OUT_DIR}/.config" | awk '{print $3}')"
[[ -n "${KVER}" ]] || KVER="5.10.66"
TAG="$(date +%Y%m%d-%H)"
PKG_NAME="${PKG_PREFIX:-Android12}-${KVER}-v${TAG}.zip"

STAGE_DIR="${WORK_DIR}/pack"
rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}"
cp -fp "${ZIMAGE_DIR}/Image.gz" "${STAGE_DIR}/"
cp -rp "${KERNEL_DIR}/anykernel/." "${STAGE_DIR}/"

FINAL_ZIP="${ARTIFACT_DIR}/${PKG_NAME}"
if command -v 7za >/dev/null 2>&1; then
  ( cd "${STAGE_DIR}" && 7za a -mx9 "${FINAL_ZIP}" * >/dev/null )
elif command -v 7z >/dev/null 2>&1; then
  ( cd "${STAGE_DIR}" && 7z a -mx9 "${FINAL_ZIP}" * >/dev/null )
else
  ( cd "${STAGE_DIR}" && zip -r9 "${FINAL_ZIP}" . )
fi
[[ -f "${FINAL_ZIP}" ]] || die "packaging failed"

# Checksums + artifact manifest
( cd "${ARTIFACT_DIR}" && sha256sum "${PKG_NAME}" > "${PKG_NAME}.sha256" )
printf '%s\n' "${PKG_NAME}" > "${ARTIFACT_DIR}/artifact-name.txt"

log "Build complete."
log "Kernel version : ${KVER}"
log "Artifact       : ${FINAL_ZIP}"
log "Size           : $(du -h "${FINAL_ZIP}" | cut -f1)"
