# PosterDrop

把 **PosterBoard 动态壁纸包（`.tendies`）** 导入设备并直接「装进系统」，无需越狱、无需电脑中转。

PosterDrop 只做一件事：**导入动态壁纸 → 注入 → respring → 立刻可用**。

- 全部操作在 iPhone / iPad 本地完成：配对隧道（Airlift/AirTraffic）或直连通道（container 沙箱扩展），二选一
- 通用 App（`TARGETED_DEVICE_FAMILY = 1,2`）：同一份 IPA 装 iPhone 和 iPad，iPad 支持四方向、分屏、台前调度与拖放导入
- 支持 iOS / iPadOS 18.0 – 27.2 beta 2（隧道）/ 26.0 – 27.2（直连，需签名带 App Groups），详见[兼容性](#一兼容性)
- 支持 `.tendies` / `.zip` / 整容器归档，自动识别 Collections / Mercury / Photos / Kaleidoscope / Unity 五类壁纸
- 自动抽取预览图、判定描述符数量、双写 iOS 18+ 的新容器
- 内置配对管理、容器探测、缓存刷新、NeoSpring respring、运行日志

> 仅供安全研究与个人设备定制使用。请只在你自己拥有或获授权管理的设备上运行。

---

## 一、兼容性

### 1.1 应用本体

| 项目 | 要求 |
| --- | --- |
| 系统 | **iOS / iPadOS 18.0 及以上**（部署目标 `IPHONEOS_DEPLOYMENT_TARGET = 18.0`） |
| 机型 | **iPhone + iPad**（`TARGETED_DEVICE_FAMILY = 1,2`），iPad 支持四方向、分屏、台前调度 |
| 架构 | arm64（AirliftFFI 只带 arm64 切片，模拟器仅 arm64） |
| 安装 | 未签名 IPA，需 SideStore / AltStore / Sideloadly / TrollStore 自签 |

**iPad 适配说明**

- iPhone 与 iPad 共用同一个 bundle、同一份 IPA，签名流程完全一致（iPad 也需要在重签工具里勾上 App Groups）。
- 界面：iPad 全宽时页签变成侧边栏；内容限制在 760pt 版心内居中，壁纸列表按窗口宽度自动单列 / 双列。
- 窗口：`UIRequiresFullScreen` 已移除，可在分屏、Slide Over、台前调度里任意缩放；窄窗口自动退回底部标签栏和单列布局。
- 导入：除「导入壁纸」外，iPad 上可直接从“文件”App 把 `.tendies` 拖进壁纸页。
- 注入：隧道 / 直连两条通道与 iPhone 共用同一套代码，能否使用只取决于 **iPadOS 版本**（见 1.2），与机型无关。直连通道的公开实测记录都来自 iPhone，iPad 尚未单独验证，建议先跑「诊断 › 自检通道」。

### 1.2 两条通道 × 系统版本

两条通道互相独立：**任意一条可用就能完成注入**。默认走配对隧道，直连通道需在「诊断 › 直连通道」手动开启。

| iOS 版本 | 配对隧道（Airlift / AirTraffic） | 直连通道（App Group 沙箱扩展） |
| --- | --- | --- |
| 17.x 及更早 | ❌ 低于部署目标 | ❌ 低于部署目标 |
| 18.0 – 25.x | ✅ | ❌ 没有这条签发缺陷，只能用隧道 |
| 26.0 – 26.6.1 | ✅ | ✅（App Group 查询用备用 flags） |
| 26.7 – 26.7.2 | ✅ | ✅（WQFiles 实测 26.7.1） |
| 27.0 – 27.2 beta 2 | ✅ | ✅（WQFiles 实测 27.0.1、27.2） |
| **27.2 beta 3 – 27.2** | ❌ **AirTraffic 已被修补** | ✅ 仍可用，走的是另一处缺陷 |
| 27.3 及以后 | ⚠️ 未验证 | ⚠️ 未验证 |

> 「✅」= 有公开实现或实测记录；「⚠️」= 没有设备验证，请先跑自检；「❌」= 明确不可用。
>
> 两处补丁要分开看：**AirTraffic 同步链路**在 27.2 beta 3 被 Apple 修掉（AirCard-iOS 的 README 有记录），
> 影响的是配对隧道；**container 签发缺陷**是另一条路（[WQFiles](https://github.com/kolbicz/WQFiles) 在 27.2 上实测可用），
> 所以这一版升级后隧道报废、直连仍可用。

### 1.3 各通道前置条件

**配对隧道**

1. LocalDevVPN / WireGuard 回环模式，隧道地址 `10.7.0.1`；
2. 一份有效配对记录（SideStore / LiveContainer / 电脑导出，或 iOS 27+ 本机配对）；
3. 设备已解锁（首次注入会校验数据保护状态）。

**直连通道**

1. 不需要配对记录，不需要 VPN；
2. 需要系统仍存在 container 签发缺陷（见 1.2 表）；
3. **签名里必须带 `com.apple.security.application-groups`**。这条是硬要求，不是可选项：
   containermanagerd 只对 App Group 容器返回查询结果，自身容器（class 2）拿不到 token。
   - 用 **轻松签 / ESign** 重签时勾选 App Groups，填任意一个 profile 允许的 group（如 `group.com.posterdrop.app`）；
   - **Sideloadly 不会加 App Groups**，直连会直接报「签名里没有可用的 App Group」；
   - 免费 Personal Team 在 Xcode 27 上通常也能签出 App Groups（[filza-wq](https://github.com/MchinaMd57764/filza-wq) 实测），但会随证书 7 天过期；
   - 应用会自动读签名里的 group，不需要手填；填了则以手填的为准。
4. 设备已解锁。

### 1.4 容器是怎么找到的

这里有个反直觉的点：**拿到扩展也列不出 `Data/Application` 父目录**——token 是按具体容器签发的，父目录本身不是容器。
所以不能靠遍历找 PosterBoard，程序按四级顺序定位（日志里会逐条打印）：

| 顺序 | 方法 | 说明 |
| --- | --- | --- |
| ① | 手动路径 | 诊断页里粘贴容器路径（WQFiles 的 App Data 里能看到 `com.apple.PosterBoard`） |
| ② | containermanagerd 枚举 | 遍历 class 1–14，用 `container_object_get_identifier` 匹配 |
| ③ | LaunchServices | `LSApplicationWorkspace` 取 `dataContainerURL` |
| ④ | 按 bundle id 查询 | `container_query_set_identifiers(class 2)`，多数系统会拒绝 |

命中后还会验证 `<容器>/Library/Application Support/PRBPosterExtensionDataStore` 是否真实存在，只有这一步通过才算可用。

### 1.5 怎么确认自己这台能用

打开「诊断 › 直连通道 › 自检通道」，输出含义：

| 输出 | 含义 |
| --- | --- |
| `签名内 App Groups：group.xxx` | 签名带 App Groups，这是直连的前提 |
| `签名内 App Groups：无` | 重签时没勾 App Groups，直连一定失败，换签名工具 |
| `✅ 已获得 …/PRBPosterExtensionDataStore` | 扩展生效，容器正确，可以直接应用壁纸 |
| `⚠️ 容器可读，但没有 PRBPosterExtensionDataStore` | 找错容器，或系统版本布局不同，请手动填路径 |
| `❌ 申请扩展失败：…（代码 -5）` | containermanagerd 拒绝查询，多为系统已修补或 flags 不匹配 |
| `❌ 申请扩展失败：…（代码 -6）` | 内核拒绝签发扩展，同上 |
| `❌ 申请扩展失败：…（代码 -8）` | 签发成功但目标打不开，通常是系统已修补 |
| `❌ 签名里没有可用的 App Group` | 签名缺 App Groups entitlement |

隧道是否可用，看「配对」页的隧道状态与日志里的 RSD 握手结果。

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

### 4. 两条写入通道（同一套注入逻辑）

| 通道 | 前提 | 适用系统 | 说明 |
| --- | --- | --- | --- |
| **配对隧道**（默认） | 有配对记录 + LocalDevVPN（`10.7.0.1`） | iOS 18.0 – 27.2 beta 2 | 走 AirTraffic/RSD，写的是 PosterBoard 真实容器 |
| **直连**（实验） | 签名带 App Groups；无需配对、无需 VPN | iOS 26.0 – 27.2 | 借 App Group 容器申请沙箱扩展后直接写容器 |

直连通道复现的是 [worse_query](https://github.com/forcequitOS/worse_query) 描述的那类缺陷：

1. 把**自己 App Group** 的 `Library/Caches` 换成指向目标的符号链接（自身容器不行，必须 class 7）；
2. 以 `class=app/appGroup`、`part=3 (Library/Caches)` 发起 `container_query`；
3. 守护进程按 part 拼路径签发 sandbox extension 时**没有对符号链接做 realpath 校验**，于是扩展实际覆盖链接指向的目录；
4. `sandbox_extension_consume` 之后，本进程就拿到了 `Data/Application/*` 的读写权；
5. 遍历该目录，找含 `Library/Application Support/PRBPosterExtensionDataStore` 的容器即为 PosterBoard。

它给的是**目录级扩展**，不是 root，也不会绕过数据保护；系统一旦修补签发逻辑（或容器布局变化）就失效，所以隧道仍是默认通道。

数据流示意：

```
.tendies ──解压──> descriptor 目录 ──随机化──> 通道写入 ──> PosterBoard 存储
                                              ├─ 配对隧道（Airlift/AirTraffic）
                                              └─ 直连（沙箱扩展）
                                                      │
                                        写 Preferences ┘──> NeoSpring respring ──> 锁屏可选
```

---

## 三、从两个项目里学到的关键点

### [GestaltX](https://github.com/huamidev/GestaltX)（MobileGestalt 编辑器）

GestaltX 编辑的是 `com.apple.MobileGestalt.plist` 这类「能力开关」文件，底层用 [worse_query](https://github.com/forcequitOS/worse_query) 做容器级沙箱逃逸（可写 `/var/containers/Data/System`、`/var/mobile/Containers/Data/Application/*` 等）。PosterDrop 的直连通道就是这套思路的复用：**PosterBoard 的库正好落在 `Data/Application/*` 里**，所以同一个扩展同样能覆盖它。三个工程化经验也被直接沿用：

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
3. **导入壁纸**：壁纸页 → 导入壁纸（或把 `.tendies` 放进「文件 › 我的 iPhone / iPad › PosterDrop」，再点「扫描文档」；iPad 也可直接从“文件”拖进壁纸页）。
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
A：分通道看。**配对隧道**在 iOS 27.2 beta 3 起被 Apple 修复（AirTraffic 同步链路），升级即失效且不可逆；
**直连通道**走的是另一处 container 签发缺陷，worse_query 标注支持到 27.2（含 beta 3），升级后大概率仍可用。
这也是 1.1.0 之后把直连做成独立通道的原因：一条被补了还有另一条。

**Q：iPad 上能用吗？界面是放大版 iPhone 吗？**
A：能，同一份 IPA。界面是原生 iPad 布局：宽窗口下页签变侧边栏、壁纸列表双列、内容按 760pt 版心居中，
并支持分屏 / 台前调度 / 从“文件”拖入壁纸包。功能上唯一的区别是 iPad 需要 iPadOS 18+，且直连通道还没有 iPad 实测记录。

---

## 八、免责声明与许可

- 本项目仅用于**安全研究与个人设备定制**，请仅在你自己拥有或获授权管理的设备上使用。
- 修改系统 App 数据可能导致壁纸异常、SpringBoard 崩溃甚至需要恢复系统，请自行承担风险，操作前备份。
- 本项目**不涉及**绕过激活锁、绕过 Apple ID、破解付费内容等行为。

许可：

- PosterDrop 本体：MIT
- `AirliftFFI.xcframework`：来自 [AirCard-iOS](https://github.com/Mak5er/AirCard-iOS)（MIT），底层为 [Airlift](https://github.com/0xjohnnydev/airlift)
- NeoSpring：[neonmodder123](https://github.com/neonmodder123) / [skadz108](https://github.com/skadz108) / [rooootdev](https://github.com/rooootdev)
