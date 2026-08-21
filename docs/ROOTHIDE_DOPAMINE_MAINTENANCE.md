# Dopamine3-RootHide 维护与修复报告

本文档记录 `riboly/Dopamine3-RootHide` 的关键架构、安全边界、已确认故障及发布验证流程，供后续维护使用。当前维护分支为 `roothide-3.x`。

## 1. 当前已验证状态

| 版本 | 变更 | 设备结果 |
| --- | --- | --- |
| 3.0.21 | 修复 RootHide setid donor 握手 | Sileo 源名称、更新、安装全部正常；Zebra 正常启动和使用 |
| 3.0.22 | 修复重启后重新月余导致用户软件源丢失 | 代码与构建验证完成后，必须执行一次真实重启和重新月余回归 |

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

只有完整通过一次设备重启循环，才能将源持久化问题标记为已解决。

## 9. 月余检测结论

此前“很多 App 仍检测到月余”不是旧 rootless 环境残留。用户在 RootHide 中为对应 App 打开隐藏开关后已完全解决，因此该方向已关闭，不需要添加 App 特定绕过，也不应清理 TrollStore/TrollFools 数据。
