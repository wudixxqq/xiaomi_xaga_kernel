# XAGA (Redmi K50 / 天玑8100, android12-5.10) SUSFS 内核编译踩坑总结

> 2026-11-17 双管线交付后沉淀。Nova = SukiSU-Nova v3.0.0 (c60f21b9)，FinaSU = LyraVoid/FinaSU master (06d71e8a)。
> 最终产物均通过全部门禁：SUSFS 符号计数、原厂 banner 逐字节一致、CFI/ThinLTO、Manager cert hash、SHA256 复核。

## 管线一览

| | Nova | FinaSU |
|---|---|---|
| 脚本 | `scripts/build_nova.sh` | `scripts/build_finasu.sh` |
| CI | `build-nova-susfs.yml` | `build-finasu-susfs.yml` |
| SUSFS 集成方式 | 预制补丁 `patches/novasus_10_enable_susfs_for_ksu.patch`（31 文件手工移植） | 官方 setup.sh 原生内置，**零补丁** |
| Hook 后端 | Nova 自带 syscall bridge | Tracepoint（`CONFIG_KSU_HOOK_TRACEPOINT=y`） |
| Manager 签名 | SukiSU Nova 官方 (0x35c / 947ae944…) | FinaSU v1.6.3 官方 (0x2cc / 2d89b50a…) |
| reboot 分发 | 预制补丁内置 kprobe→dispatcher | 需向 kernel/reboot.c 注入 hook（驱动内无调用方） |

## 一、FinaSU 集成（工作量≈0，但有 3 个坑）

1. **目录名是 `FinaSU/` 不是 `KernelSU/`**。官方 `kernel/setup.sh` 把源码 clone 到 `$GKI_ROOT/FinaSU`，symlink 为 `drivers/kernelsu -> ../FinaSU/kernel`。脚本里所有后续引用（`git -C`、文件校验）必须用 `FinaSU`。（首跑失败直接原因）
2. **setup.sh 自己会 checkout 指定 ref**，clone 后无需再手动 checkout。
3. **Tracepoint+SUSFS 是唯一合法组合**：Inline 后端不支持 LKM 且需要 12 个内核挂点；必须 `-e KSU_HOOK_TRACEPOINT -d KSU_HOOK_SUSFS_INLINE` 并用脚本门禁复核 config。
4. reboot.c 注入：FinaSU 的 `ksu_handle_sys_reboot` 在驱动内没有调用方，唯一入口是 `kernel/reboot.c` 的 `SYSCALL_DEFINE4(reboot,...)`，需在魔法校验前拦截：`SYS_reboot(0xdeadbeef, 0xfafafafa, cmd, payload)`；处理成功返回 0 消费 syscall。

## 二、Nova SUSFS 移植（6 版迭代踩坑记录）

### 根本性结论
- **Nova 官方只有 SUSFS 占位 stub**，KSU 侧集成必须手工移植 susfs4ksu 的 `10_add_susfs_in_kernelsu.patch`。
- **不能直接套官方 10_ 补丁**——它按官方 KSU 目录结构写，对 Nova 有害：重写 7 个文件的 include 列表（丢失 20 个 include）、删 Kbuild 的 hook 子系统对象、删 ksu.h 声明、删 `ksu_app_profile_init` 定义。正确做法是预制专用补丁并**逐文件 diff 验证**。

### 逐版本踩坑
| 版本 | 失败点 | 修复 | 教训 |
|---|---|---|---|
| v1 | init.c 编译错 `ksu_late_loaded` | 回退最小移植，放弃官方有害 hunk | 官方补丁 hunk 必须逐个审查适用性 |
| — | 首跑 CONFIG_KSU_SUSFS 全部丢失 | 构建脚本注入 11 个 Kconfig 符号 + 硬门禁 | KSU 侧 config 必须显式注入并 grep 复核 |
| — | 链接缺 `initialize_fake_status` | 证明必须 KSU 侧补丁配合，不能只上内核 50_ | 符号依赖要在本地先链接验证 |
| v3 | `PT_REGS_SYSCALL_PARM2/3` 未定义 | Nova arch.h 只有 PARM1/4，arm64 用 `PT_REGS_PARM2/3` | 不同 KSU fork 的 arch 抽象层 API 不一致 |
| v4 | 7 文件丢 20 个 include（隐式声明） | v5 全量恢复 include 列表 | **多余 include 零风险，丢失 include 才致命**；宁多勿少 |
| — | setresuid 语义错误 | SUSFS `ksu_handle_setresuid` 必须 **pre-call**（current uid 仍为 0），参数用请求的 ruid/euid/suid 三参；post-call + old_uid 会被 `cur_uid != 0` 守卫拒绝 | hook 时机与参数语义必须跟 SUSFS 官方实现对齐 |
| — | `ksu_app_profile_init` 缺定义 | 官方删了定义但 init.c 仍调用 → 补空存根 | 调用点与定义点要双向核对 |
| v5→v6 | `supercall.c:148 implicit declaration of ksu_handle_sys_reboot`（-Werror） | supercall.c 补 `#include "supercall/supercall.h"` | 见下方"系统性审计" |
| — | 验证脚本报假成功 | `grep -c` 返回 0 会让 `&&` 链断裂、diff 未执行 | 验证必须分步显式检查返回值 |

