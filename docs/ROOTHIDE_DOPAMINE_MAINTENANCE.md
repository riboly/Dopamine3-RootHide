# Dopamine3-RootHide 维护与修复报告

本文档记录 `riboly/Dopamine3-RootHide` 的关键架构、安全边界、已确认故障及发布验证流程，供后续维护使用。当前维护分支为 `roothide-3.x`。

## 1. 当前已验证状态

| 版本 | 变更 | 设备结果 |
| --- | --- | --- |
| 3.0.21 | 修复 RootHide setid donor 握手 | Sileo 源名称、更新、安装全部正常；Zebra 正常启动和使用 |
| 3.0.22 | 修复重启后重新月余导致用户软件源丢失 | 用户已确认 `sileo.sources` 与 `roothide-release.sources` 生效，软件源持久化正常 |
| 3.0.23 | A1：修复 iOS 18 `ucred` 引用宽度、最终 weak release 和异常 respring | 构建通过，但 21:00 的有效新版本回归仍出现同类 `smr.c:2831` panic，A1 已被设备证伪为不完整 |
| 3.0.24 | A2：禁止 iOS 17+ 原地修改 credential hash key，统一安全复制/替换 | 设备首次激活在 `kauth_cred_reference_adjust()` 中 SIGSEGV，不能使用 |
| 3.0.25 | A3：首次激活改为 pinned credential 回退 | 设备仍在同一 mapped credential reference 路径 SIGSEGV，不能使用 |
| 3.0.26 | A5：weak-only pin，并修复 PTE/full-map 后端分派 | 设备可正常月余，自动重启显著减少；运行约 3 小时 13 分后出现新的 launchd trust-cache/IOSurface 路径 SIGEMT，不能关闭稳定性问题 |
| 3.0.27 | B1：修复 launchd trust-cache 并发、去重和跨页写入 | 真机仍发生 IOSurface 生命周期 panic，不能使用 |
| 3.0.28 | C1：通用动态 trust-cache 注册表 | 真机注册表有效，但主按钮路径未恢复；月余时可自动重启或长时间黑屏卡顿，不能使用 |
| 3.0.29 | B2/D1：内核 allocator 与 launchd 同步持久恢复 | GitHub Actions 全量构建通过；设备安装与完整重启周期仍待验证 |

测试设备基线：iPhone XS Max，iOS 18.2.1。其他系统版本仍需单独验证，不能从该设备结果直接推断。

## 2. RootHide 路径模型

RootHide 使用同一 brand 的两棵目录：

```text
/var/containers/Bundle/Application/.jbroot-<16 位 brand>
/var/mobile/Containers/Shared/AppGroup/.jbroot-<16 位 brand>
```

第一棵保存 bootstrap 主体；第二棵保存可写的 `var` 数据，并通过 `.jbroot` 与主目录配对。`ReRandomizeBootstrap` 每次重新月余都会生成新 brand，同时移动这两棵目录并重建链接。

在已注入 RootHide 的 SSH 进程中，路径会被虚拟化：月余根显示为 `/`，因此应检查 `/etc/apt`、`/var/lib/apt` 和 `/var/mobile`。`/var/jb` 不存在是 RootHide 的正常表现，不能据此判断 bootstrap 丢失。

## 3. 3.0.21：Sileo/Zebra 共用 root-spawn 故障

### 现象

- Zebra 启动即闪退。
- Sileo 所有软件源显示“未命名的软件源”。
- Sileo 下载到的 Packages 索引随机、不完整，插件依赖被错误判断为无候选。

### 证据与根因

Zebra 的根进程启动返回：

```text
spawn .../usr/bin/id error:100,34,Result too large
```

设备 syslog 将失败定位到：

```text
Persona root fix failed
stage=donor-handshake-protocol
result=100
```

donor 子进程已经创建，但旧的 `DYLD_HOOK_SETUID` 和单字节 `0x42` 握手没有在目标程序 `main` 之前完成。Sileo 保存 Release/Packages 同样依赖 `spawnAsRoot`，所以两个 App 实际上是同一个 RootHide root-spawn 故障，而不是逐个软件源缺少公钥。

### 修复

- donor 请求改用 systemhook 启动参数协议。
- 让 launchd 正常注入 systemhook，并在 constructor 阶段、目标 `main` 之前完成身份设置。
- 回复包含 magic、状态和 donor PID，并由父进程完整校验。
- 保留原有父子关系校验、凭证复制和失败清理。

主要文件：

```text
BaseBin/libjailbreak/src/setid_donor.h
BaseBin/libjailbreak/src/util.c
BaseBin/systemhook/src/main.c
```

设备实测已确认 3.0.21 解决 Sileo 和 Zebra 的全部上述问题。

## 4. 3.0.22：软件源持久化故障

### 现象

Sileo 当次使用完全正常，但手机重启并重新月余后，用户之前添加的软件源消失，需要重新添加。

### 根因

为了在早期修复中重新生成有效默认源，`buildPackageSources` 被加入 `ReRandomizeBootstrap`。每次重新月余时它都会执行，并无条件写入：

```text
/etc/apt/sources.list.d/sileo.sources
```

Sileo 自己也使用这个文件保存用户添加的软件源。Dopamine 将 RootHide release 默认源写入同名文件，导致重随机后用户内容被完整覆盖。

设备侧在故障状态下只剩：

```text
Types: deb
URIs: https://github.com/roothide/roothide.github.io/releases/download/1900/
Suites: ./
Components:
```

同一函数还无条件覆盖 Zebra 的：

```text
/var/mobile/Library/Application Support/xyz.willy.Zebra/sources.list
```

因此 Zebra 虽未被本次用户报告点名，也存在同类数据丢失风险。

### 修复设计

软件源文件所有权现在明确如下：

| 路径 | 所有者 | 重随机策略 |
| --- | --- | --- |
| `default.sources` | Dopamine | 可重建默认源 |
| `procursus.sources` | Dopamine | 可重建 RootHide Procursus 源 |
| `roothide-release.sources` | Dopamine | 可重建 RootHide release 源 |
| `sileo.sources` | Sileo/用户 | 不得覆盖；只迁移旧版精确匹配的托管 stanza |
| Zebra `sources.list` | Zebra/用户 | 仅首次不存在时创建 |

升级迁移会读取旧 `sileo.sources`，只删除精确匹配当前 CoreFoundation 主版本的 RootHide release stanza。其他 stanza 保留，然后将托管源写到独立的 `roothide-release.sources`。

主要文件：

```text
Application/Dopamine/Jailbreak/DOBootstrapper.m
Application/Makefile
BaseBin/_external/basebin/.version
```

## 5. 安全边界

### 禁止盲删

“移除月余”只能删除经过验证的候选项。至少验证：

