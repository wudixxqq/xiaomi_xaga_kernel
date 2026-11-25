# xaga HyperOS2 GKI 自构建方案

基于 ESK v4.0.1 xaga ksu-susfs 的公开源码构成，提供可复现的 GitHub Actions 构建流水线。

## 组成与固定版本

| 组件 | 来源 | 固定版本 |
|---|---|---|
| 内核源码 | `ESK-Project/android_kernel_xiaomi_mt6895` | `5bf560ebb55b`（5.10.274，android12-5.10 GKI） |
| 模块清单 | `ESK-Project/esk_builder` | `d2ebf28b46eb`（`targets/xaga/modules.load*`） |
| AnyKernel3 | `ESK-Project/AnyKernel3` | `4a448ee5019f`（分支 `xaga`） |
| 工具链 | `bachnxuan/aosp_clang_mirror` | `clang-r614150`（Clang 23.0.1） |
| SUSFS | `gitlab.com/simonpunk/susfs4ksu` | 分支 `gki-android12-5.10` |
| Root 驱动 | BakaSU / SukiSU-Nova / FinaSU | 默认见 `config.env` 与 `build.sh` case |

BakaSU 默认解析 `main` 的最新 commit 并写入 `build.env`，兼顾“最新 CI”与可复现。

## 使用

### 自动构建

推送到 `hyperos2-gki-ci` 分支并修改 `gki-build/**` 或工作流文件会触发默认 `bakasu` 构建。

### 手动选择变体

Actions → “Build xaga GKI” → Run workflow：

- `root_variant`: `bakasu`（默认）/ `sukisu` / `finasu`
- `root_ref`: 留空使用默认；BakaSU 留空即最新 main
- `kernel_ref` / `susfs_ref`: 留空使用固定版本
- `enable_susfs` / `enable_modules`: 调试时可关闭，正常刷机请保持开启

### 本地构建

```bash
cd gki-build
ROOT_VARIANT=bakasu JOBS=8 bash build.sh
```

需要在 Linux 环境；Windows 请用 WSL2。

## 源码拉取与补丁顺序

1. `clone_pinned` 按 commit/分支浅克隆内核、builder、AK3、SUSFS。
2. 下载对应变体的 `kernel/setup.sh` 注入 Root 驱动，并校验实际 checkout commit。
3. 应用 `susfs4ksu` 的 `50_add_susfs_in_gki-android12-5.10.patch`，复制 `fs/*` 与 `include/linux/*`。
4. 兼容处理 `VMA_PAD_START`；必要时注入 `CONFIG_KSU_SUSFS*` Kconfig。
5. SukiSU 变体应用仓库内已移植的 `patches/novasus_10_enable_susfs_for_ksu.patch`。
6. FinaSU 变体校验原生 SUSFS 层并注入 `kernel/reboot.c` 派发钩子。
7. 合并 `gki_defconfig` + `vendor/xiaomi_mt6895.config` + `vendor/xaga.config`。
8. 强制 ThinLTO + CFI + MODVERSIONS，应用变体配置，`olddefconfig` 后做硬门禁校验。

## 构建参数（ABI 硬门禁）

沿用本仓库 SUSFS 适配经验：

- `CONFIG_LTO_CLANG_THIN=y`、`CONFIG_CFI_CLANG=y`、`CONFIG_MODVERSIONS=y` 必须为真。
- 禁用 Full LTO（CI 内存不足），但不能让 CFI 被静默关闭。
- 编译后校验镜像含 `__cfi_check` 且 `System.map` 也有该符号。
- 校验 KernelSU/SUSFS 字符串计数，避免“编译成功但没打进去”。
- 校验 banner 与 `kernelrelease` 一致；如需 OEM 精确时间戳，设置 `KBUILD_BUILD_TIMESTAMP` 与 `KERNEL_LOCALVERSION`。

## 产物

`gki-build/out/`：

- `<PACKAGE_NAME>-AnyKernel3.zip`：可刷入的 AK3（含 `Image.zst`、校验和、`module.tar.xz`、`kernel.config`）
- `SHA256SUMS.txt`
- `build.env`：所有固定版本与实际 commit、包名、SHA256
- `kernel.config.txt` / `kernel-banner.txt` / `symbol-counts.txt` / `susfs-hooked-files.txt`
- `build.log` / `console.log`

命名格式：

```
ESKXAGA-xaga-5.10.274-<VARIANT>[-SUSFS]-<kernel_sha12>-AnyKernel3.zip
```

工作流同时上传 Actions artifact 并发布 Release asset，Release 可直接下载。

## 缓存与失败处理

- ccache：按变体 + commit 命名 key，并有前缀 restore-key。
- Clang：按固定 tag 缓存，避免每次下载 1.1GB 归档。
- `set -Eeuo pipefail` + ERR trap 记录失败阶段/命令行。
- 关键步骤硬失败；失败时上传 `gki-build/out/**` 诊断包。
- 并发组阻止同一分支同类构建互相覆盖缓存。

## 扩展新 Root 方案

在 `build.sh` 的 case 中新增分支，至少提供：

1. `ROOT_REPO` / `SETUP_URL` / `DRIVER_DIR` / 默认 `ROOT_REF`
2. 该驱动的 SUSFS 集成方式（原生 Kconfig、额外 patch 或 Kconfig 注入）
3. 需要的 `EXTRA_MAKE` 变量和硬门禁

其余源码拉取、模块打包、产物上传流程无需改动。
