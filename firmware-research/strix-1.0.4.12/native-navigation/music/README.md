# TMU1 · 第十项网易云音乐（实验版）

> **高风险试验用品，仅限懂技术的开发者学习研究，禁止未经授权的商业使用或收费分发。非开发者请用官方 App，不要随便刷！** 一台研究机实测成功不代表你的设备安全，不保证回滚、救砖、长期稳定或所有歌曲可播放。掉电、中断、版本不匹配、AP 错误均可能导致无法启动或失去 OTA。普通 SDK/App 开发不需要刷固件。

本版基于 **Strix OS 1.0.4.12**，手机侧适配 **雷鸟 AI iOS 1.0.5（201）**。新增第十项“网易云音乐”，保留原七项、第八项 Turbo Display/ANIM60、第九项原生导航。这里只发布源码及实测固件 ZIP，**不提供合并后的 IPA、预签名包、Apple 账号/证书、服务 Key、网易云账号或 Cookie**。Android / HarmonyOS 尚未接入 TMU1 手机播放器。

目的不是替换原厂系统，而是研究手机与轻量 BES2800 眼镜之间的双向应用协议、原生 UI 与多媒体状态同步。

## 能做什么 / 实测边界

2026-09-23，用户在非越狱 iPhone Air 私用配套版与研究眼镜上确认以下功能正常：

- 手机搜索、选择可播放歌曲；有声音、专辑封面、歌词，拖动进度时歌词跟随，暂停/继续/切歌可用。
- 手机播放并开启眼镜同步后打开音乐页；眼镜菜单进入音乐页可向运行中的手机扩展请求播放。
- **左侧 144×144 灰度旋转封面，右侧五行定时歌词，当前句固定在第三行高亮**。镜片是绿色单色显示，不是彩屏。歌词按时间轴切换窗口，不宣称已验证平滑逐像素滚动。
- 播放状态、封面和歌词已通过镜片反馈。代码提供常亮 / 30秒 / 60秒显示设置；计时、断连、后台、语音抢占等全部边界尚未逐项长期验收。
- 保留眼镜按键播放/暂停、实体返回退出以及旋钮上一首/下一首协议。

### 已知问题：旋钮太灵敏

**眼镜旋钮轻轻碰到就可能切歌。用户已确认此问题，本版有意保留，不是已修复。** 当前实现有约1秒间隔限制，但没有累计旋转距离阈值；间隔限制不能消除第一次误触。临时建议使用手机切歌、避免触碰旋钮。后续考虑旋转阈值、方向累计和可配置操作。不要把这个实验版当成完成打磨的日常播放器。

其他限制：

- 网易云扫码确认可能提示“环境异常”。本次采用无需登录也能播放的歌曲测试，**没有完成登录验收，不处理风控绕过**。会员、地区、试听与不可播放限制以服务返回为准，不解锁、换源或下载受限歌曲。
- 蓝牙文件传输是串行、带原生文件任务回执及 AP 回执的协议；首次封面/歌词需要传输，不是实时视频。断线或失败会停止，不无限重试。
- App 被强杀/系统终止后的自动唤醒不保证；不要把运行中双向请求等同于万能 BLE 后台拉起。歌词最大192行、24 KiB，长歌词可能截断。
- 整套公开集成源码已做本机构建/测试；镜片实测来自同一音乐实现的私用配套构建，不代表所有自行签名组合均已验收。

## 下载与校验