1. 父目录必须是预期的 RootHide 或 Dopamine rootless 容器目录。
2. 目录名必须满足严格格式。
3. 必须存在 Dopamine 安装标记。
4. RootHide 主目录和 secondary 目录必须通过 `.jbroot` 正确配对。
5. `/var/jb` 如存在，必须是指向已验证候选项的符号链接。
6. 任意路径归属不明确时整体中止，不进行部分删除。

不要把 TrollStore Lite 标记、TrollFools 当前插件配置或 App 内注入 dylib 当作旧月余残留直接删除。

### 设备操作

- 默认只读检查。
- 不自动重启、用户空间重启或 kill 系统服务。
- OpenSSH 重装或 RootHide 重随机可能导致主机密钥变化。先显示并核对新指纹；不要为方便而删除整个 `known_hosts`。
- 不在仓库中保存设备 IP、SSH 密码、签名证书或 GitHub token。

## 6. 软件源诊断流程

在 active RootHide SSH 环境中执行：

```sh
find /etc/apt -maxdepth 3 -type f -print
find /var/lib/apt/lists -maxdepth 1 -type f -print
find /var/lib/apt/sileolists -maxdepth 1 -type f -print
```

检查配置内容时应逐文件读取，不要先删除缓存：

```sh
for f in /etc/apt/sources.list.d/* /etc/apt/sileo.list.d/*; do
    [ -f "$f" ] || continue
    echo "FILE:$f"
    cat "$f"
done
```

若 Sileo 和 Zebra 同时异常，优先检查共享 root-spawn：

```sh
id
sudo -n id
```

结合 syslog 区分 spawn、persona、donor handshake、权限和下载问题。不要根据 Sileo UI 的 GPG 文案直接推断为单个公钥缺失。

## 7. 构建和产物验证

GitHub Actions 工作流：

```text
.github/workflows/roothide.yml
```

每次发布至少完成：

1. `git diff --check` 通过。
2. `Application/Makefile` 与 basebin `.version` 一致。
3. Actions 完整 TIPA 构建成功。
4. 下载的 artifact ZIP SHA-256 与 GitHub API digest 一致。
5. TIPA ZIP 和嵌套 `basebin.tar` 都能完整枚举。
6. `Info.plist` 的 `CFBundleShortVersionString` 正确。
7. `systemhook.dylib` 包含 `arm64` 和 `arm64e`。
8. 与本次修复有关的 runtime marker 或文件名确实进入最终产物。

设备使用 LCSIGN 覆盖安装时，构建成功不等于修复完成。必须在真实设备验证目标行为。

## 8. 3.0.22 回归清单

升级前先在 Sileo 添加至少一个易识别的测试源，并记录：

```sh
find /etc/apt/sources.list.d -maxdepth 1 -type f -print -exec cksum {} \;
cat /etc/apt/sources.list.d/sileo.sources
```

覆盖安装 3.0.22 并重新月余后检查：

1. `sileo.sources` 中用户 stanza 仍存在。
2. `roothide-release.sources` 单独存在且内容正确。
3. 不存在重复 RootHide release 条目。
4. Sileo UI 中用户源仍存在，刷新和安装正常。
5. Zebra 自定义源仍存在且 Zebra 正常启动。
6. 重启手机，再次重新月余后重复以上检查。

用户已完成设备验证，3.0.22 的源持久化问题已关闭。后续版本仍需保留本清单，防止引导重随机逻辑回归。

## 9. 月余检测结论

此前“很多 App 仍检测到月余”不是旧 rootless 环境残留。用户在 RootHide 中为对应 App 打开隐藏开关后已完全解决，因此该方向已关闭，不需要添加 App 特定绕过，也不应清理 TrollStore/TrollFools 数据。

## 10. 3.0.23：iOS 18 `ucred` SMR panic

### 现象与排除项

设备在月余后偶发自动重启，panic 为：

```text
Unable to find item 0xffffffded5077760
(linkage 0xffffffded5077770)
in 0xfffffff01937f5a8
(traits 0xfffffff016a13a20)
@smr.c:2831
```

设备为 iPhone XS Max（iPhone11,6），iOS 18.2.1（22C161），XNU 11215.62.3。panic task 是 `kernel_task`。日志同时显示：

```text
Compressor Info: 41% of compressed pages limit (OK)
swap space OK
memoryPressure=false
```

因此这不是内存耗尽，也没有证据支持普通用户态内存泄漏。

### XNU 结构证据

Apple XNU 11215.61.5 的 `struct ucred_rw` 布局为：

```c
struct ucred_rw {
    os_ref_atomic_t         crw_weak_ref;
    struct ucred           *crw_cred;
    struct smrq_slink       crw_link;
    struct smr_node         crw_node;
};
```

panic 中 `linkage - item == 0x10`，正好等于 `crw_link` 在 `ucred_rw` 中的偏移。`kauth_cred_retire()` 会通过该 link 从 `kauth_cred_hash` 的 SMR hash 删除凭证。故障对象可确定为 `ucred_rw`，不是泛化的任意 SMR 容器。

旧实现有两个违反 XNU 语义的问题：

1. iOS 18 的 `crw_weak_ref` 是 32 位 `os_ref_atomic_t`，旧代码却用 64 位原子加减。
2. weak ref 的最后一次 `1 -> 0` 必须进入 `kauth_cred_retire()`；裸 `atomic_fetch_sub` 会绕过 hash 删除和 SMR 延迟释放。

### 修复

- weak ref 使用 32 位 CAS，long-term `cr_ref` 使用 64 位 CAS。
- 拒绝 0、溢出和裸 weak `1 -> 0`，不再绕过 XNU retirement。
- donor 与目标 `proc/ucred` 在取得引用前、发布前和释放旧凭证前重新校验。
- 新凭证引用或发布失败时停止并返回 `donor-ucred-copy`，不继续写 audit token。
- 发布写入后读回目标指针；只有确认目标仍指向旧凭证时才回滚新引用，写入状态不确定时保留新引用，避免制造悬空 `ucred`。
- strong drop 失败时不继续 weak unref，避免产生“强引用未释放、weak 却被提前减少”的不一致状态。
- 新凭证已经发布后，如旧凭证不能安全释放，则保留旧引用并记录错误；有限保留优先于 SMR 损坏或危险回滚。

主要文件：

```text
BaseBin/libjailbreak/src/kernel.c
BaseBin/libjailbreak/src/kernel.h
BaseBin/libjailbreak/src/util.c
```

产物标记：

```text
UCRED-SMR-18A1
```

### 3.0.23 设备回归结论

3.0.23 已在设备上覆盖安装并重新月余。日志时间必须严格区分：

