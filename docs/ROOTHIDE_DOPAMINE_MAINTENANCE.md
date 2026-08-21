# Dopamine3-RootHide 维护与修复报告

本文档记录 `riboly/Dopamine3-RootHide` 的关键架构、安全边界、已确认故障及发布验证流程，供后续维护使用。当前维护分支为 `roothide-3.x`。

## 1. 当前已验证状态

| 版本 | 变更 | 设备结果 |
| --- | --- | --- |
| 3.0.21 | 修复 RootHide setid donor 握手 | Sileo 源名称、更新、安装全部正常；Zebra 正常启动和使用 |
| 3.0.22 | 修复重启后重新月余导致用户软件源丢失 | 用户已确认 `sileo.sources` 与 `roothide-release.sources` 生效，软件源持久化正常 |
| 3.0.23 | 修复 iOS 18 `ucred` SMR 生命周期和异常 respring | 代码与构建验证后仍需设备覆盖安装、重新月余、respring 和稳定性观察 |

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

### 设备验证

覆盖安装后重新月余，至少验证：

1. Sileo 刷新与安装、Zebra 启动、`sudo -n id` 等 root-spawn 路径仍正常。
2. 多次正常安装/卸载小型软件包后没有 `donor-ucred-copy` 错误。
3. 观察期内不再出现相同 `smr.c:2831` panic。
4. 如仍有 panic，必须按新的 panic string 和 `item/linkage` 重新分类，不能直接归因于本次旧日志。

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
