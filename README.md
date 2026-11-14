# PosterDrop

把 **PosterBoard 动态壁纸包（`.tendies`）** 导入 iPhone / iPad，直接装进系统，**免越狱、免电脑、免 VPN**。

导入 → 注入 → respring，全程在设备上完成，一分钟内出结果。

- **支持 iOS / iPadOS 26.0 – 27.2**（详见[系统支持](#二系统支持)）
- 同一份 IPA 装 iPhone 和 iPad，iPad 支持分屏、台前调度、拖放导入
- 支持 `.tendies` / `.zip` / 已解压的文件夹 / 整容器归档
- 自动识别 Collections / Mercury / Photos / Kaleidoscope / Unity 五类壁纸
- 自带缓存清理，本 App / PosterBoard / 其他 App / 系统四级范围，容器内覆盖 8 类位置

**[下载最新版（v1.4.1）](https://github.com/NIHAO1145141918/PosterDrop/releases/latest)** · 未签名 IPA，侧载时需勾选 App Groups（`group.com.posterdrop.shared`）

> **1.4.1**：修复 1.4.0 的容器索引误判——没有 `container-manager` 权限时，`container_query` 只返回自己却不报错，
> 导致深扫后「其他 App」整组消失。现改为剔除自身后少于 3 条即判定为沙盒限制并回落。详见 [Releases](https://github.com/NIHAO1145141918/PosterDrop/releases/tag/v1.4.1)。

> 仅供安全研究与个人设备定制使用，请只在你自己拥有或获授权管理的设备上运行。

---

## 一、功能

### 1. 导入与注入

| 功能 | 说明 |
| --- | --- |
| 多格式导入 | `.tendies`、`.zip`、整个已解压的文件夹，或丢进「文件 › PosterDrop」后一键扫描 |
| 自动识别 | 按 `versions/`、`providerInfo.plist`、`Wallpaper.plist` 判定描述符目录，支持五类壁纸 |
| 内置 zip 解析 | 只读中央目录和单张预览图，几 GB 的包也不会因为临时空间不足失败 |
| 预览与筛选 | 自动抽首帧做缩略图，按类型 / 名称分组，支持批量勾选 |
| 一键注入 | 逐目录签发沙箱扩展写入 PosterBoard 容器，写完比对文件数 |
| 双写新容器 | iOS 26+ 额外写一份 `.Posters.<Name>App`，壁纸更容易出现在「墙纸」里 |
| 即时生效 | 写偏好后 NeoSpring respring，回到锁屏就能选 |

注入采用 `clonefile` 零拷贝：同卷整树克隆是元数据操作，几百 MB 的壁纸也不会因为逐文件读写而拖时间；克隆不可用时自动回退流式拷贝，不影响成功率。

### 2. 缓存清理

第三个页签，按范围分四组，容器内覆盖 8 类位置：

| 分组 | 清理项 | 默认 |
| --- | --- | --- |
| 本 App | 解包暂存（导入中断留下的临时目录）、本 App 缓存 | ✅ |
| PosterBoard | 缓存与缩略图、`tmp`、应用快照、窗口状态、网络缓存、Cookie、网页数据、运行日志 | 前两项 ✅ |
| 其他 App | **逐个 App 一项**，按占用从大到小排，展开可看每一项包含哪些位置（上限 400 个容器，30 秒软上限，超时降级为只算 Caches + tmp） | ⬜（需深度扫描） |
| 系统 | 全系统应用快照、崩溃日志、系统共享缓存 | ⬜ |

顶部显示可清理总量，勾选后底部按钮直接给出「清理 3 项 · 136 MB」。清掉 PosterBoard 缩略图或系统缓存后会提示一键 respring 重建，避免预览变灰块让人以为壁纸丢了。

**选哪些会有什么后果**

- 可重建：缓存、`tmp`、快照、窗口状态、日志——删了系统自己长回来，最多下次启动慢一点；
- 需重新登录：Cookie、网络缓存、网页数据——标为「需重新登录」，默认不勾；
- 系统级：全系统快照通常最占地方（几百 MB 到几 GB），共享缓存清完桌面会重载一次。

**安全护栏**（这部分比功能本身重要）：

1. **路径不可伪造** —— 容器内只由「合法容器根 + 固定相对路径」拼出；系统级是三个硬编码绝对路径，删除前还要过一遍精确白名单校验；界面上没有任何入口能传入任意路径；
2. **符号链接只删链接本身** —— `lstat` 判定是链接就走 `unlink`，绝不跟进。App Group 的 `Library/Caches` 本身就是链接，跟进去会删到别的容器；
3. **目录句柄相对操作** —— 删除只在已经打开的父目录 fd 上做 `unlinkat` / `AT_REMOVEDIR`，所有打开都带 `O_NOFOLLOW`，不会被符号链接引到别的容器；
4. **不碰壁纸本体** —— 壁纸在 `Library/Application Support/PRBPosterExtensionDataStore`，不在任何清理路径里；
5. **不碰偏好设置** —— `Library/Preferences`、`Documents`、`Application Support` 都不在白名单里，清缓存不会丢登录以外的数据。

**速度**

统计和删除都改成「目录句柄相对操作」：打开一次目录拿到 fd，之后 `openat` / `fstatat` / `unlinkat` 都以它为起点。原来每访问一个文件都要拼出
`/private/var/mobile/Containers/Data/Application/<UUID>/Library/Caches/…` 这样一条八十字符的路径，让内核从根重新解析一遍——一个五万文件的缓存目录就是五万次全路径解析。改成 fd 相对之后，这段前缀解析全部省掉。

| 环节 | 做法 |
| --- | --- |
| 定位容器 | ⓪ 上次路径（0.02 秒）→ ①.5 `LSApplicationProxy.dataContainerURL` 直取（一次 ObjC 消息）→ ①.6 签发容器父目录 → ②③④ 枚举/查询 → ⑤ `fsgetpath` 扫描 |
| 进入其他 App | 三条路依次降级：父目录 fd 直进 → `container_query` 索引激活 → 逐个签发 |
| 8 个缓存目录 | 在容器 fd 上 `fstatat` 判断存在，判完直接 `openat` 进去 |
| 目录内容统计 | `getattrlistbulk` 一次调用取回一批条目的名字、类型、占用；启动时用已知内容的小目录自检布局，校验不过自动退回 `fstatat` |
| 删除 | `unlinkat(fd, 名字, 0)` 与 `unlinkat(fd, 名字, AT_REMOVEDIR)`，不再拼路径再 `unlink` / `rmdir` |
| 时间上限 | 30 秒软上限；到点后**不丢容器**，只把后面的降级成「Caches + tmp」两项，总时长由后台线程承担 |
| 扫描缓存 | fsgetpath 结果保留 7 天，失效路径不做预过滤，避免整份缓存被清空后重扫 |

**为什么能扫到几百 MB**

关键不是「每个 App 删得更深」，而是**能不能进得去**。一次父目录扩展覆盖不全时，剩下的大 App 会整片消失，
表现就是「只清掉几十 MB」。为此依次尝试三条路：

1. **父目录扩展**：签出 `/private/var/mobile/Containers/Data/Application` 一次，之后每个容器 `openat`
   直接进，正常路径零 XPC；
2. **容器索引**：用 `container_query_set_class(2)` 枚举全部 App 数据容器，再对每个容器调
   `container_object_sandbox_extension_activate`。这条和 3105 的主路径一致；
3. **逐个签发**：每条 80–120ms，走 Caches 符号链接交换，最慢但兼容性最好。

第二条路有个必须点明的前提：**没有 `com.apple.private.security.container-manager` 权限时，
`container_query_set_class(2)` 不会报错，而是安静地只返回调用者自己的容器。** 1.4.0 把这唯一的
一条结果当成成功，直接跳过后续路径，导致「其他 App」整片只剩自己——比不加索引还差。

1.4.1 起，索引结果会先剔除自身容器，少于 3 条即判定为沙盒限制并回落；打开率低于一半也回落
（拿到路径不等于能进，`activate` 没生效时路径是死的）。所以在只带 App Groups 的 ad-hoc 签名下，
实际干活的是第三条。

扫描日志会把真实数字写出来：`N 个容器，打开 X 个、被拒 Y 个，K 个有缓存，D 个降级统计`。
三个数的含义很明确：

- **X 接近 N** —— 覆盖没问题，MB 数取决于设备里 App 的真实缓存量；
- **X 远小于 N** —— 卡在权限，再多时间也扫不出东西，该补签名权限而不是调参数；
- **N 很小（几十）** —— 容器发现入口本身就窄，问题在 `fsgetpath` 这一层。

深度扫描上限 400 个容器，30 秒软上限保证排在后面的容器不会因为超时被丢掉。

### 3. 诊断

| 功能 | 说明 |
| --- | --- |
| 自检通道 | 检查签名里的 App Groups、申请沙箱扩展、定位 PosterBoard 容器，全流程带阶段计时 |
| 容器路径 | 自动定位，也支持手动粘贴 WQFiles 里复制的路径 |
| VPN 检测 | 端口拨号判断是否真的能通，区分「有 utun 网卡」和「隧道可用」 |
| 结构版本 | 切换 59 / 61 两套描述符结构，应对不同系统布局 |
| 运行日志 | 每一步的签发、写入、校验结果都在 App 内可见，可复制 |

---

## 二、系统支持

**支持 iOS / iPadOS 26.0 – 27.2。**

| 版本 | 状态 | 说明 |
| --- | --- | --- |
| 18.x 及更早 | ❌ | 没有这条签发缺陷，功能不可用 |
| 26.0 – 26.6.1 | ✅ | App Group 查询使用备用 flags（`0x0000000800000000`） |
| 26.7 – 26.7.2 | ✅ | 同上 |
| 27.0 – 27.2 | ✅ | 使用标准 flags（`0x0000008000000000`） |
| 27.3 及以后 | ❌ 已修补 | 实测 27.3（24C5037i）签发返回 -6，containermanagerd 不再签发跨容器扩展 |

> 「✅」= 有公开实现或实测记录；「⚠️」= 没有设备验证；「❌」= 明确不可用。

### 机型与安装

| 项目 | 要求 |
| --- | --- |
| 机型 | **iPhone + iPad**（`TARGETED_DEVICE_FAMILY = 1,2`），iPad 支持四方向、分屏、台前调度 |
| 架构 | arm64 |
| 安装 | 未签名 IPA，用 SideStore / AltStore / Sideloadly / 轻松签 / ESign 自签 |
| 签名 | **必须带 `com.apple.security.application-groups`**，这是硬要求 |

签名不带 App Groups 一定失败：containermanagerd 只对 App Group 容器签发扩展，自身容器（class 2）拿不到 token。

- 轻松签 / ESign：重签时勾 App Groups，填任意一个 profile 允许的 group（如 `group.com.posterdrop.shared`）；
- Sideloadly：默认不加 App Groups，需手动在签名配置里加，否则报「签名里没有可用的 App Group」；
- 免费 Personal Team 也能签出 App Groups，但随证书 7 天过期。

App 会自动读签名里的 group，不需要手填；填了则以手填为准。

---

## 三、使用步骤

1. **确认签名**：打开「诊断」，看「签名内 App Groups」是否有值。
2. **自检**：点「自检通道」。首次会扫容器（通常几秒），成功后缓存路径，下次基本一步命中。
3. **导入壁纸**：壁纸页 → 导入壁纸，选 `.tendies` / `.zip`，或选整个已解压的文件夹；iPad 可直接从「文件」拖进来。
4. **应用**：勾选 → 应用所选（或单张长按 / 详情页应用）。注入完成自动 respring。
5. **选用**：锁屏长按 → 自定义 → 墙纸；或「设置 › 墙纸」里选新出现的壁纸。
6. **（可选）清缓存**：占空间时去「清理」页，勾选后一键清理，再 respring 重建缩略图。

---

## 四、工作原理

### 4.1 沙箱扩展（worse_query）

复现 [worse_query](https://github.com/forcequitOS/worse_query) 描述的缺陷：

1. 把**自己 App Group** 的 `Library/Caches` 换成指向目标目录的符号链接（自身容器不行，必须 class 7）；
2. 以 `class = 7 (app group)`、`part = 3 (Library/Caches)` 发起 `container_query`；
3. containermanagerd 按 part 拼路径签发 sandbox extension 时没有对符号链接做 realpath 校验，扩展实际覆盖链接指向的目录；
4. `sandbox_extension_consume` 之后，本进程就拿到了目标目录的读写权；
5. 交换前写恢复标记，结束后还原 Caches；进程被杀也会在下次启动时恢复。

一条关键约束：**扩展只覆盖签发时指定的那一个目录**。给容器根签发不足以在两三层之下创建文件，所以每建一层目录、每写一层文件，都要给文件真正所在的目录单独签发一次。整批操作包在 `beginBatch / endBatch` 里，Caches 符号链接只装一次。

### 4.2 容器定位

`Data/Application` 父目录列不出来，所以按顺序尝试：

| 顺序 | 方法 | 说明 |
| --- | --- | --- |
| ① | 手动路径 | 诊断页输入框，粘贴 WQFiles 复制的路径 |
| ② | LaunchServices | 取 `dataContainerURL`，快，但系统 App 常为空 |
| ③ | containermanagerd 枚举 | class 0/2/5/7/8/10/11/13，带 `include_other_owners` |
| ④ | 按 bundle id 查询 | `container_query_set_identifiers(class 2)` |
| ⑤ | **`fsgetpath` 反查** | 多线程扫描卷上的 object id，还原容器 UUID 并逐个签发认领 |
| ⑥ | 父目录列举 | 通常被拒，最后兜底 |

`fsgetpath(fsid, inode)` 不受沙箱限制，是定位的核心：扫描上界取「自己刚建的临时文件 inode + 10 万」，按核数分段并行，几百万个 id 通常几秒；命中后读根目录 xattr `com.apple.containermanager.identifier` 确认归属。结果落缓存，7 天内复用，下次只扫增量。

### 4.3 注入

PosterBoard 把每张壁纸存成一组描述符目录：

```
<容器>/Library/Application Support/PRBPosterExtensionDataStore/<61|59>/Extensions/<bundleID>/descriptors/<UUID>/
├── versions/…
├── providerInfo.plist
├── Wallpaper.plist
├── com.apple.posterkit.provider.descriptor.identifier
└── com.apple.posterkit.provider.contents.userInfo
```

程序做四件事：

1. 读中央目录递归找 descriptor 目录；
2. **随机化标识**（只改纯数字标识，保留 `v6x.colorA` 这类符号标识，否则 Mercury / Unity 会失效）；
3. 逐目录签发扩展写入，写完比对源 / 目标文件数；iOS 26+ 再往 `.Posters.<Name>App` 写一份；
4. 写 `com.apple.PosterBoard.unprotectedUserDefaults.plist` 强制重新索引，NeoSpring 打崩 SpringBoard 让壁纸立刻出现。

```
.tendies ──解压──> descriptor 目录 ──随机化──> clonefile 写入 ──> PosterBoard 容器
                                                          │
                                            写 Preferences ┘──> respring ──> 锁屏可选
```

---

## 五、常见问题

**Q：为什么不需要 VPN 和配对文件？**
A：底层是 worse_query，靠 App Group 容器 `Library/Caches` 的符号链接让 containermanagerd 签出目标目录的扩展，全程在本机进程内完成。旧版的 Airlift 隧道（需要配对 + LocalDevVPN）已经整条删除。

**Q：iOS 26 之前能用吗？支持 19–25 吗？**
A：不能。iOS 18 之后 Apple 直接跳到 iOS 26，没有 19–25 这些版本号；而这条签发缺陷只存在于 26.0–27.2。

**Q：提示「签名里没有可用的 App Group」**
A：重签时没勾 App Groups。用轻松签 / ESign 勾一个 group 重签；Sideloadly 需手动加。

**Q：自检显示 `fsgetpath 只能解析本 App 自己的文件`**
A：这个版本拦住了 inode 反查。用 WQFiles 打开 App Data › PosterBoard，复制容器路径，粘到诊断页输入框再自检。

**Q：注入成功但壁纸里看不到**
A：依次试「刷新壁纸缓存」→ respring → 打开墙纸设置后下拉。仍不行就看日志里的结构版本（应为 61）和 `写入 …/Preferences` 是否成功。

**Q：清缓存会删掉我注入的壁纸吗？**
A：不会。容器的清理范围只有 `Library/Caches`、`tmp`、`SplashBoard`、`Saved Application State`、`HTTPStorages`、`Cookies`、`WebKit`、`Logs` 八个位置，壁纸本体在 `Application Support/PRBPosterExtensionDataStore`，不在白名单里。

**Q：清理后预览变成灰块？**
A：缩略图被清了，点清理页的「重建壁纸缩略图」respring 一次即可，壁纸本身没丢。

**Q：升级系统后失效？**
A：worse_query 支持到 27.2（含 beta 3）。27.3 已实测被修补：签发返回 -6，容器枚举为 0，导入和清理都用不了。升级前先跑「诊断 › 自检通道」，看到 -6 就是这条路封了。

---

## 六、目录结构

```
PosterDrop/
├── project.yml                    # XcodeGen 工程定义
├── Config/PosterDrop.entitlements # App Groups entitlement（ad-hoc 签名用）
├── scripts/build-ipa.sh           # 编译 + ad-hoc 签名 + 打包 IPA
├── .github/workflows/build.yml    # GitHub Actions：出 IPA / 发 Release
├── Design/AppIcon-1024.png        # 图标源文件
└── PosterDrop/
    ├── App/
    │   ├── PosterDropApp.swift    # 入口
    │   └── AppModel.swift         # 状态与业务编排
    ├── Core/
    │   ├── SandboxEscape.swift    # worse_query：签发 / 交换 / 批量 / 恢复
    │   ├── ContainerLocator.swift # 容器定位（含 fsgetpath 并行扫描）
    │   ├── ContainerIndex.swift   # 按 bundleID 直取容器（container_query class 2）
    │   ├── LaunchServices.swift   # LSApplicationProxy 直取容器路径与 App 名称
    │   ├── FileChannel.swift      # clonefile 写入 + 校验
    │   ├── ArchiveInspector.swift # 解压 / descriptor 发现 / 预览图
    │   ├── ZipArchive.swift       # 自带 zip 解析（EOCD 双路 + ZIP64）
    │   ├── LibArchive.swift       # 系统 libarchive 兜底
    │   ├── PosterBoardInstaller.swift # 注入 + 缓存刷新
    │   ├── CacheCleaner.swift     # 缓存清理（白名单 + 分组统计）
    │   ├── FileTree.swift         # 目录遍历内核：fd 相对 + getattrlistbulk
    │   ├── VPNStatus.swift        # VPN 三态检测
    │   ├── WallpaperStore.swift   # 本地库与索引
    │   ├── Respring.swift         # NeoSpring
    │   └── LogBus.swift
    ├── UI/                        # SwiftUI（壁纸 / 清理 / 诊断）
    └── Resources/                 # Info.plist、图标、配色
```

---

## 七、构建

### GitHub Actions（无需 Mac）

1. 推送仓库，Actions 会自动跑 `Build IPA`（也支持手动 `workflow_dispatch`）；
2. 在运行记录的 **Artifacts** 下载 `PosterDrop-ipa`，解压得到 `PosterDrop.ipa`；
3. 打 tag（如 `v1.4.1`）并推送，IPA 会自动附到 Release。

工作流：安装 XcodeGen → `xcodegen generate` → `build-ipa.sh Release` → 上传产物。脚本会去掉 Xcode 的空签名，再用 `Config/PosterDrop.entitlements` 做 ad-hoc 签名，让重签工具能读到 App Groups。

### 本地构建（macOS + Xcode 16 以上）

```bash
brew install xcodegen
xcodegen generate
./scripts/build-ipa.sh Release
# 产物：build/PosterDrop.ipa
```

---

## 八、免责声明与致谢

- 仅用于**安全研究与个人设备定制**，请只在你自己拥有或获授权管理的设备上使用。
- 修改系统 App 数据可能导致壁纸异常、SpringBoard 崩溃甚至需要恢复系统，请自行承担风险并提前备份。
- 本项目不涉及绕过激活锁、绕过 Apple ID、破解付费内容等行为。

许可与致谢：

- PosterDrop 本体：MIT
- 沙箱逃逸思路：[worse_query](https://github.com/forcequitOS/worse_query)（forcequitOS / Taj C，GPL-3.0-or-later）与 WQFiles 的公开实现，本项目按公开描述的机制用 Swift 重写
- 注入流程参考：[AirCard-iOS](https://github.com/Mak5er/AirCard-iOS)（MIT）
- NeoSpring：[neonmodder123](https://github.com/neonmodder123) / [skadz108](https://github.com/skadz108) / [rooootdev](https://github.com/rooootdev)