```text
panic-full-2026-08-21-193028.0002.ips  旧版本，仅作历史记录
panic-full-2026-08-21-210019.0002.ips  3.0.23 有效回归
```

设备同时只读确认：

```text
/basebin/.version = 3.0.23
/basebin/.build = 6cb051f303596048c63f74032d30f519c24fd632
```

21:00 日志仍然是：

```text
Unable to find item 0xffffffdd33bb5060
(linkage 0xffffffdd33bb5070)
@smr.c:2831
```

`linkage - item == 0x10` 仍指向 `ucred_rw.crw_link`。日志同时为 `Compressor 69% (OK)`、swap 正常、`memoryPressure=false`，再次排除内存爆满和普通用户态内存泄漏。结论是 A1 修正了引用计数错误，但没有消除所有 credential hash 损坏来源。

### A1 原验证清单

覆盖安装后重新月余，至少验证：

1. Sileo 刷新与安装、Zebra 启动、`sudo -n id` 等 root-spawn 路径仍正常。
2. 多次正常安装/卸载小型软件包后没有 `donor-ucred-copy` 错误。
3. 观察期内不再出现相同 `smr.c:2831` panic。
4. 如仍有 panic，必须按新的 panic string 和 `item/linkage` 重新分类，不能直接归因于本次旧日志。

### 构建记录

GitHub Actions 全量构建：

```text
run: 32478274023
source commit: 6cb051f303596048c63f74032d30f519c24fd632
artifact id: 9445143469
artifact: roothide-Dopamine-3.0.23-6cb051f.tipa
artifact ZIP SHA-256: b5a701bc8a252d8124cbfcd9b3aefc2327007ea83da728ef8deb5621d80f7650
TIPA SHA-256: 8e8a92cf6167076e4785642daf33ef0f0ad4ac162f641b65990e121bdb4a370f
```

核验结果：

- `Info.plist`：`CFBundleShortVersionString = 3.0.23`。
- `basebin/.version = 3.0.23`，`basebin/.build` 与 source commit 一致。
- `libjailbreak.dylib`、`systemhook.dylib`、`jbctl` 均包含 arm64 和 arm64e 切片。
- `UCRED-SMR-18A1` 与 `RESPRING-IOS18-BBD1` 均存在于最终 `basebin.tar` 对应双切片中。
- artifact ZIP digest 与 GitHub 元数据一致，TIPA 与内层 `basebin.tar` 均可完整解包。

## 11. iOS 18 respring 变成整机式重启

### 证据链与规避范围

`uikittools` 2.1.6 的 `sbreload` 先通过 `SBSRelaunchAction` 和 `FBSSystemService` 请求重启 render server，失败后才使用旧 launchd system handle 停止 SpringBoard/backboardd。该旧流程与 iOS 18.2.1 上报告的整机式重启现象吻合。

Dopamine 的 `watchdoghook` 会拦截 userspace panic、进入 safe mode，并执行：

```c
reboot3(RB2_USERREBOOT);
```

这可以解释为何用户看到整机式用户空间重启，却没有 kernel panic 日志。但是当前没有取得对应时刻保存下来的 userspace-panic 日志，因此不能把 watchdog 链路写成已经日志证实的唯一根因。3.0.23 主动绕开可疑的旧 FrontBoard 流程，并保留错误状态用于设备验证。

### 修复

- `jbctl respring` 在 iOS 18+ 直接向 `backboardd` 发送 `SIGTERM`，不再执行旧 `sbreload` FrontBoard 流程。
- systemhook 在 iOS 18+ 识别直接执行的 `/usr/bin/sbreload`，让 Sileo、Zebra、控制中心模块等第三方调用者走同一传统 respring 路径。
- 设备只读检查确认 SpringBoard 与 backboardd 均以 `mobile` 运行；第三方 `sbreload` 可在同一 UID 下合法发送信号，无需增加新的 jbserver 提权接口。
- 两条路径都检查是否真正找到并成功发出信号；权限不足时返回非零并写日志，不再静默报告成功。
- 修正 `killall()` 的参数缓冲区长度不匹配：缓冲区现在按传给 `KERN_PROCARGS2` 的 `KERN_ARGMAX` 分配，避免进程列表较小时发生用户态堆越界。
- iOS 17 及更旧系统保留原行为，缩小兼容性影响范围。

主要文件：

```text
BaseBin/jbctl/src/main.m
BaseBin/systemhook/src/main.c
```

产物标记：

```text
RESPRING-IOS18-BBD1
```

该行为必须由用户明确触发测试。维护过程不得为了验证而自行重启 SpringBoard、用户空间或手机。

## 12. AFC2 安装警告

`com.cannathea.afc2d-arm64e` 1.1.7-21 的 `postinst` 为：

```sh
launchctl kill 9 system/com.apple.mobile.lockdown
exit 0
```

iOS 18.2.1/RootHide 设备实际将服务显示在 `user/501` 域，`user/foreground/com.apple.mobile.lockdown` 可以解析；旧脚本写死 `system/...` 时，launchctl 会提示：

```text
Warning: Please switch to user/foreground/
com.apple.mobile.lockdown service identifier
Not privileged to signal service.
```

这不是 dpkg 安装失败。设备已确认包状态为 `install ok installed`，以下文件存在：

```text
/Library/MobileSubstrate/DynamicLibraries/afc2dService.dylib
/Library/MobileSubstrate/DynamicLibraries/afc2dService.plist
/usr/libexec/afc2d
```

后续服务重启后 AFC2 生效。正确的长期修复是 AFC2 包更新 postinst 的服务域；Dopamine 不应为单个第三方包全局重写所有 `launchctl system/...` 请求。若未来实现通用域兼容层，必须逐个服务验证并禁止模糊匹配。

## 13. 3.0.24：credential hash key 原地突变修复

### A2 根因

Apple XNU 的 `kauth_cred_ro_hash()` 不只依赖 `ucred_rw` 引用生命周期，还会把 credential 内容作为 hash key，包含：

- `cr_posix` 中的 UID、GID、groups 和 saved IDs；
- audit session；
- 启用 MAC 时的 credential label。

3.0.23 仍有多条路径在 credential 已进入 hash 后直接修改这些字段。对象留在旧 bucket，但退休时 XNU 根据突变后的新 key 删除，于是 `kauth_cred_retire()` 无法找到原 item 并在 `smr.c:2831` panic。这解释了为什么 A1 修正 weak/strong 引用后，同类 panic 仍能在 3.0.23 上复现。

已确认的危险路径包括：

```text
Application/Dopamine/Jailbreak/DOJailbreaker.m
BaseBin/launchdhook/src/jbserver/jbdomain_dopamine.c
BaseBin/launchdhook/src/jbserver/jbdomain_systemwide.c
BaseBin/launchdhook/src/jbserver/jbdomain_root.c
Application/Dopamine/Jailbreak/DOEnvironmentManager.m
```

