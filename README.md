# PosterDrop

把 **PosterBoard 动态壁纸包（`.tendies`）** 导入手机并直接「装进系统」，无需越狱、无需电脑中转。

PosterDrop 只做一件事：**导入动态壁纸 → 注入 → respring → 立刻可用**。

- 全部操作在 iPhone 本地完成（Airlift 通道 + 本机回环隧道）
- 支持 `.tendies` / `.zip` / 整容器归档，自动识别 Collections / Mercury / Photos / Kaleidoscope / Unity 五类壁纸
- 自动抽取预览图、判定描述符数量、双写 iOS 18+ 的新容器
- 内置配对管理、容器探测、缓存刷新、NeoSpring respring、运行日志

> 仅供安全研究与个人设备定制使用。请只在你自己拥有或获授权管理的设备上运行。

---

## 一、兼容性

| 系统版本 | 状态 | 配对方式 |
| --- | --- | --- |
| iOS 27.0 – 27.2 beta 2 | ✅ 支持 | 本机配对 / 导入配对文件 |
| iOS 18.0 – 26.x | ✅ 支持 | 仅导入配对文件 |
| iOS 27.2 beta 3 及以后 | ❌ 已修复 | Apple 在 AirTraffic 同步链路上打了补丁 |

前置条件：

1. **LocalDevVPN / WireGuard 回环模式**：隧道地址 `10.7.0.1`，Airlift 默认往这里拨号。
2. **一份有效配对记录**：SideStore / LiveContainer / 电脑导出，或 iOS 27+ 的本机配对。
3. 设备已解锁（首次注入时系统会校验数据保护状态）。

---

## 二、它是怎么工作的

整条链路分三段，缺一不可：

### 1. 配对：拿到设备自己的调试凭据

App 在本机启动一个 RPPairing host，通过 Bonjour 广播 `_remotepairing-pairable-host._tcp`。
iOS 27+ 可以在「设置 › 隐私与安全性 › 开发者模式」里输入 6 位 PIN 完成自配对；iOS 18–26 只能导入已有的配对文件（本质是 lockdown 的 `HostID / SystemBUID / RootCertificate` 等字段）。

配对记录 = 设备调试凭据，等价于把「电脑上的 iTunes/Xcode 权限」搬进 App 沙盒。**不要外传。**

### 2. 隧道：连上设备内部的 AirTraffic 服务

Airlift 通过 RSD（Remote Service Discovery）连到 `10.7.0.1`，再用配对凭据换取 lockdown 会话，进而找到 `com.apple.PosterBoard` 的**真实数据容器**：
`/var/mobile/Containers/Data/Application/<UUID>`。

### 3. 注入：把 descriptor 写进 PosterBoard 的存储

PosterBoard 把每张壁纸存成一组描述符目录：

```
<容器>/Library/Application Support/PRBPosterExtensionDataStore/<61|59>/Extensions/<bundleID>/descriptors/<UUID>/
├── versions/…
├── providerInfo.plist
├── Wallpaper.plist
├── com.apple.posterkit.provider.descriptor.identifier
└── com.apple.posterkit.provider.contents.userInfo
```

PosterDrop 做四件事：

1. 解开 `.tendies`（zip），递归找出所有 descriptor 目录（判据：含 `versions/`、`providerInfo.plist`、`Wallpaper.plist` 之一）；
2. **随机化标识**（只改纯数字标识，保留 `v6x.colorA` 这类符号标识，否则 Mercury/Unity 会失效）；
3. 调用 `al_exploit_inject_folder` 把目录原子注入，iOS 18+ 再往 `com.apple.Posters.<Name>App` 双写一份；
4. 写入 `com.apple.PosterBoard.unprotectedUserDefaults.plist`（`PBF_RESET_FILE_PROTECTIONS` 等键），强制系统重新索引，最后用 **NeoSpring** 打崩 SpringBoard 让壁纸立刻出现。

数据流示意：

```
.tendies ──解压──> descriptor 目录 ──随机化──> AirTraffic 注入 ──> PosterBoard 存储
                                                        │
                                          写 Preferences ┘──> NeoSpring respring ──> 锁屏可选
```

---

## 三、从两个项目里学到的关键点

### [GestaltX](https://github.com/huamidev/GestaltX)（MobileGestalt 编辑器）

