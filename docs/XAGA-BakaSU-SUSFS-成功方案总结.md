# XAGA (POCO X4 GT / Redmi Note 11T Pro) 内核构建成功方案总结

> BakaSU (SukiSU-Nova 系) builtin + 内核态 SUSFS + vendor 模块 ABI 兼容
> 最终交付：CI run `43979064199`（success）· commit `b5a0c20d2f0d` · 2026-11-16/17
> 真机验证：成功开机，386 个 vendor 模块全部加载，SUSFS v2.4.0 正常工作

---

## 一、最终成果

| 项目 | 值 |
|---|---|
| 设备 | POCO X4 GT / Redmi Note 11T Pro / Redmi K50i（xaga，MT6895 天玑 8100） |
| 内核源码 | `aosp-mirror/kernel_common` 分支 `android12-5.10`，固定 `81e7418c6466`（5.10.136 基线） |
| 内核名 | `5.10.136-android12-9-00020-gc9f59ef34367-ab9585114`（与原厂 V14.0.6.0 完全一致） |
| root 方案 | BakaSU builtin（驱动 commit `5d6d1843c893`，main 最新可用） |
| 隐藏方案 | SUSFS v2.4.0 内核态（15 个 fs 源文件含 hook，内核内 142 处 susfs 符号） |
| LTO / CFI | `LTO_CLANG_THIN=y` + `CFI_CLANG=y`（**vendor 模块 ABI 兼容的关键**） |
| boot.img | 64MiB（与原厂等长，sha256 `074fe3208dc3...5ef10`） |
| AK3 包 | `AnyKernel3-BakaSU-SUSFS-xaga.zip`（sha256 `19d89b2aa0b7...5e59`） |

构建脚本：`scripts/build_bakasu.sh`；workflow：`.github/workflows/build-bakasu-susfs.yml`。

---

## 二、已验证的构建配方（核心）

```
源码基线   kernel_common @ android12-5.10 @ 81e7418c6466（对应原厂 5.10.136 / 2022-11 补丁级）
工具链     LineageOS clang r416183b（Android clang 12.0.5 + LLD，与原厂一致）
defconfig  gki_defconfig
LTO/CFI    make 命令行强制注入（照 GKI 官方 KMI 约束）：
           CONFIG_LTO_CLANG=y CONFIG_LTO_NONE=n
           CONFIG_LTO_CLANG_THIN=y CONFIG_LTO_CLANG_FULL=n
           （Full LTO 会在 16GB CI runner OOM，ThinLTO 与 GKI 官方一致）
驱动注入   BakaSU 仓库整树拷入 drivers/kernelsu，CONFIG_KSU=y + SUSFS 全套 CONFIG
SUSFS 注入 susfs4ksu gki-android12-5.10 补丁（gitlab simonpunk 官方），
           fs/* + include/linux/* 全量覆盖 + VMA_PAD_START 兼容宏 backport
内核名     CONFIG_LOCALVERSION="" + CONFIG_MODULE_SCMVERSION=y + 空本地版本
           → kernelrelease 精确等于原厂串
boot.img   magiskboot 用原厂 boot.img 换入新 Image.gz，truncate 回 64MiB 原厂分区长度
AK3 打包   python3 zipfile 写入 Unix 权限位（0755/0644），不用 zip/7z（Windows 会丢权限位）
```

---

## 三、踩坑全记录（五个坑 + 两个门禁误报，全部修复并固化）

### 坑 1：上游仓库改名/删除
SukiSU 生态仓库不稳定（ShirkNeko/SukiSU-Ultra 改名、shirkneko/susfs4ksu 删除、补丁文件改名）。
**对策**：所有外部仓库 URL/commit 全部参数化并固定 commit；镜像回退链（hopez13/Susfs-Mirror 等）。

### 坑 2：BakaSU 驱动版本引入链接 bug
`252b1520` 在 ThinLTO 下 `selinux_hide_init_setxattr` 链接失败（static 函数被内化）。
**对策**：回退到 `5d6d1843c893`（其 #659 已修复），真机验证通过。

### 坑 3：AK3 zip 权限位丢失（「刷写失败」）
Windows 上用 zip/7z 打包，包内所有文件权限变 0666，recovery 解压后
`update-binary`/`tools/busybox`/`tools/magiskboot` 无法执行，安装器直接中止。
**对策**：一律用 python3 zipfile 设置 `external_attr`（0755/0644）。

### 坑 4：CFI 被静默丢弃 → 无限重启（**最关键的坑**）
为了绕坑 2 曾 `-d CFI_CLANG` + `-e LTO_NONE`，驱动回退后忘恢复。链条：

```
CFI off → GKI 5.10 struct module 少了 cfi_check 字段 → module_layout 符号 CRC 变化
→ 原厂 vendor 模块（按 CFI=y 构建）全部 "disagrees about version of symbol module_layout"
→ UFS 等存储驱动起不来 → boot_a/super/vbmeta 分区 10s 不出现
→ init 退出 → Kernel panic: Attempted to kill init! → 无限重启
```

