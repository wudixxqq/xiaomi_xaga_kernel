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
warn() { echo "[build] WARNING: $*" >&2; }
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

# NOTE (2026-11): upstream renamed/moved - ShirkNeko/SukiSU-Ultra -> SukiSU-Nova/SukiSU-Nova,
# shirkneko/susfs4ksu was deleted, ShirkNeko/SukiSU_patch -> SukiSU-Nova/SukiSU_patch.
KSU_SETUP_URL="${KSU_SETUP_URL:-https://raw.githubusercontent.com/SukiSU-Nova/SukiSU-Nova/main/kernel/setup.sh}"
KSU_REF="${KSU_REF:-}"                 # empty = latest tag; or a tag/commit like v3.0.0
SUSFS_REPO="${SUSFS_REPO:-https://github.com/hopez13/Susfs-Mirror.git}"
SUSFS_BRANCH="${SUSFS_BRANCH:-gki-android12-5.10}"
SUKISU_PATCH_REPO="${SUKISU_PATCH_REPO:-https://github.com/SukiSU-Nova/SukiSU_patch.git}"
# Hook patch was renamed upstream: new_hooks.patch -> scope_min_manual_hooks_v1.6.patch
HOOK_PATCH="${HOOK_PATCH:-scope_min_manual_hooks_v1.6.patch}"
CLANG_REPO="${CLANG_REPO:-https://github.com/crdroidandroid/android_prebuilts_clang_host_linux-x86_clang-r416183b}"

# ---- boot.img repack (direct deliverable) ----------------------------------
ENABLE_BOOTIMG="${ENABLE_BOOTIMG:-1}"   # 1 = also rebuild a flashable boot.img
# Stock boot.img source. Accepts a Windows path (forward or back slashes), a
# POSIX path, or an https URL. Backslashes / Chinese chars are normalized below.
STOCK_BOOT_IMG="${STOCK_BOOT_IMG:-E:\迅雷云盘\xaga_images_V14.0.6.0.TLOCNXM_20230904.0000.00_13.0_cn_e2a532f260\xaga_images_V14.0.6.0.TLOCNXM_13.0\images\boot.img}"
STOCK_BOOT_SHA256="${STOCK_BOOT_SHA256:-50d5665a81014a9fbc9e22f58acd1f315cf9302ac761fb52251c29f9f98f1429}"
BOOT_CHUNKS_DIR="${BOOT_CHUNKS_DIR:-${KERNEL_DIR}/boot-stock}"   # optional boot.img.part-* chunks
BOOT_OUT_NAME="${BOOT_OUT_NAME:-boot-xaga-KSU-SUSFS.img}"
MKBOOT_TOOLS_DIR="${MKBOOT_TOOLS_DIR:-${WORK_DIR}/mkboot}"