### A2 设计

- `proc_copy_ucred()` 公开为公共安全复制接口；`proc_replace_ucred()` 为显式 credential 替换接口。
- 新 credential 在发布前取得 weak 与 strong 引用，并在发布后读回目标指针、复核 PID/proc/ucred 身份。
- 发布失败时，只有确认目标仍指向旧 credential 才撤销新引用；状态不确定时保留引用，避免悬空指针。
- 释放旧 credential 时必须先 strong drop，成功后才 weak unref；weak `1 -> 0` 仍被禁止并有限保留。
- Dopamine 初始提权与 finalize 直接借用不可变 kernel credential，不再写 UID/GID/groups 或 kernel MAC label。
- Dopamine get/drop root 和 iOS 17+ setuid check-in 通过 donor 生成完整 credential，再原子式发布；real UID/GID 保持原值，只修改所需 effective ID 与 `groups[0]`。
- Dopamine check-in 只更新 `proc.svuid/svgid`，不再写 `ucred.svuid/svgid`。
- root 域临时 unsandbox 改为安全借用 kernel credential 并恢复，iOS 17+ 禁止旧 MAC label 原地修改接口。
- iOS 16 及更旧系统保留旧兼容分支，缩小行为变化范围。

产物标记：

```text
UCRED-SMR-18A2
```

### 3.0.24 回归要求

构建核验必须确认版本 `3.0.24`、arm64/arm64e 切片、`UCRED-SMR-18A2` 和 `RESPRING-IOS18-BBD1` 都进入最终 TIPA。设备覆盖安装后：

1. 确认 `/basebin/.version` 与 `/basebin/.build` 对应 3.0.24 产物。
2. 验证 Sileo 刷新/安装、Zebra、OpenSSH、Frida、Dopamine get/drop root 与需要 unsandbox 的管理功能。
3. 观察 jbserver 日志中是否出现 `donor-*`、`ucred replace`、`get-root` 或 `drop-root` 阶段错误。
4. 正常使用并观察稳定性；只有足够观察期内不再产生同类 `ucred_rw` SMR panic，才能关闭该问题。
5. respring、用户空间重启和手机重启均由用户自行触发；维护过程不得代为执行。

### 3.0.24 构建记录

GitHub Actions 第一次构建在新增错误码缺少 `<errno.h>` 时失败，补齐声明后第二次全量构建成功：

```text
successful run: 32487161830
source commit: 11c003131dc0fd4957fd7d5d10c503064e9d4b51
artifact id: 9448347509
artifact: roothide-Dopamine-3.0.24-11c0031.tipa
artifact ZIP SHA-256: bd7fbf5e13dc6d7257d82bee510283e8c00e4144bed2dcfa70ba08a7e4e28bc3
TIPA SHA-256: e4927cfd4319958fd8c26ac1730daa5e595bb4fa479ab9952c929a43487e4050
basebin.tar SHA-256: de85bc4076693e0291ad832cce42e0338d32c094bfe213f2e3a2b0b3569fa891
```

核验结果：

- GitHub artifact digest 与下载的外层 ZIP SHA-256 完全一致。
- `Info.plist` 的 `CFBundleShortVersionString = 3.0.24`。
- `basebin/.version = 3.0.24`，`basebin/.build` 与 source commit 完全一致。
- `libjailbreak.dylib`、`systemhook.dylib`、`jbctl` 均包含 arm64 和 arm64e 切片。
- `UCRED-SMR-18A2` 存在于 `libjailbreak.dylib` 双切片；`RESPRING-IOS18-BBD1` 存在于 `systemhook.dylib`。
- artifact ZIP、TIPA 和内层 `basebin.tar` 均可完整枚举和解包。

3.0.24 的构建核验通过，但设备首次激活回归失败，不能交付或继续用于测试。

## 14. 3.0.23 新 panic 与 3.0.24 激活回归

### 3.0.23 新日志

用户提供的有效目录：

```text
D:\LocalSend\21点13-21点29参数 月余环境3.0.23
panic-base-2026-08-21-211339.ips
panic-full-2026-08-21-212942.0002.ips
```

两次均为相同的 `ucred_rw` SMR 哈希删除失败：

```text
Unable to find item ... (linkage item+0x10) @smr.c:2831
```

21:13 日志的 Compressor 为 33% (OK)，panicked task 是 `sudo`；21:29 为 36% (OK)、`memoryPressure=false`，panicked task 是 `launchd`。因此不是内存爆满，也没有证据支持普通用户态内存泄漏；A1 仍遗漏了 credential hash key 原地突变。

### 3.0.24 设备失败

3.0.24 覆盖安装后，月余执行到 `Elevating Privileges` 附近时 Dopamine App 直接退出，手机没有重启或注销；重新打开重试仍复现。最初曾怀疑完整替换为 `kernproc` credential 导致 RunningBoard 终止 GUI App，但随后取得的两份 crash report 已否定该判断：实际是 `proc_copy_ucred()` 首次执行 `kauth_cred_ref()` 时，`kaccess_mapped()` 解引用未建立的 full-map 地址并触发 SIGSEGV。详见第 16 节。

构建成功不能覆盖该设备回归结论，3.0.24 不能继续使用。

## 15. 3.0.25：首次激活 pinned credential 回退

首次激活发生在 launchdhook 能提供 donor credential 之前。3.0.25 使用以下窄回退：

1. 读取 Dopamine 自身当前 credential，不复制 `kernproc` credential。
2. 在任何 UID/GID/MAC 写入前，同时增加 weak 与 strong 引用，并在写入前重新核对 `proc` 仍指向同一 credential。
3. 每个 App 进程对同一 credential 只 pin 一次；该引用在本次开机周期内故意不释放，使突变后的 hash key 永远不会进入 `kauth_cred_retire()`。
4. 恢复首次激活所需的 UID/GID、saved IDs、groups 和 sandbox label 修改；其他已激活环境的 `sudo`、`launchd`、setuid、get/drop-root 仍使用 A2 donor credential，不采用此回退。
5. `finalize` 只验证 real/effective UID/GID 仍为 0，不再复制 kernel credential，也不再重复修改 hash key。
6. `runUnsandboxed` 仅在 App 已为完整 root 身份且确实能枚举 `/private/var/root` 时复用当前激活身份；仅临时 UID 0 但仍受沙盒约束时继续走原有借用路径。

该方案有意保留一组 credential 引用，完整手机重启后由内核回收；这是有上限的单次开机泄漏，用来换取避免 SMR panic。不得把它推广到循环调用、daemon 或任意目标进程。

产物标记：

```text
UCRED-SMR-18A3
```

### 3.0.25 构建记录