GestaltX 编辑的是 `com.apple.MobileGestalt.plist` 这类「能力开关」文件，底层用 [worse_query](https://github.com/forcequitOS/worse_query) 做容器逃逸（可写 `/var/containers/Data/System`、`/var/mobile/Containers/Shared/AppGroup` 等）。三个工程化经验被直接沿用：

- **写前必备份**：任何一次写系统文件前先留原始值，能回滚才敢改；
- **写入后要校验**：写完重新读一遍确认字节落地（Airlift 的 canary 写入就是同一思路）；
- **改完要 respring**：SpringBoard 不重载，改了等于没改；
- 同时它也说明了这类方案的边界：系统版本一动（如 iOS 26 → 27 的容器布局变化），路径和结构版本号就得跟着适配。

PosterDrop 把「备份 + 校验 + respring」落成了：结构版本可选（59/61）、注入后写缓存标记、respring 双通道（NeoSpring / 诊断中继）。

### [AirCard-iOS](https://github.com/Mak5er/AirCard-iOS)（重点学习对象）

AirCard 的 **PosterBoard 壁纸（Tendies）** 模块是这条链路最完整的公开实现，PosterDrop 学习并复刻了它的核心逻辑：

| 环节 | AirCard 的做法 | PosterDrop 的处理 |
| --- | --- | --- |
| 包的解压 | `al_zip_extract_all`（Rust 侧 zip 解析） | 同 |
| descriptor 识别 | 路径/元数据/标识文件三重判据 | 同，并抽成 `ArchiveInspector` |
| 类型判定 | `Extensions/<bundleID>` + `suggestionMetadata.plist` + 路径关键字 | 同 |
| 标识随机化 | 仅纯数字才改，避免破坏符号查表 | 同（含详细注释） |
| 注入路径 | `…/PRBPosterExtensionDataStore/<ver>/Extensions/<ext>/descriptors/<UUID>` | 同 |
| 双写 | iOS 18+ 额外写 `.Posters.<Name>App` | 同，可选开关 |
| 缓存刷新 | 写 `unprotectedUserDefaults.plist` 的 `PBF_RESET_FILE_PROTECTIONS` | 同 |
| respring | NeoSpring（WebKit GPU 崩溃） | 同，另加诊断中继兜底 |

差异在于 PosterDrop 把「壁纸」这一件事拆干净了：没有钱包卡面、没有密码键盘主题，换来更完整的库管理（多选、批量、预览、失败逐条报告）和更可诊断的过程日志。

底层 `AirliftFFI.xcframework`（Rust 静态库，MIT）来自 AirCard-iOS 仓库，由 `scripts/fetch-vendor.sh` 在构建时按固定 commit 拉取；[Airlift](https://github.com/0xjohnnydev/airlift) 的 AirTraffic/ATAirlock 研究是这一切的基础。

---

## 四、目录结构

```
PosterDrop/
├── project.yml                    # XcodeGen 工程定义
├── scripts/
│   ├── fetch-vendor.sh            # 拉取 AirliftFFI.xcframework（固定 commit）
│   └── build-ipa.sh               # 编译 + 打包未签名 IPA
├── .github/workflows/build.yml    # GitHub Actions：出 IPA 产物 / 发 Release
├── Design/AppIcon-1024.png        # 图标源文件
├── Config/                        # 预留（本地签名配置等）
└── PosterDrop/
    ├── App/
    │   ├── PosterDropApp.swift    # 入口，bootstrap Airlift
    │   └── AppModel.swift         # 状态与业务编排
    ├── Core/
    │   ├── AirliftBridge.swift    # C FFI 的 Swift 封装
    │   ├── ArchiveInspector.swift # 解压 / descriptor 发现 / 预览图
    │   ├── PosterBoardInstaller.swift # 注入 + 缓存刷新
    │   ├── WallpaperStore.swift   # 本地库与索引
    │   ├── WallpaperItem.swift    # 数据模型
    │   ├── PairingStore.swift     # 配对文件导入 / 发现
    │   ├── OnDevicePairing.swift  # 本机配对（Bonjour + PIN）
    │   ├── LocalNetworkPermission.swift
    │   ├── BackgroundKeepAlive.swift
    │   ├── TunnelStatus.swift     # 10.7.0.1 隧道探测
    │   ├── Respring.swift         # NeoSpring
    │   └── LogBus.swift
    ├── UI/                        # SwiftUI 界面（壁纸 / 配对 / 诊断）
    └── Resources/                 # Info.plist、图标、配色
```

---

## 五、构建

### 用 GitHub Actions（推荐，无需 Mac）

1. 把仓库推到 GitHub；
2. Actions 会自动跑 `Build IPA`（也可手动 `workflow_dispatch`）；
3. 在运行记录的 **Artifacts** 里下载 `PosterDrop-ipa`，解压得到 `PosterDrop.ipa`；
4. 打 tag（`v1.0.0`）推送会自动把 IPA 附到 Release。

工作流做的事：`fetch-vendor.sh` → 安装 XcodeGen → `xcodegen generate` → `build-ipa.sh Release` → 上传产物。

### 本地构建（需要 macOS + Xcode 16+）

```bash
brew install xcodegen
./scripts/fetch-vendor.sh
xcodegen generate
./scripts/build-ipa.sh Release
# 产物：build/PosterDrop.ipa（未签名）
```

### 安装

产物是**未签名 IPA**，需要自签工具安装：

- SideStore / AltStore：直接导入 IPA，用你的 Apple ID 重签；
- TrollStore：直接安装；
- Sideloadly / iOS App Signer：自签后安装。

> 首次打开需要允许「本地网络」，否则配对与本机通信都会失败。

---

## 六、使用步骤

1. **连隧道**：打开 LocalDevVPN，确认本机拿到 `10.7.0.1`（App 的「配对」页会显示隧道状态）。
2. **配对**：
   - iOS 27+：配对页 → 开始本机配对 → 记下 6 位 PIN → 设置 › 隐私与安全性 › 开发者模式 › 与 PosterDrop 配对 → 输入 PIN；
   - iOS 18–26：配对页 → 导入配对文件（SideStore 的 `ALTPairingFile.mobiledevicepairing` 等）。
3. **导入壁纸**：壁纸页 → 导入壁纸（或把 `.tendies` 放进「文件 › 我的 iPhone › PosterDrop」，再点「扫描文档」）。
4. **应用**：勾选 → 应用所选（或单张长按/详情页应用）。注入完成后自动 respring。
5. **选用**：锁屏长按 → 自定义 → 墙纸，或「设置 › 墙纸」里选择新出现的壁纸。

建议第一次只在「诊断」页点一次 **自动探测**，把容器路径缓存下来，后续应用会更快。

---

## 七、常见问题

**Q：提示「未检测到 10.7.0.1」**
A：LocalDevVPN 没连上，或没开回环模式。先连 VPN，再回「配对」页刷新状态。

**Q：配对一直失败 / 收不到 PIN**
A：确认「本地网络」权限已开；iOS 27 需要先在设置里打开开发者模式；从「设置」返回 App 时别急着切后台（App 用静音音频保活，属正常现象）。

**Q：注入成功但壁纸里看不到**
A：依次尝试「刷新壁纸缓存」→ NeoSpring respring → 打开墙纸设置后下拉。仍不行就检查「诊断」里的结构版本是否为 61，以及日志中是否出现 `写入 …/Preferences 失败`。

**Q：能不能只导入不动系统？**
A：可以，导入和预览完全不碰系统；只有点「应用」才会写 PosterBoard。

**Q：升级系统后失效？**
A：iOS 27.2 beta 3 起 Apple 已修复 AirTraffic 同步漏洞，升级即失效，且不可逆。升级前请勿更新。

---

## 八、免责声明与许可

- 本项目仅用于**安全研究与个人设备定制**，请仅在你自己拥有或获授权管理的设备上使用。
- 修改系统 App 数据可能导致壁纸异常、SpringBoard 崩溃甚至需要恢复系统，请自行承担风险，操作前备份。
- 本项目**不涉及**绕过激活锁、绕过 Apple ID、破解付费内容等行为。

许可：

- PosterDrop 本体：MIT
- `AirliftFFI.xcframework`：来自 [AirCard-iOS](https://github.com/Mak5er/AirCard-iOS)（MIT），底层为 [Airlift](https://github.com/0xjohnnydev/airlift)
- NeoSpring：[neonmodder123](https://github.com/neonmodder123) / [skadz108](https://github.com/skadz108) / [rooootdev](https://github.com/rooootdev)