# Normalize a Windows path to something bash / python can open on MSYS/Git-Bash:
#   E:\dir\文件\boot.img -> /e/dir/文件/boot.img
# Leaves POSIX paths and http(s) URLs untouched.
normalize_path() {
  local p="$1"
  case "$p" in
    http://*|https://*) printf '%s' "$p"; return 0 ;;
  esac
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
  log "Setting up SukiSU-Nova (KernelSU) ..."
  rm -rf "${KERNEL_DIR}/KernelSU"
  # Download setup.sh to a file first so an HTTP error is never piped into bash
  # (the old `curl | bash -s susfs-main` silently executed a 404 body and exited 127).
  SETUP_SH="${WORK_DIR}/sukisu_setup.sh"
  curl -fLSs "${KSU_SETUP_URL}" -o "${SETUP_SH}" || die "failed to download setup.sh from ${KSU_SETUP_URL}"
  grep -q 'setup_kernelsu' "${SETUP_SH}" || die "setup.sh looks invalid (not a SukiSU setup script)"
  if [[ -n "${KSU_REF}" ]]; then
    bash "${SETUP_SH}" "${KSU_REF}"
  else
    bash "${SETUP_SH}"          # no args -> checks out latest stable tag
  fi
  [[ -d "${KERNEL_DIR}/KernelSU" ]] || die "KernelSU setup failed"

  KSU_VERSION=$(( $(git -C "${KERNEL_DIR}/KernelSU" rev-list --count HEAD) + 10606 ))
  log "KSU_VERSION=${KSU_VERSION}"
  sed -i "s/DKSU_VERSION=12800/DKSU_VERSION=${KSU_VERSION}/" \
    "${KERNEL_DIR}/KernelSU/kernel/Makefile" || log "WARNING: DKSU_VERSION pattern not found"

  log "Fetching SUSFS mirror (${SUSFS_BRANCH}) and SukiSU_patch ..."
  if [[ ! -d "${WORK_DIR}/susfs4ksu/.git" ]]; then
    git clone --depth=1 -b "${SUSFS_BRANCH}" "${SUSFS_REPO}" "${WORK_DIR}/susfs4ksu"
  fi
  if [[ ! -d "${WORK_DIR}/SukiSU_patch/.git" ]]; then
    git clone --depth=1 "${SUKISU_PATCH_REPO}" "${WORK_DIR}/SukiSU_patch"
  fi

  log "Applying SUSFS / hook patches ..."
  SUSFS_PATCH="${WORK_DIR}/susfs4ksu/kernel_patches/50_add_susfs_in_gki-android12-5.10.patch"
  [[ -f "${SUSFS_PATCH}" ]] || die "SUSFS patch not found: ${SUSFS_PATCH}"
  cp -f "${SUSFS_PATCH}" "${KERNEL_DIR}/"
  cp -rf "${WORK_DIR}"/susfs4ksu/kernel_patches/fs/* "${KERNEL_DIR}/fs/"
  cp -rf "${WORK_DIR}"/susfs4ksu/kernel_patches/include/linux/* "${KERNEL_DIR}/include/linux/"

  apply_patch "${KERNEL_DIR}/50_add_susfs_in_gki-android12-5.10.patch" -p1

  cp -f "${WORK_DIR}/SukiSU_patch/69_hide_stuff.patch" "${KERNEL_DIR}/"
  apply_patch "${KERNEL_DIR}/69_hide_stuff.patch" -p1 3

  # Hook patch: prefer configured name, fall back to the legacy new_hooks.patch
  HOOK_SRC="${WORK_DIR}/SukiSU_patch/hooks/${HOOK_PATCH}"
  if [[ ! -f "${HOOK_SRC}" ]]; then
    HOOK_SRC="${WORK_DIR}/SukiSU_patch/hooks/new_hooks.patch"
  fi
  [[ -f "${HOOK_SRC}" ]] || die "no hook patch found in SukiSU_patch/hooks/"
  cp -f "${HOOK_SRC}" "${KERNEL_DIR}/hooks.patch"
  apply_patch "${KERNEL_DIR}/hooks.patch" -p1

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

# ------------------------- boot.img support ---------------------------------
STOCK_BOOT_PATH="$(normalize_path "${STOCK_BOOT_IMG}")"

fetch_mkboot_tools() {
  mkdir -p "${MKBOOT_TOOLS_DIR}/gki"
  rm -f "${MKBOOT_TOOLS_DIR}/gki/__init__.py"
  local f
  for f in mkbootimg.py unpack_bootimg.py gki/generate_gki_certificate.py; do
    local dest="${MKBOOT_TOOLS_DIR}/$f"
    [[ -s "$dest" ]] && continue
    curl -sSL --retry 3 "${MKBOOT_BASE_URL:-https://android.googlesource.com/platform/system/tools/mkbootimg/+/refs/heads/main/$f?format=TEXT}" \
      | base64 -d > "$dest" 2>/dev/null || true
    grep -qiE "error 404|<html|cannot find" "$dest" 2>/dev/null && { rm -f "$dest"; }
  done
  [[ -s "${MKBOOT_TOOLS_DIR}/mkbootimg.py" && -s "${MKBOOT_TOOLS_DIR}/unpack_bootimg.py" ]] \
    || die "cannot fetch mkbootimg tools"
}

prepare_stock_boot() {
  # 1) direct file / URL
  if [[ "${STOCK_BOOT_PATH}" == http://* || "${STOCK_BOOT_PATH}" == https://* ]]; then
    [[ -f "${WORK_DIR}/boot-stock.img" ]] || {
      log "Downloading stock boot.img from ${STOCK_BOOT_PATH} ..."
      curl -fL --retry 3 "${STOCK_BOOT_PATH}" -o "${WORK_DIR}/boot-stock.img" || die "stock boot download failed"
    }
    STOCK_BOOT_PATH="${WORK_DIR}/boot-stock.img"
  elif [[ -f "${STOCK_BOOT_PATH}" ]]; then
    log "Using stock boot.img: ${STOCK_BOOT_PATH}"
  else
    # 2) reassemble from 16MB chunks (GitHub cannot store a 64MB blob via API)
    local chunkdir chunks=0 c
    chunkdir="$(normalize_path "${BOOT_CHUNKS_DIR}")"
    chunks=$(ls "${chunkdir}"/boot.img.part-* 2>/dev/null | wc -l) || chunks=0
    if [[ "${chunks}" -gt 0 ]]; then
      log "Reassembling stock boot.img from ${chunks} chunks in ${chunkdir} ..."
      cat "${chunkdir}"/boot.img.part-* > "${WORK_DIR}/boot-stock.img"
      STOCK_BOOT_PATH="${WORK_DIR}/boot-stock.img"
    else
      warn "stock boot.img not found at ${STOCK_BOOT_PATH} and no chunks in ${chunkdir}"
      return 1
    fi
  fi
  if [[ -n "${STOCK_BOOT_SHA256}" ]]; then
    local actual; actual="$(sha256sum "${STOCK_BOOT_PATH}" | awk '{print $1}')"
    if [[ "${actual}" != "${STOCK_BOOT_SHA256}" ]]; then
      warn "stock boot.img sha256 mismatch (got ${actual}, expected ${STOCK_BOOT_SHA256})"
      warn "continuing anyway - set STOCK_BOOT_SHA256='' to silence"
    else
      log "stock boot.img sha256 verified"
    fi
  fi
  return 0
}

repack_boot_img() {
  [[ "${ENABLE_BOOTIMG}" == "1" || "${ENABLE_BOOTIMG}" == "true" ]] || return 0
  prepare_stock_boot || { warn "boot.img repack skipped: no stock boot"; return 0; }
  fetch_mkboot_tools

  local unpack="${WORK_DIR}/unpacked-boot" ksrc="${ZIMAGE_DIR}/Image.gz"
  [[ -f "${ksrc}" ]] || { warn "Image.gz missing, cannot repack boot.img"; return 0; }
  rm -rf "${unpack}"; mkdir -p "${unpack}"
  log "Unpacking stock boot.img header ..."
  local out
  out="$(python3 "${MKBOOT_TOOLS_DIR}/unpack_bootimg.py" --boot_img="${STOCK_BOOT_PATH}" --out="${unpack}" 2>&1)" || die "boot unpack failed"
  echo "${out}" | head -12

  local hv osv ospl cmdline
  hv="$(echo "${out}"   | grep -oE 'boot image header version: [0-9]+' | grep -oE '[0-9]+' | head -1)"
  osv="$(echo "${out}"   | grep -oE 'os version: [0-9.]+'              | grep -oE '[0-9.]+' | head -1)"
  ospl="$(echo "${out}"  | grep -oE 'os patch level: [0-9-]+'          | grep -oE '[0-9-]+' | head -1)"
  cmdline="$(echo "${out}" | grep -oE 'command line args:.*' | sed 's/^command line args: *//')"
  hv="${hv:-4}"; osv="${osv:-12.0.0}"
  case "${ospl}" in *-*) : ;; ????) ospl="${ospl}-05" ;; *) ospl="2023-07-05" ;; esac

  local -a extra=()
  [[ -f "${unpack}/dtb" ]]     && extra+=(--dtb "${unpack}/dtb")
  [[ -f "${unpack}/ramdisk" ]] && extra+=(--ramdisk "${unpack}/ramdisk")
  [[ -n "${cmdline}" ]]        && extra+=(--cmdline "${cmdline}")

  local boot_out="${ARTIFACT_DIR}/${BOOT_OUT_NAME}"
  python3 "${MKBOOT_TOOLS_DIR}/mkbootimg.py" \
    --kernel "${ksrc}" --header_version "${hv}" \
    --os_version "${osv}" --os_patch_level "${ospl}" \
    "${extra[@]}" --output "${boot_out}" || die "mkbootimg failed"
  ( cd "${ARTIFACT_DIR}" && sha256sum "${BOOT_OUT_NAME}" > "${BOOT_OUT_NAME}.sha256" )
  log "boot.img ready: ${boot_out} ($(du -h "${boot_out}" | cut -f1))"
  printf '%s\n' "${BOOT_OUT_NAME}" > "${ARTIFACT_DIR}/boot-name.txt"
}

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

# ------------------- direct boot.img deliverable ----------------------------
repack_boot_img

log "Build complete."
log "Kernel version : ${KVER}"
log "AK3 artifact   : ${FINAL_ZIP}"
log "Size           : $(du -h "${FINAL_ZIP}" | cut -f1)"
if [[ -f "${ARTIFACT_DIR}/${BOOT_OUT_NAME}" ]]; then
  log "BOOT artifact  : ${ARTIFACT_DIR}/${BOOT_OUT_NAME}"
  log "BOOT size      : $(du -h "${ARTIFACT_DIR}/${BOOT_OUT_NAME}" | cut -f1)"
fi