### 系统性 include 审计方法（v6 后必做）
1. 解析补丁中所有"头文件新增声明"（`^\+\s*(int|void|bool|...) ksu_\w+\(` 且当前 diff 段落是 .h 文件）。
2. 对每个符号 grep 移植树全部调用方（.c）。
3. 核对每个调用方 include 链中是否包含声明所在头文件。
4. 任何一处缺失都是潜在的 -Werror 编译炸弹。

### 补丁最终验证流程（不可省略）
```bash
diff -ruN <基准树> <移植树> > patch        # 从干净基准树生成
cp -r <基准树> verify_tree && cd verify_tree
patch -p1 --batch < ../patch               # 真实套用，检查 0 fuzz 0 fail
diff -rq verify_tree <移植树>              # 逐字节一致才算通过
```

## 三、构建共同要点（"内核名与构建时间要和原厂一样"）

1. **banner 复刻**（防"内核比 boot 新"等启发式检测）：
   - `SUBLEVEL = 136`；写入 `.scmversion` 防 `-g<sha>-dirty` 后缀
   - 冻结编译时间戳 `STOCK_BTS="Wed Feb 8 23:50:57 UTC 2023"` → `uname -a` 与原厂逐字节一致
   - 目标 banner：`5.10.136-android12-9-00020-gc9f59ef34367-ab9585114`
2. **vermagic 一致 = vendor 模块能加载**：CFI 未开（`CFI_N=0`）→ `module_layout` CRC 不匹配 → 所有 stock vendor 模块加载失败 → init panic bootloop。脚本必须硬门禁 `CFI_CLANG=y + LTO_CLANG_THIN=y`。
3. **boot 重打包**：magiskboot unpack 原厂 stock boot（从 chunk 分片重组并校验 SHA `8a818f31…`），只替换内核 Image，ramdisk/dtb 原样保留，repack 后 truncate 回原厂 64MiB。
4. **门禁清单**（构建后必须全过）：SUSFS 符号计数（>100 为正常）、Image 内 cert hash 与 Manager APK 一致、reboot hook 计数、15 个 hooked 文件清单、banner 逐字节比对。
5. KSU_EXPECTED_SIZE/HASH 来自官方 Manager APK 的 v2 签名证书 DER（size + sha256）。**kernel 只读第一个 signer**，解析 APK 签名块时注意偏移。

## 四、GitHub REST API 推送（无 clone 环境）踩坑

1. **大文件 blob 必须 `-d @file`**：把 base64 内容放进命令行会 `Argument list too long`。
2. **每步返回的 SHA 必须非空校验后才进下一步**：blob 失败后空字符串进 tree 请求 → GitHub 静默丢弃该条目 → root tree 缺整个目录 → 坏 commit 已推上 main。教训：`test -n "$SHA" || exit 1` 逐级把关，出事后立即用旧 base_tree 重建。
3. tree 创建 422（偶发超时）→ 重试机制；PATCH ref 用 `force:false` 防覆盖。
4. 推送后必须 `raw.githubusercontent.com` 回读验证内容。

## 五、真机救砖经验（2026-11-17 实战）

1. **黑屏无反应 ≠ 砖**。先怀疑电池耗尽（bootloop 极耗电）：原装充电器充电 30 分钟再操作。
2. **MTK BROM 握手特征**：设备管理器"瞬间出现 MediaTek USB Port VCOM (COMx)" = 硬件完好、救砖通道可用。关机状态按住音量上+下插线可进 BROM，mtkclient 可读写任意分区。
3. **fastboot（bootloader）≠ fastbootd（userspace）**：fastbootd 是 recovery 样式界面，也能 `flash boot`；但必须在电脑上用 fastboot 命令操作，光在手机上进入没用。
4. **进入 fastboot 最可靠方式：开机进系统后 `adb reboot bootloader`**，比按键组合可靠得多。
5. boot 分区损坏不影响 fastboot/BROM 模式——bootloader 独立于 boot 分区；刷坏 boot 的保底方案永远存在。
6. 保底文件：原厂 boot 可从 chunk 重组（本仓库 `boot-bakasu/boot.img.part-*.part` 拼接，SHA256 `8a818f319380a7bb…`）。

## 六、最终交付记录

| 产物 | SHA256 | banner 校验 |
|---|---|---|
| Nova boot.img | eb7e1632b120cc92… | 与原厂一致 ✓ |
| Nova AK3 zip | 482d07f03efe8bcc… | SUSFS 158 符号 |
| FinaSU boot.img | 60a29419f054ae8e… | 与原厂一致 ✓ |
| FinaSU AK3 zip | 51f9ae0e926ffab9… | SUSFS 155 符号 |

CI run：Nova v6 = 44005372833（success），FinaSU = 44004635967（success）。