GitHub Actions 全量构建：

```text
successful run: 32489768172
source commit: 5df75d8eea563b422636c5feda7a9d6db62d7a48
artifact id: 9449323835
artifact: roothide-Dopamine-3.0.25-5df75d8.tipa
artifact ZIP SHA-256: 10d2f23ac435801b0f7beea35b617257ebc60100dde970cf216beea059166d13
TIPA SHA-256: 56ec0ac7133acc744cb8f146f5cf70ef536ec72454cd33f0ff8a91555c587661
basebin.tar SHA-256: 81d69748475f90c8b9be03c1aaee8608d4c8369f0bf2fc3f88cc3175d45aafdb
```

核验结果：

- GitHub artifact digest 与下载的外层 ZIP SHA-256 完全一致。
- `Info.plist` 的 `CFBundleShortVersionString = 3.0.25`。
- `basebin/.version = 3.0.25`，`basebin/.build` 与 source commit 完全一致。
- `libjailbreak.dylib`、`systemhook.dylib`、`jbctl` 均包含 arm64 和 arm64e 切片。
- `UCRED-SMR-18A3` 存在于 `libjailbreak.dylib` 双切片；`RESPRING-IOS18-BBD1` 存在于 `systemhook.dylib` 双切片。
- artifact ZIP、TIPA 和内层 `basebin.tar` 均可完整枚举和解包。

3.0.25 已通过源码与产物核验，但设备首次激活仍与 3.0.24 一样在流程中直接退出。A3 不能交付。

## 16. 3.0.26：修复 credential 原子访问的 physrw 后端分派

### 3.0.24/3.0.25 crash report 证据

通过 `mobile` 身份从真实 CrashReporter 路径读取到：

```text
Dopamine-2026-08-21-214255.ips  3.0.24
Dopamine-2026-08-21-214315.ips  3.0.24
Dopamine-2026-08-21-221935.ips  3.0.25
Dopamine-2026-08-21-222010.ips  3.0.25
Dopamine-2026-08-21-222301.ips  3.0.25
```

五份日志均为 `EXC_BAD_ACCESS / SIGSEGV`，共同栈为：

```text
__kauth_cred_adjust32_block_invoke
kaccess_mapped
kauth_cred_reference_adjust
-[DOJailbreaker elevatePrivileges]
```

3.0.24 的栈还经过 `proc_copy_ucred`；3.0.25 直接在首次 weak pin 中进入同一 helper。崩溃地址均为 `0x78...` 的用户地址，属于 Dopamine 预留的 PPLRW 物理映射区，而不是 `ucred` 内核地址。因此此前“可能是 `cr_ref` 的只读 zone 写入导致退出”的判断已被新日志否定：实际连第一次 32 位 weak-ref 原子读取都没有完成。

### A5 根因与修复

iPhone XS Max 的激活路径使用 `physrw_pte` 单页 window。`libjailbreak_physrw_pte_init()` 正确注册了：

```text
gPrimitives.physaccess_mapped = physrw_pte_physaccess_mapped
```

但旧 `kaccess_mapped()` 没有通过该后端分派，而是固定调用 `physrw_kvtouaddr()`，按整段物理映射计算 `PPLRW_USER_MAPPING_OFFSET`。PTE 模式并没有建立这段整映射，所以 block 首次解引用即 SIGSEGV。

A5 做两项配套修改：

1. 在 primitives 层补齐 `physaccess_mapped()` 分派器，统一调用当前注册的后端。
2. `kaccess_mapped()` 只负责把 kernel VA 转换成 PA，再经分派器进入 full-map 或 PTE window。PTE window 自带互斥锁，CAS 仍在映射有效期间完成。

A4 的 weak-only 首次 pin 保留：阻止 weak ref 归零已经足以避免 `kauth_cred_retire()` 和错误的 SMR hash remove；无需额外改写 `ZC_READONLY` 中的 long-term `cr_ref`。App 退出时人为保留的 weak ref 使突变 credential 在本次开机周期内不退休。这是首次激活限定、每个进程至多一次的有界保留，不得推广到循环或 daemon 路径。

为避免再次仅凭现象推断，3.0.26 会在提权前打开 App 数据容器内的 `Library/Caches/privilege-elevation-stage.log`，随后通过同一个文件描述符同步覆盖以下阶段：

```text
begin
before-weak-pin
after-weak-pin
before-posix-writes
after-posix-writes
before-mac-label
after-mac-label
complete
```

若 App 再次退出，回退到可用版本后读取该文件即可确定最后完成的步骤。该标记不包含用户数据，也不依赖提权后的 `cfprefsd` 或其他系统服务。

产物标记：

```text
UCRED-SMR-18A5
```

### 3.0.26 构建记录

GitHub Actions 全量构建：

```text
successful run: 32494919456
source commit: 6609f27204b61c800e6ca3947b6b5d0ac267b5a7
artifact id: 9451283546
artifact: roothide-Dopamine-3.0.26-6609f27.tipa
artifact ZIP SHA-256: c0ea2b773f3c9e8716e688895070a745b1d56769efde9fd70ba251f3cec1cef8
TIPA SHA-256: 68182288ff3cbc4aa22017c788f7aafc3cfe85153d362bee9bb7d54a4f4d2056
basebin.tar SHA-256: 9cae038fd1c86379dc7807835de96c0fc3d6c056c6bf5e29a02394f82a6e8680
```

核验结果：

- GitHub artifact digest 与下载的外层 ZIP SHA-256 完全一致。
- 外层 artifact ZIP、TIPA 和内层 `basebin.tar` 均可完整枚举。
- `Info.plist` 的 `CFBundleShortVersionString = 3.0.26`。
- `basebin/.version = 3.0.26`，`basebin/.build` 与 source commit 完全一致。
- `libjailbreak.dylib`、`systemhook.dylib`、`jbctl` 均包含 arm64 和 arm64e 切片。
- `UCRED-SMR-18A5` 存在于 `libjailbreak.dylib`；`RESPRING-IOS18-BBD1` 存在于 `systemhook.dylib`。

3.0.26 已通过源码、工作流和产物核验，但仍需真实设备完成首次月余和后续稳定性验证，不能仅凭构建宣布 panic 已关闭。

### 22:36 最新 panic

`panic-full-2026-08-21-223652.0002.ips` 仍是：

```text
Unable to find item ... (linkage item+0x10) @smr.c:2831
Panicked task: pid 1130: sudo
Compressor 16% (OK)
memoryPressure=false
```

设备当时运行 3.0.23；panic 紧随一次 SSH `sudo` 日志枚举发生。这再次排除内存耗尽，并确认 3.0.23 的 credential hash 损坏仍可由 `sudo` 路径触发。后续取证必须以 `mobile` 读取 `/rootfs/private/var/mobile/Library/Logs/CrashReporter`，不得为了读取日志调用 `sudo`，也不得对 RootHide 虚拟 `/var/mobile/Library/Logs` 做递归枚举。