诊断方法：pstore（`/sys/fs/pstore/console-ramoops-0`，需 root）。注意 MTK 的
`dmesg-ramoops-0.enc.z` 是加密的不可读，只有 `console-ramoops-0` 有用。

**修复**：恢复 CFI/ThinLTO 时又发现 gki_defconfig 默认是 `LTO_CLANG_FULL=y`
（16GB runner 会 OOM），仅 `-d LTO_CLANG_FULL` 会让 LTO 三选一落回 `LTO_NONE=y`，
CFI（依赖 LTO）**被 kconfig 静默丢弃**。最终照 GKI 官方/run#4 已验证配方在
make 命令行注入四个 CONFIG 变量 + `scripts/config` 同步设置，双保险。

### 坑 5：CI 上 REPO_ROOT 解析错误（AK3 打包必挂）
workflow 用相对路径 `bash scripts/build_bakasu.sh` 调用，脚本先 `cd $WORK/common`
（内核树里也有 `scripts/` 目录），之后才用 `BASH_SOURCE` 算仓库根 → 解析进内核树。
**对策**：脚本顶部（任何 `cd` 之前）固化 `SCRIPT_DIR/REPO_ROOT` 为绝对路径，
WORK/ARTIFACTS/STOCK_CHUNKS_DIR 全部引用 `$REPO_ROOT`。

### 门禁误报 1：banner 匹配
ThinLTO 重排 `.rodata`，`grep -m1 'Linux version'` 会先命中格式串
`Linux version %s (%s)`。**对策**：精确匹配完整版本串。

### 门禁误报 2：`__cfi_check` 计数
clang CFI 每翻译单元生成一个 `__cfi_check`，但 **ThinLTO 会合并为全局唯一一个**，
最终 Image 中恰好 1 次出现是健康形态（CFI 关闭才是 0 次）。**对策**：阈值 `>=1`
+ System.map 交叉验证。

---

## 四、CI 防回归门禁（已固化进 workflow/脚本）

1. **原厂 boot 分片校验**：内置 boot-bakasu/ 分片 sha256 必须匹配
2. **config 门禁**：`CONFIG_LTO_CLANG_THIN=y` 与 `CONFIG_CFI_CLANG=y` 必须存在，否则 fail
3. **内核名门禁**：banner 必须精确等于原厂串（vermagic 风险）
4. **CFI 实证门禁**：Image 内 `__cfi_check` ≥1 且 System.map 含该符号
5. **SUSFS 实证门禁**：fs 源文件含 hook 数 ≥3；boot 内 susfs 符号计数
6. **boot.img 长度门禁**：必须等于原厂 64MiB

任何会产生「能编译但刷了挂」的 ABI 回归都会在 CI 阶段直接拦截。

---

## 五、刷入与验证

**刷入**（二选一）：
- TWRP / OrangeFox 刷 `AnyKernel3-BakaSU-SUSFS-xaga.zip`（刷前核对 sha256）
- fastboot：`fastboot flash boot_a boot.img`（+`boot_b`，或只刷当前活跃槽）

**验证清单**：
```
adb shell uname -a                        # 内核名 = 原厂串 + 新编译时间戳
adb shell su -c 'cat /proc/modules | wc -l'    # ~386 个，无加载失败
adb shell su -c 'dmesg | grep -i susfs'        # susfs v2.4.0 initialized
adb shell su -c 'dmesg | grep -i "disagrees"'  # 必须为空
```

**注意事项**：
- MIUI 原厂 recovery 不能刷第三方 zip（签名校验拒绝），不是包的问题
- 内核态 SUSFS 需要配套的 BakaSU 管理器 App 配置排除项（sus_path/sus_mount 等）
- 解锁 BL 后首次开机稍慢属正常；若卡 logo 超过 5 分钟再进 fastboot 救砖
- 模块 vermagic 的版本前缀本就宽容（GKI same_magic 逻辑），CRC 才是唯一关卡——
  所以**绝不能动 CFI/LTO/MODVERSIONS**

---

## 六、诊断经验速查

| 症状 | 第一入口 |
|---|---|
| 刷写失败 | 检查 zip 权限位（Windows 打包必坏）；原厂 recovery 不能刷 zip |
| 开机无限重启 | pstore `console-ramoops-0` 找 panic 链；`module_layout` CRC 失配 = CFI/LTO 配置被动过 |
| CI 打包挂但编译过 | 检查脚本内路径计算是否在 `cd` 之后用了相对 BASH_SOURCE |
| LTO 下链接 undefined | 上游驱动 bug（查 BakaSU/SukiSU-Nova 提交记录）或 CFI 内化 static 函数 |
| 门禁误报 | 自检规则要匹配工具链真实形态（ThinLTO 合并符号、rodata 重排） |
