# PosterDrop

把 **PosterBoard 动态壁纸包（`.tendies`）** 导入设备并直接「装进系统」，无需越狱、无需电脑中转。

PosterDrop 只做一件事：**导入动态壁纸 → 注入 → respring → 立刻可用**。

- **底层只有一条：worse_query 的 App Group 沙箱逃逸。** 不需要配对文件、不需要 LocalDevVPN、不走 RSD。
- 通用 App（`TARGETED_DEVICE_FAMILY = 1,2`）：同一份 IPA 装 iPhone 和 iPad，iPad 支持四方向、分屏、台前调度与拖放导入。
- 支持 iOS / iPadOS 26.0 – 27.2（worse_query 的适用范围），详见[兼容性](#一兼容性)。
- 支持 `.tendies` / `.zip` / 整容器归档 / **已解压的文件夹**，自动识别 Collections / Mercury / Photos / Kaleidoscope / Unity 五类壁纸。
- 自带 zip 解析，只读中央目录 + 单张预览图，大包不会因临时目录空间不足失败。
- 自动抽取预览图、判定描述符数量；iOS 18+ 额外写一份独立的 `.Posters.<Name>App` 容器。
- 容器定位、写入校验、缓存刷新、NeoSpring respring、运行日志都在 App 内完成。

> 仅供安全研究与个人设备定制使用。请只在你自己拥有或获授权管理的设备上运行。

---

## 一、兼容性

### 1.1 应用本体

| 项目 | 要求 |
| --- | --- |
| 系统 | iOS / iPadOS **26.0 – 27.2**（部署目标 18.0，但低于 26.0 没有这条签发缺陷） |
| 机型 | **iPhone + iPad**（`TARGETED_DEVICE_FAMILY = 1,2`），iPad 支持四方向、分屏、台前调度 |
| 架构 | arm64 |
| 安装 | 未签名 IPA，需 SideStore / AltStore / Sideloadly / TrollStore 自签 |
| 签名 | **必须带 `com.apple.security.application-groups`**（见 1.3） |

**iPad 适配说明**

- iPhone 与 iPad 共用同一个 bundle、同一份 IPA，签名流程完全一致（iPad 也要在重签工具里勾 App Groups）。
- 界面：iPad 全宽时页签变成侧边栏；内容限制在 760pt 版心内居中，壁纸列表按窗口宽度自动单列 / 双列。
- 窗口：`UIRequiresFullScreen` 已移除，可在分屏、Slide Over、台前调度里任意缩放；窄窗口自动退回底部标签栏和单列布局。
- 导入：除「导入壁纸」外，iPad 上可直接从“文件”App 把 `.tendies` 拖进壁纸页。
- 注入：与 iPhone 完全同一套代码，能否使用只取决于 **iPadOS 版本**，与机型无关。

### 1.2 系统版本

worse_query 支持 iOS 26.0 – 26.7.2 / 27.2。区间内唯一变化是查询 flags：

| iOS / iPadOS 版本 | 状态 | 说明 |
| --- | --- | --- |
| 17.x 及更早 | ❌ | 低于部署目标，且没有 App Group 签发缺陷 |
| 18.0 – 25.x | ❌ | 没有这条缺陷，旧版的 Airlift 隧道也已移除 |
| 26.0 – 26.6.1 | ✅ | App Group 查询使用备用 flags（`0x0000000800000000`） |
| 26.7 – 26.7.2 | ✅ | 同上 |
| 27.0 – 27.2 | ✅ | 使用标准 flags（`0x0000008000000000`） |
| 27.3 及以后 | ⚠️ 未验证 | 先跑「诊断 › 自检通道」，失败就说明漏洞已被修补 |

> 「✅」= 有公开实现或实测记录；「⚠️」= 没有设备验证；「❌」= 明确不可用。

### 1.3 前置条件

1. **签名里必须带 `com.apple.security.application-groups`。** 这条是硬要求，不是可选项：
   containermanagerd 只对 App Group 容器签发扩展，自身容器（class 2）拿不到 token。
   - 用 **轻松签 / ESign** 重签时勾选 App Groups，填任意一个 profile 允许的 group（如 `group.com.posterdrop.shared`）；
   - **Sideloadly 默认不会加 App Groups**，会直接报「签名里没有可用的 App Group」；
   - 免费 Personal Team 在 Xcode 27 上通常也能签出 App Groups，但会随证书 7 天过期；
   - 应用会自动读签名里的 group，不需要手填；填了则以手填的为准。
2. 设备已解锁（首次访问容器会校验数据保护状态）。
3. 不需要 VPN、不需要配对记录、不需要电脑。

### 1.4 容器是怎么找到的

`Data/Application` 父目录本身列不出来（WQFiles 的注释也确认：三个容器父目录只能靠扫描）。程序按顺序尝试：

| 顺序 | 方法 | 说明 |
| --- | --- | --- |
| ① | 手动路径 | 诊断页输入框，粘贴 WQFiles 里复制的路径（可编辑） |
| ② | LaunchServices | `LSApplicationWorkspace` 取 `dataContainerURL`；系统 App 常常为空，但很快 |
| ③ | containermanagerd 枚举 | class 0/2/5/7/8/10/11/13，带 `include_other_owners` |
| ④ | 按 bundle id 查询 | `container_query_set_identifiers(class 2)`，同时试 `xpc_string` / `xpc_array` |
| ⑤ | **`fsgetpath` 反查** | 多线程扫描卷上的 object id，把容器 UUID 还原成路径，再逐个签发扩展、读 xattr 认领 |
| ⑥ | 父目录列举 | 通常被拒，最后试一次 |

命中后验证 `<容器>/Library/Application Support/PRBPosterExtensionDataStore` 是否存在，或 xattr `com.apple.containermanager.identifier == com.apple.PosterBoard`。

**⑤ 的实现要点**

- `fsgetpath(fsid, inode)` 把 inode 还原成路径，不受沙箱限制；
- 扫描上界取「自己刚建的临时文件」的 inode + 10 万（APFS 的 object id 单调递增）；
- 4–8 个工作线程按 32768 一段并行扫，几百万个 id 通常几秒；
- 先抽样 2000 个 id，如果只能解析到自己 App 的文件，就直接放弃并提示（说明这个版本拦住了反查）；
- 结果写入 UserDefaults，7 天内复用；下次只扫上次上界之后的新 id（增量）。

### 1.5 怎么确认自己这台能用

打开「诊断 › 沙箱通道 › 自检通道」：

| 输出 | 含义 |
| --- | --- |
| `签名内 App Groups：group.xxx` | 签名带 App Groups，这是前提 |
| `签名内 App Groups：无` | 重签时没勾 App Groups，一定失败，换签名工具 |
| `✅ 找到 Library/Application Support/PRBPosterExtensionDataStore` | 扩展生效、容器正确，可以直接应用壁纸 |
| `⚠️ 容器可读，但里面没有目标数据目录` | 找错容器，或系统布局不同，请手动填路径 |
| `❌ 申请扩展失败：…（代码 -5）` | containermanagerd 拒绝查询，多为系统已修补或 flags 不匹配 |
| `❌ 申请扩展失败：…（代码 -6）` | 内核拒绝签发扩展，同上 |
| `❌ 申请扩展失败：…（代码 -8）` | 签发成功但目标打不开/写不进，通常是系统已修补 |
| `扫了 N 个 object id，得到 0 个容器` | `fsgetpath` 被拦住，去 WQFiles 复制容器路径手填 |
| `fsgetpath 只能解析本 App 自己的文件` | 同上，快速失败提示 |
| `✅ 认领到 com.apple.PosterBoard：…` | 找到了，直接去点「应用所选」 |

自检成功后容器路径会自动保存，后续「应用」直接用。

---

## 二、它是怎么工作的

### 1. 拿到沙箱扩展（worse_query）

复现 [worse_query](https://github.com/forcequitOS/worse_query) 描述的缺陷：

1. 把**自己 App Group** 的 `Library/Caches` 换成指向目标目录的符号链接（自身容器不行，必须 class 7）；
2. 以 `class = 7 (app group)`、`part = 3 (Library/Caches)` 发起 `container_query`；
3. containermanagerd 按 part 拼路径签发 sandbox extension 时**没有对符号链接做 realpath 校验**，扩展实际覆盖链接指向的目录；
4. `sandbox_extension_consume` 之后，本进程就拿到了目标目录的读写权；
5. 交换前写恢复标记，结束后还原 Caches；即使进程被杀，下次启动也会恢复。

一条实测结论（27.0.1）决定了写入逻辑：**扩展只覆盖签发时指定的那一个目录**。
给容器根签发并不足以在两三层之下创建文件，所以每建一层目录、每写一层文件，都先给文件真正所在的目录单独签发一次。

### 2. 注入

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

1. 用内置 `ZipArchive` 读中央目录，递归找出所有 descriptor 目录（判据：含 `versions/`、`providerInfo.plist`、`Wallpaper.plist` 之一）；
2. **随机化标识**（只改纯数字标识，保留 `v6x.colorA` 这类符号标识，否则 Mercury/Unity 会失效）；
3. 逐目录签发扩展后把目录写进去，写完对比源/目标文件数；iOS 18+ 再往独立的 `com.apple.Posters.<Name>App` 容器写一份；
4. 写入 `com.apple.PosterBoard.unprotectedUserDefaults.plist`（`PBF_RESET_FILE_PROTECTIONS` 等键）强制重新索引，最后用 **NeoSpring** 打崩 SpringBoard 让壁纸立刻出现。

数据流：

```
.tendies ──解压──> descriptor 目录 ──随机化──> 逐目录签发扩展 ──> PosterBoard 容器
                                                              │
                                                写 Preferences ┘──> NeoSpring respring ──> 锁屏可选
```

---

## 三、为什么 2.0 把 Airlift 删干净了

1.0 – 1.5 有两套底层同时存在：Airlift（配对 + RSD）和 worse_query。结果是：

- 没有配对记录时能走直连，但只要直连失败就会回退到隧道，日志里到处是 Airlift；
- 隧道需要 LocalDevVPN，且 iOS 27.2 beta 3 起 AirTraffic 已被 Apple 修补；
- 引入 127 MB 的 Rust 静态库，IPA 体积、构建步骤、故障面都翻倍。

2.0 的做法是只保留 worse_query：删除 `AirliftFFI`、配对页、配对存储、隧道检测、TunnelChannel 和所有 `al_*` 调用。
现在打开 App、导入、注入、respring 的整条链路里没有任何一条需要 VPN 或配对文件。

---

## 四、目录结构

```
PosterDrop/
├── project.yml                    # XcodeGen 工程定义
├── Config/PosterDrop.entitlements # App Groups entitlement（ad-hoc 签名用）
├── scripts/build-ipa.sh           # 编译 + ad-hoc 签名 + 打包 IPA
├── .github/workflows/build.yml    # GitHub Actions：出 IPA 产物 / 发 Release
├── Design/AppIcon-1024.png        # 图标源文件
└── PosterDrop/
    ├── App/
    │   ├── PosterDropApp.swift    # 入口
    │   └── AppModel.swift         # 状态与业务编排
    ├── Core/
    │   ├── SandboxEscape.swift    # worse_query：签发 / 交换 / 缓存 / 恢复
    │   ├── ContainerLocator.swift # 容器定位（含 fsgetpath 并行扫描）
    │   ├── FileChannel.swift      # 逐目录签发 + 写入 + 校验
    │   ├── ArchiveInspector.swift # 解压 / descriptor 发现 / 预览图
    │   ├── PosterBoardInstaller.swift # 注入 + 缓存刷新
    │   ├── WallpaperStore.swift   # 本地库与索引
    │   ├── WallpaperItem.swift    # 数据模型
    │   ├── ZipArchive.swift       # 自带 zip 解析
    │   ├── Respring.swift         # NeoSpring
    │   └── LogBus.swift
    ├── UI/                        # SwiftUI 界面（壁纸 / 诊断）
    └── Resources/                 # Info.plist、图标、配色
```

---

## 五、构建

### 用 GitHub Actions（推荐，无需 Mac）

1. 把仓库推到 GitHub；
2. Actions 会自动跑 `Build IPA`（也可手动 `workflow_dispatch`）；
3. 在运行记录的 **Artifacts** 里下载 `PosterDrop-ipa`，解压得到 `PosterDrop.ipa`；
4. 打 tag（如 `v2.0.0`）推送会自动把 IPA 附到 Release。

工作流做的事：安装 XcodeGen → `xcodegen generate` → `build-ipa.sh Release` → 上传产物。
构建脚本会去掉 Xcode 的空签名，再用 `Config/PosterDrop.entitlements` 做 ad-hoc 签名，让 SideStore / AltStore 重签时能读到 App Groups。

### 本地构建（需要 macOS + Xcode 16+）

```bash
brew install xcodegen
xcodegen generate
./scripts/build-ipa.sh Release
# 产物：build/PosterDrop.ipa（ad-hoc 签名，含 App Groups entitlement）
```

### 安装

- SideStore / AltStore：导入 IPA，用你的 Apple ID 重签，**确认勾选/保留了 App Groups**；
- TrollStore：直接安装；
- Sideloadly：可以装，但需要自己在签名配置里加 App Groups，否则会报「签名里没有可用的 App Group」。

---

## 六、使用步骤

1. **确认签名**：打开「诊断」，看「签名内 App Groups」是否有值。
2. **自检**：点「自检通道」。第一次会自动扫容器（几秒），成功后会缓存路径。
3. **导入壁纸**：壁纸页 → 导入壁纸，可以选 `.tendies` / `.zip`，也可以选**整个已解压的文件夹**（或放进「文件 › 我的 iPhone / iPad › PosterDrop」后点「扫描文档」，递归扫描；iPad 可直接拖入）。
4. **应用**：勾选 → 应用所选（或单张长按 / 详情页应用）。注入完成后自动 respring。
5. **选用**：锁屏长按 → 自定义 → 墙纸，或「设置 › 墙纸」里选择新出现的壁纸。

---

## 七、常见问题

**Q：为什么不需要 VPN 和配对文件了？**
A：2.0 的底层是 worse_query，靠 App Group 容器的 `Library/Caches` 符号链接让 containermanagerd 签出目标目录的扩展，全程在本机进程内完成。旧版的 Airlift 隧道（需要配对 + LocalDevVPN）已经整条删除。

**Q：提示「签名里没有可用的 App Group」**
A：重签时没勾 App Groups。用轻松签 / ESign 勾选一个 group 重签；免费 Personal Team 也可以。

**Q：自检显示 `fsgetpath 只能解析本 App 自己的文件`**
A：这个系统版本拦住了 inode 反查。用 WQFiles 打开 App Data › PosterBoard，复制容器路径，粘到诊断页输入框再点自检。

**Q：注入成功但壁纸里看不到**
A：依次尝试「刷新壁纸缓存」→ NeoSpring respring → 打开墙纸设置后下拉。仍不行就看日志里的结构版本（应为 61）和 `写入 …/Preferences` 是否成功。

**Q：升级系统后失效？**
A：worse_query 标注支持到 27.2（含 beta 3）。27.3 及以后未验证，升级后先跑自检；如果返回 -5 / -6 / -8，说明签发缺陷已被修补。

**Q：iPad 上能用吗？界面是放大版 iPhone 吗？**
A：能，同一份 IPA。界面是原生 iPad 布局：宽窗口下页签变侧边栏、壁纸列表双列、内容按 760pt 版心居中，并支持分屏 / 台前调度 / 从“文件”拖入壁纸包。

---

## 八、免责声明与许可

- 本项目仅用于**安全研究与个人设备定制**，请仅在你自己拥有或获授权管理的设备上使用。
- 修改系统 App 数据可能导致壁纸异常、SpringBoard 崩溃甚至需要恢复系统，请自行承担风险，操作前备份。
- 本项目**不涉及**绕过激活锁、绕过 Apple ID、破解付费内容等行为。

许可与致谢：

- PosterDrop 本体：MIT
- 沙箱逃逸思路：[worse_query](https://github.com/forcequitOS/worse_query)（forcequitOS / Taj C，GPL-3.0-or-later）与 WQFiles 的公开实现；本项目的 Swift 实现按公开描述的机制重写
- 注入流程参考：[AirCard-iOS](https://github.com/Mak5er/AirCard-iOS)（MIT）
- NeoSpring：[neonmodder123](https://github.com/neonmodder123) / [skadz108](https://github.com/skadz108) / [rooootdev](https://github.com/rooootdev)