## 17. 3.0.27：launchd trust-cache/IOSurface 稳定性修复

### 3.0.26 设备结果与新 panic 分类

用户确认 3.0.26 比此前版本稳定，自动重启次数明显减少，说明 A5 已消除一部分主要故障；但以下新日志证明仍有独立问题：

```text
D:\LocalSend\panic-full-2026-08-22-022721.0002.ips
initproc exited -- exit reason namespace 1 subcode 0x7
Panicked task: pid 1: launchd
Compressor 64% (OK)
memoryPressure=false
```

`namespace 1 / subcode 0x7` 是 `SIGEMT`。设备从开机到 panic 约 3 小时 13 分，PID 1 的 `residentMemoryBytes` 为 `2,207,316,856`，约 2.06 GiB。系统压缩页、segment 和 swap 均报告 OK，因此这次不是此前的 `ucred_rw / smr.c:2831`，也不能归因于全机内存压力。

日志内用户镜像 UUID 与 3.0.26 最终产物完全匹配：

```text
image 18  6D22FA2D...  libjailbreak.dylib
image 19  6F9F2D1D...  launchdhook.dylib
image 20                 /sbin/launchd
```

按该精确产物符号化后，退出线程位于 launchd 的 XPC event queue，调用链为：

```text
xpc_receive_mach_msg_hook
jbserver_received_xpc_message
trust_macho_recurse
jb_trustcache_add_cdhashes
jb_trustcache_add_entries
_jb_trustcache_grow
IOSurface_kalloc
```

`SIGEMT` 最终发生在 `IOSurface_kalloc` 内。该证据把问题限定在 PID 1 中由并发信任请求触发的 trust-cache 扩容与 IOSurface 生命周期，而不是 credential 或普通 App。

### B1 根因

旧实现同时存在以下缺陷：

1. `IOSurfaceCreate()` 返回的 `IOSurfaceRef` 只执行 `IOSurfaceDecrementUseCount()`，没有平衡 `CFRelease()`；global kalloc 将 ranges 从 IOSurface 脱离后仍永久保留 Mach send right。每次新建 16 KiB trust-cache 页都会把 IOSurface 对象和相关 VM 资源积累在 launchd 中。
2. trust-cache 查询、追加、清空和整表上传没有共享锁。多个 XPC event 可同时选择同一个空闲页、排序并覆盖整页，或在链表替换/释放期间遍历它。
3. 收集 CDHash 与写入之间没有锁内二次去重；同一批次也不去重，重复信任请求会不必要地扩容 global kalloc。
4. 输入跨过一个 trust-cache 页时，旧循环始终从 `entries[0]` 复制，后续页会重复首段条目。
5. `_jb_trustcache_grow()` 失败返回零地址后，调用方仍继续读写；多条 kernel read/write/list-insert 失败也被吞掉并向 XPC 报告成功。
6. 每次追加在栈上分配完整 trust-cache 页；在 launchd 的 XPC worker 中没有必要承担该栈压力。

### B1 修复

- IOSurface dummy page 通过 `dispatch_once` 初始化；检查用户区分配、CF 对象、Mach port、send right、surface 和 kernel read/write 结果。
- 平衡释放临时 `IOSurfaceRef`。global kalloc 只有在 ranges 与 range count 成功脱离后才释放 Mach send right；中间写失败时保留对象或停止，避免返回已经失效的内核地址。
- trust-cache 查询、追加、清空和整表上传共用 `os_unfair_lock`。锁内重新检查 live trust-cache，并过滤批内重复 CDHash。
- 使用累计 `insertedEntryCount` 修正跨页输入偏移；完整页临时缓冲和 CDHash entry 数组改为 heap allocation，并在不可回收的 kernel allocation 之前完成用户态页分配。
- 校验现有页 length、扩容地址和读回 length；区分 `ENOMEM`、`EIO`、`EINVAL` 并沿 local、systemwide、RootHide XPC 调用链向上返回。
- trust-cache 信息与调试读取也限制动态页 length，损坏页不会驱动 PID 1 越界遍历。
- 链表头、next/prev、整表内容和 clear 的 kernel 写入均检查返回值。插入或初始化失败后不继续访问零地址。

扩容已经完成 kernel allocation、但后续 kernel 写入或链表插入失败时，无法证明该对象对所有内核读者都不可达，因此 B1 选择不做危险回滚，最多保留一次 16 KiB allocation。该有限错误路径泄漏优先于释放仍可能被引用的 trust-cache 页；正常成功路径不再保留 IOSurface/Mach right。

产物标记：

```text
TRUSTCACHE-IOSURFACE-18B1
```

### 3.0.27 回归要求

构建核验必须确认 3.0.27、arm64/arm64e 切片，以及以下三个标记进入最终 `basebin.tar`：

```text
UCRED-SMR-18A5
TRUSTCACHE-IOSURFACE-18B1
RESPRING-IOS18-BBD1
```

设备覆盖安装后必须由用户完成以下验证：

1. 确认 `/basebin/.version = 3.0.27`，并记录 `/basebin/.build`。
2. 正常使用 Sileo 刷新与安装、Zebra、OpenSSH/SSH、Frida，以及会触发递归 Mach-O 信任的插件安装流程。
3. 观察 launchd 内存是否仍持续异常增长，并检查是否再次出现 `initproc exited / namespace 1 / subcode 0x7`。
4. 同时继续观察旧的 `ucred_rw / smr.c:2831` 是否复现；B1 不改变 A5 credential 设计。
5. 构建成功和短时可用都不能宣布问题关闭，必须经过真实设备的持续稳定性观察。

### 3.0.27 构建记录

待 GitHub Actions 构建与产物核验后补充。

## 18. 3.0.28：第三方动态 trust-cache 持久恢复

### 问题边界

3.0.27 保证动态 trust cache 的内核创建、扩容、写入和并发更新稳定，但动态页仍只存在于内核内存。完整重启后，TrollFools、包管理器、签名工具和其他 RootHide API 调用方此前登记的 CDHash 会消失；App 容器中的 Loader、插件和依赖文件仍然存在。dyld 随后能解析文件路径，AMFI 却会拒绝映射未重新受信的 CDHash，表面上可能显示闪退或误导性的 `Library missing`。

这不是 TrollFools 专属问题，也不应通过扫描 Telegram 等普通 App 容器、创建 `_TrollStoreLite` 标记、保存工具专属路径或降低 AMFI/签名校验来解决。正确的所有权边界是 `jb_trustcache_add_entries()`：所有成功通过 RootHide 动态信任入口登记的第三方条目都在此处统一持久化。