[TMU1 高风险固件 Pre-release](https://github.com/Turbo1123/Turbo-IO/releases/tag/firmware-strix-1.0.4.12-tmu1)。Release ZIP 与本次修正后实测 ZIP **字节一致**，只改附件文件名，不重新压缩。不要使用修正前的音乐候选包，也不要混用 R3/TNV1/ANIM60 的手机升级门禁。

| 项目 | 校验值 |
| --- | --- |
| ZIP 文件 | `StrixOS-1.0.4.12-TurboMusic-TMU1-EXPERIMENTAL.zip` |
| ZIP 大小 | 9,468,398 B |
| ZIP SHA-256 | `307a0d41aa76b3ed91a8fcc07b09329d76d78a51584c9954c7896d64b1ad9a81` |
| AP SHA-256 | `15da0e4ed255587f3b0f2dc422aff9c01d4ea48f3cf71c73407f3fcd6b2c936f` |
| AP MD5 | `1d3edd747e409e52437755e876c39b37` |

在仓库根目录运行（示例路径需自行替换）：

```sh
gh release download firmware-strix-1.0.4.12-tmu1 --repo Turbo1123/Turbo-IO --dir /absolute/new-downloads
python3 firmware-research/strix-1.0.4.12/native-navigation/music/verify.py \
  /absolute/new-downloads/StrixOS-1.0.4.12-TurboMusic-TMU1-EXPERIMENTAL.zip
```

验证15个成员、原厂13项哈希、AP、清单 Size/MD5 及完整清单哈希。**只有 `nuttx_ap.bin` 内容改变**，清单更新对应 Size/Md5；这不等于官方 OTA 只写 AP，完整更新仍可能重写未改变的负载。只改 AP 是为了缩小改动面，并不保证不会变砖。

## 配套 iOS 构建与签名

macOS + Xcode、Node.js，合法兼容、未加密、thin arm64 的官方1.0.5（201）`Runner.app`，以及你自己的证书、设备和描述文件。参见 [iOS 扩展说明](../../../../official-addon/README.md)。不需要作者私人工程或账号。

```sh
# 高德导航为可选依赖；要保留配套地图导航，先按提示接受 SDK 条款。
node official-addon/setup-amap.mjs --accept-sdk-terms
TIO_MUSIC=1 TIO_NATIVE_NAV=1 TIO_OTA_RESEARCH_ENABLED=1 TIO_AMAP_ENABLED=1 \
  bash official-addon/build.sh embedded com.rayneo.venus.pub

node official-addon/package.mjs \
  --app /absolute/Runner.app \
  --addon /absolute/Turbo-IO/official-addon/build/music/TurboIOPrivateAddon.dylib \
  --profile /absolute/YOUR_PROFILE.mobileprovision \
  --identity YOUR_CERTIFICATE_SHA1 --device YOUR_DEVICE_UDID \
  --bundle com.rayneo.venus.pub \
  --amap-sdk-root /absolute/Turbo-IO/official-addon/build/amap-sdk \
  --experimental-ota TMU1 \
  --firmware /absolute/new-downloads/StrixOS-1.0.4.12-TurboMusic-TMU1-EXPERIMENTAL.zip \
  --out /absolute/NEW_LOCAL_OUTPUT
```

只测音乐可省去高德下载、`TIO_AMAP_ENABLED=1` 和打包的 `--amap-sdk-root`；此时手机地图导航不可用。普通构建不设置 `TIO_MUSIC`，不会默认加入音乐试刷入口。打包器核对音乐/导航编译符号和精确 ZIP，错误配对直接拒绝。未提供任何服务 Key；AI/TTS/天气/高德均使用自己的配置。本机 TTS 不需要云 Key。

通过 Xcode Devices 或自己的安装工具安装输出。不是 App Store 安装流程；签名、到期与系统授权由使用者管理，不能凭重签名冒充原厂 APNs 权限。

## 试刷与第一次播放

1. 先确认兼容版本、眼镜电量至少50%、手机与眼镜连接稳定且没有录音/提词/导航/对话；保留原厂包及旧版资料。没有可靠恢复条件就不要刷。
2. 「TurboIO → 诊断 → TMU1 音乐固件 · 默认锁定」等待内置候选校验通过。
3. 开启15分钟**只下载验收**，回官方固件页检查并下载。确认完整归档和官方解压目录均通过；这一步不授权发送。
4. 官方固件页重新检查版本；两分钟内返回实验页，阅读风险后输入 `TMU1`，允许一次试刷。确认授权1，再回官方页手动开始安装。
5. 传输和安装期间不退出、杀 App、重启、断连或改文件。错误时不要反复点击，不绕过 MD5/SHA 或门禁。
6. **等待升级完成且眼镜正常启动后**，重启手机 App 复位本次升级通道占用；不要在传输中重启。确认原有功能和新菜单可进入。
7. 「TurboIO → 资料与导出 → 网易云音乐」先从右上角菜单播放本机校验曲，再搜索可播放歌曲。开启眼镜同步，选择显示时长。正常时左侧显示封面，右侧显示五行歌词；手机拖动进度、暂停/继续作对照。

这版已修复初次 OPEN 回“成功”却丢失会话、第二包报“眼镜拒绝音乐包（4）”的问题：原厂菜单切换的内部 hide 不再被当成用户退出。真正的退出、销毁和断线检查仍保留；不通过无限 OPEN 重试掩盖错误。

## 架构与协议

手机 `MusicAPI → AVPlayer/MusicPlayer → MusicBridge → 原厂文件传输 → AP music_service → LVGL`；反向 `TMA1 → 原厂业务15/类型6 → MusicBridge → 播放/暂停/切歌`。

- 音频由手机 AVPlayer 走系统音频路由播放，**不是把 MP3 装进眼镜 AP 解码**。
- TMU1文件最大4096 B，32 B头，SID/代数/序号/偏移/CRC；OPEN、CLOCK、COVER、LYRICS、CLOSE、QUERY。AP 回执同时带 active/awake、播放位置和控制请求ID。
- 144×144 L8封面约20 KiB，歌词分块；眼镜根据手机同步的时钟本地选取当前行并绘制旋转封面。固定双缓冲，DMA空闲时换引用，不逐帧堆分配。
- 错误码：1格式，2过期/重放冲突，3忙，4无匹配活动会话。文件发送成功不等于镜片渲染成功。
- 手机只记录数字诊断，不保存歌词/歌曲正文到日志；Cookie 只存本机钥匙串。诊断与歌曲偏好不要上传仓库。

## 离线复现与测试

需要原版1.0.4.12 ZIP（见早期R3 Release）、OHOS LLVM15.0.4（提交 `39bec79f56c3b5a629e4bacac1dc022e1da552d0`）、Node.js、Python capstone/unicorn。无需 BES 私有 SDK。

```sh
uv run --no-project --with capstone --with unicorn python firmware-research/strix-1.0.4.12/native-navigation/build-music.py \
  --stock /absolute/StrixOS-1.0.4.12-ORIGINAL-rollback.zip \
  --llvm /absolute/openharmony/native/llvm/bin \
  --out /absolute/NEW_REBUILD_DIRECTORY

TIO_MUSIC=1 bash firmware-research/strix-1.0.4.12/native-navigation/test.sh \
  /absolute/new-downloads/StrixOS-1.0.4.12-TurboMusic-TMU1-EXPERIMENTAL.zip \
  /absolute/NEW_REBUILD_DIRECTORY/candidate/payload \
  /absolute/NEW_REBUILD_DIRECTORY/firmware-inspection/StrixOS-1.0.4.12
node --test official-addon/package.test.mjs scripts/check-source.test.mjs
```

脚本只写新目录，不连接设备、不授予刷写权限。检查10项菜单44场景、音乐文件/生命周期、居中歌词/边缘留空/seek、DMA延迟释放、导航/显示/动图回归、AP-only字节审计和内存检测。重建 AP 必须与上表一致；ZIP时间戳可不同，手机只接受 Release 原始 ZIP。测试通过不能代替真机安全性。

API编码参考 [Beans Music](https://github.com/XIaodou0416/Beans-Music) 提交 `f9881318caf774129205c3160510ef0dfa318adc`，保留 [MIT许可](../../../../official-addon/music/Beans-MIT-LICENSE.txt)；并非合并整个 Beans App。原创项目仍按仓库非商业许可，第三方代码、原厂固件和音乐内容的权利保持独立。固件中的头像是作者授权公开的素材，不含音乐账号或个人服务配置。
