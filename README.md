# PosterDrop

把 **PosterBoard 动态壁纸包（`.tendies`）** 导入 iPhone / iPad，直接装进系统，**免越狱、免电脑、免 VPN**。

导入 → 注入 → respring，全程在设备上完成，一分钟内出结果。

- **支持 iOS / iPadOS 26.0 – 27.2**（详见[系统支持](#二系统支持)）
- 同一份 IPA 装 iPhone 和 iPad，iPad 支持分屏、台前调度、拖放导入
- 支持 `.tendies` / `.zip` / 已解压的文件夹 / 整容器归档
- 自动识别 Collections / Mercury / Photos / Kaleidoscope / Unity 五类壁纸
- 自带缓存清理，能清理 PosterBoard 和其他 App 的缓存与临时文件

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

第三个页签，按范围分三组：

| 分组 | 清理项 | 默认 |
| --- | --- | --- |
| 本 App | 解包暂存（导入中断留下的临时目录）、本 App 缓存 | ✅ |
| PosterBoard | 壁纸缩略图缓存、`tmp`、应用快照、窗口状态存档 | 前两项 ✅ |
| 其他 App | 可见容器的 `Library/Caches` + `tmp` 汇总 | ⬜（需深度扫描） |

顶部显示可清理总量，勾选后底部按钮直接给出「清理 3 项 · 136 MB」。清掉 PosterBoard 缩略图后会提示一键 respring 重建，避免预览变灰块让人以为壁纸丢了。

**安全护栏**（这部分比功能本身重要）：

1. **路径不可伪造** —— 容器内只由「合法容器根 + 固定相对路径」拼出；系统级是三个硬编码绝对路径，删除前还要过一遍精确白名单校验；界面上没有任何入口能传入任意路径；
2. **符号链接只删链接本身** —— `lstat` 判定是链接就走 `unlink`，绝不跟进。App Group 的 `Library/Caches` 本身就是链接，跟进去会删到别的容器；
3. **逐层签发** —— 扩展只覆盖签发的那一个目录，所以每层删除前先给父目录签发写权限，子目录清空后才 `rmdir`；
4. **不碰壁纸本体** —— 壁纸在 `Library/Application Support/PRBPosterExtensionDataStore`，不在任何清理路径里；
5. **不碰偏好设置** —— `Library/Preferences`、`Documents`、`Application Support` 都不在白名单里，清缓存不会丢登录以外的数据。

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
| 27.3 及以后 | ⚠️ 未验证 | 先跑「诊断 › 自检通道」，返回 -5 / -6 / -8 说明缺陷已被修补 |

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
A：不会。清理范围只有 `Library/Caches`、`tmp`、`SplashBoard`、`Saved Application State`，壁纸本体在 `Application Support`，不在白名单里。

**Q：清理后预览变成灰块？**
A：缩略图被清了，点清理页的「重建壁纸缩略图」respring 一次即可，壁纸本身没丢。

**Q：升级系统后失效？**
A：worse_query 支持到 27.2（含 beta 3）。27.3 及以后未验证，升级后先跑自检。

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
    │   ├── FileChannel.swift      # clonefile 写入 + 校验
    │   ├── ArchiveInspector.swift # 解压 / descriptor 发现 / 预览图
    │   ├── ZipArchive.swift       # 自带 zip 解析（EOCD 双路 + ZIP64）
    │   ├── LibArchive.swift       # 系统 libarchive 兜底
    │   ├── PosterBoardInstaller.swift # 注入 + 缓存刷新
    │   ├── CacheCleaner.swift     # 缓存清理（白名单 + 逐层签发）
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
3. 打 tag（如 `v1.1.0`）并推送，IPA 会自动附到 Release。

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