### C1 设计

- 注册表位于 `JBROOT_PATH("/var/mobile/Library/RootHide/dynamic-trustcache-v1.bin")`。它跟随 RootHide 可写 AppGroup 的 brand 重命名，不依赖设备特定 `.jbroot-*` 路径。
- 文件保存完整 `trustcache_entry_v1`，包含 magic、格式版本、头大小、条目大小、条目数、头部 CRC32 和负载 CRC32。最大条目数固定为 32768；异常大小、重复/乱序 hash、截断、尾随数据或校验失败均拒绝加载。
- 锁文件与注册表继承 RootHide 目录的 `mobile:mobile` 所有权并保持 `0600`，确保 PID 1 写入后下次 Dopamine 激活仍可读取，同时不开放给其他 UID。写入使用同目录临时文件、完整写循环、`F_FULLFSYNC`/`fsync` 和原子 `rename`；目录同步在文件系统支持时执行，iOS 明确返回 `EINVAL/ENOTSUP` 时不把已完成的原子替换误报为失败。独立锁文件协调 Dopamine 激活进程与 launchd 中的后续登记。
- 内核 trust-cache 修改仍只在 `gJbTrustCacheLock` 下执行；磁盘 I/O 在该 unfair lock 之外。新增、恢复和显式 clear 另由操作级 mutex 串行化，避免 `clear` 与新增在同一进程内交错。
- 内核更新成功后持久化调用方显式请求的全部条目，而不只保存本次 live cache 中的新条目。这样一次落盘失败后，调用方重试能够补写注册表，即使 CDHash 已在当前内核页中。
- 若内核追加只完成一部分后失败，只镜像已经实际插入的前缀，并向调用方返回内核错误。持久化失败不会撤销当前内核信任，但会返回 errno 并写入统一日志标记，调用方不得把它当作完整成功。
- Dopamine 在 `load_basebin_trustcache()` 之后、注入 launchdhook 之前一次性读取并恢复注册表。恢复调用内部插入函数，明确关闭再次持久化，避免递归写盘。
- 首次原地升级时，恢复器还会枚举当前内核中已有的 `jb_trustcache` 动态页并合并进注册表，从而自动迁移 3.0.27 本次开机仍存活的第三方条目。固定 UUID trust cache 不属于该页类型，因此不会被导入。
- basebin 与 dyld 固定 UUID trust cache 继续使用 `trustcache_file_upload_with_uuid()`，不会进入第三方动态注册表。
- `jbctl trustcache clear` 只有在内核动态页清空成功后才原子写入空注册表。清空注册表失败会向调用方返回错误，旧注册表不会被静默视为已清除。

注册表按授予过的 CDHash 管理，不保存文件路径，也不主动判断文件是否仍存在。旧 CDHash 会保留到显式 `trustcache clear`；这是避免扫描任意 App 容器和避免工具专属耦合的直接代价。达到 32768 项时拒绝继续持久化并返回 `ENOSPC`，不得静默淘汰仍可能需要的信任。

产物标记：

```text
TRUSTCACHE-PERSIST-18C1
```

### 升级与验证要求

3.0.28 能在原地升级激活时自动迁移当前内核动态页。它无法追溯在安装前已经因完整重启而消失、且之后没有重新登记的历史 CDHash；这种情况下对应工具仍需成功执行一次正常信任流程。首次持久性重启测试前必须确认注册表已经包含目标 CDHash，不得把安装前就不存在的条目误判为恢复器失效。

构建核验必须确认 3.0.28、arm64/arm64e 切片，以及以下标记进入最终 `basebin.tar`：

```text
UCRED-SMR-18A5
TRUSTCACHE-IOSURFACE-18B1
TRUSTCACHE-PERSIST-18C1
RESPRING-IOS18-BBD1
```

设备验证必须由用户分别授权覆盖安装和完整重启，并至少完成：

1. 安装前记录当前动态 CDHash；安装 3.0.28 后，让 TrollFools 及至少一个其他 RootHide 信任调用方各执行一次正常登记。
2. 检查注册表为普通 `0600` 文件，校验格式、条目数及目标 CDHash；不得修改 App 容器或创建 TrollStore 标记来辅助测试。
3. 完整重启并重新月余后，在启动这些第三方工具之前检查目标 CDHash 已恢复到动态 trust cache。
4. 直接启动先前注入的 App，确认 Loader、插件和依赖可映射；同时检查 `TRUSTCACHE-PERSIST-18C1` 恢复日志。
5. 显式执行 `trustcache clear` 的破坏性回归必须另行授权；若执行，应确认当前动态页与持久注册表同时清空，下一次激活不会恢复旧条目。
6. 构建成功、注册表生成或单次 App 启动均不能单独宣布修复完成，必须通过完整重启周期。

### 3.0.28 构建记录

GitHub Actions 全量构建：

```text
run: 32555605294
source commit: af268932da9299c76f9b01e62d1ca4cafdd57fe5
artifact id: 9471335544
artifact: roothide-Dopamine-3.0.28-af26893.tipa
artifact ZIP SHA-256: d2c10a0aafc2c945f46dc41ff2d9f9fdd0fea6d9dbcb5ca68f4cece9079e4295
TIPA SHA-256: 24fec01c397673b0f05911f8a4c0e1663a57138d78b20b35df832cfde4fcd709
```

独立核验结果：外层 artifact ZIP 与 GitHub digest 完全一致；TIPA 含 131 项、内嵌 `basebin.tar` 含 31 项，均无不安全路径；App 标识为 `com.opa334.Dopamine-roothide`，版本为 3.0.28；内嵌 `.version` 为 3.0.28，`.build` 与 source commit 一致；部署用 `libjailbreak.dylib`、`jbctl`、`systemhook.dylib` 均含 arm64 与 arm64e；`UCRED-SMR-18A5`、`TRUSTCACHE-IOSURFACE-18B1`、`TRUSTCACHE-PERSIST-18C1`、`RESPRING-IOS18-BBD1` 均存在于对应最终 Mach-O。当前状态为静态与构建验证通过，设备安装、注册表生成和完整重启恢复仍未验证。

## 19. 3.0.29：trust-cache 分配生命周期与主路径恢复

### 3.0.28 真机结果

3.0.28 已被真机证伪。月余可能在中途触发完整重启；偶尔代码执行完成后黑屏两三分钟才进入桌面，随后系统明显卡顿。完整重启并重新月余后，先前由 TrollFools 等工具注入的普通 App 仍可能因目标 CDHash 不在动态 trust cache 中而无法启动。

`panic-base-2026-08-22-142549.ips` 的关键证据为：

```text
pmap_tt_deallocate(): ... count 4918 @pmap.c:5673
Kernel Extensions in backtrace: com.apple.iokit.IOSurface
Compressor 19% (OK)
```

这属于 IOSurface memory descriptor 析构期间的页表计数损坏，不是 OOM。B1 在 ranges 与 range count 脱离后立即 `mach_port_deallocate()`；iOS 18 的 IOSurface 析构仍会处理内部 descriptor，因此已链接到 trust-cache 链表的 backing allocation 会与 descriptor 销毁发生冲突。

设备上的 3.0.28 注册表本身有效：magic 为 `RHTCREG1`、版本 1、entry size 22、entry count 185、权限 `mobile:mobile 0600`。但用户点击月余按钮走 `Application/Dopamine/Jailbreak/DOJailbreaker.m`，3.0.28 的恢复调用只存在于独立 `BaseBin/dopamine/src/main.m`，所以实际主路径加载 basebin trust cache 后直接注入 launchdhook，没有读取这份注册表。

Telegram 当前 `MtProtoKitFramework` 的 CDHash `a202c0c39cdf9c01e755ab4a22588b4d57886531` 既不在该注册表，也不在 live cache；它不是恢复阶段丢失，而是此前从未成功持久登记。`CydiaSubstrate` 的 arm64e CDHash `c63fd92bb489dd50f404fad75d221c561d433a45` 已在注册表。恢复器只能恢复已经授予并落盘的 CDHash，不能从不存在的历史内核状态推导文件清单。

### B2/D1 设计

- 当 kcall 与 `kalloc_data_external` 可用时，所有 global `kalloc()` 直接使用真正的内核 allocator，并传入 `Z_WAITOK`（数值 0）；不得传入 `1`，因为在 XNU 11215 中它是 `Z_NOWAIT`，会令启动压力下的有界恢复随机返回空指针。固定 basebin/dyld trust cache、动态页和持久恢复均不再依赖进程持有的 IOSurface/Mach right。没有 kcall 的旧设备继续使用 IOSurface 兼容回退，但成功摘出的 global allocation 不再立即触发 descriptor 析构。
- 原地升级时，现存 trust-cache 页可能由 3.0.28 的 IOSurface 回退创建，而新页来自 `kalloc_data_external`。页内没有 allocator provenance，因此替换固定 UUID trust cache 时只从链表摘除旧页，本次 boot 内不调用任何释放器；把 IOSurface 页交给 `kfree_data_external` 或反向混用都可能破坏内核。该有界泄漏在下次完整重启时自然消失。
- 持久恢复从短生命周期 Dopamine 进程移到 launchdhook。launchd 先通过 boomerang 恢复 primitives，再读取注册表并恢复第三方条目。
- boomerang 完成消息新增 `completion-result`。launchd 只有在恢复完成后才通知按钮端；恢复 errno 会返回 `injectLaunchdHook`，UI 不再把未恢复的环境当成成功。恢复失败只记录并返回，不主动 abort PID 1。
- 注册表 merge 先规范化本次请求，再与已有有序条目线性合并；同 hash 的新显式授权覆盖旧元数据，同一批次里 hash 相同但 `hash_type/flags` 冲突则返回 `EINVAL`。只有条目数和完整 entry 内容都一致时才跳过原子重写与 full sync。
- 恢复仍位于通用 `jb_trustcache_add_entries()` 所有权边界，不扫描 Telegram 或其他普通 App 容器，不依赖 `_TrollStoreLite`，也不保存 TrollFools 专属路径。

3.0.28 产物的 LC_UUID 复核结果：`43bc3f75-8bb4-318d-846e-b86b7aee7f88` 是 `libjailbreak.dylib`，`228aaa11-6098-3a19-8326-5b5abb44f526` 是 `launchdhook.dylib`；SIGTRAP 触发线程使用的 `39968232-6191-3a4c-a577-845246f43357` 不存在于 App 或 `basebin.tar` 的任何 Mach-O 中，属于系统共享缓存镜像，不能再把 image 15 误标成 launchdhook。独立的 `pmap_tt_deallocate` panic 与 IOSurface 内核 backtrace 仍是 B2 的直接证据。

产物标记：

```text
TRUSTCACHE-KALLOC-18B2
TRUSTCACHE-PERSIST-18C1
TRUSTCACHE-PERSIST-18D1
```

### 3.0.29 构建记录

```text
commit: 045faeb62a76fa1a011582d8943730b6e4ba450a
workflow run: 32560952417
workflow URL: https://github.com/riboly/Dopamine3-RootHide/actions/runs/32560952417
artifact id: 9472776011
artifact: roothide-Dopamine-3.0.29-045faeb.tipa
artifact ZIP SHA-256: 4d3255ad5ad6b083678ba77fcc3f2bb30f1806dcd8b7d4a2d8788f5b537d4b1b
TIPA SHA-256: 903bd021789ab9920edc40be92ead8fff020dd2402bf7582e63f22fe3591c64e
status: STATICALLY VERIFIED; device installation and reboot-cycle validation pending
```

独立产物核验：TIPA 含 131 项、`basebin.tar` 含 31 项，ZIP CRC 与路径安全检查通过；App/basebin 版本均为 3.0.29，`.build` 与 commit 一致；`libjailbreak.dylib`、`jbctl`、`launchdhook.dylib`、`systemhook.dylib` 均含 arm64 与 arm64e；五个运行时标记全部存在。该结果不等价于真机稳定性验证。

### 3.0.29 验证要求

1. 构建产物必须包含 3.0.29、arm64/arm64e 切片及 `UCRED-SMR-18A5`、`TRUSTCACHE-KALLOC-18B2`、`TRUSTCACHE-PERSIST-18C1`、`TRUSTCACHE-PERSIST-18D1`、`RESPRING-IOS18-BBD1`。
2. 覆盖安装前记录注册表和 live cache。安装后先让 Telegram 对应工具及至少一个其他 RootHide 动态信任调用方成功登记一次；必须先证明目标 CDHash 已进入注册表。
3. 对安装前已经丢失且注册表中从未存在的 CDHash，先由原工具重新信任或重新注入一次。不得把这种历史缺项当成恢复器能够凭空重建的文件条目。
4. 经用户单独授权后执行完整重启并重新月余。在启动 TrollFools、目标 App 或其他登记工具之前，检查目标 CDHash 已经恢复到 live dynamic trust cache，并核对 `TRUSTCACHE-PERSIST-18D1` 成功日志。
5. 直接启动先前注入的 App，确认 Loader、插件和依赖均可映射；继续观察是否出现 IOSurface `pmap_tt_deallocate`、月余中途自动重启、异常长黑屏或系统卡顿。
6. 构建成功只能标记为静态验证；只有上述完整重启周期和持续稳定性观察均通过，才能标记为设备修复完成。
