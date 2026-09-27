# ANIM60 动图实验 · Strix OS 1.0.4.12

**高风险实验固件，不是推荐更新，也不是可直接安装的手机 App。非开发者请勿刷写。** 断电、传输中断、版本不匹配或 AP 错误可能使眼镜无法启动或失去 OTA；原厂回滚不保证救砖。使用者自行承担研究风险。

2026-09-22 研究机实刷后，用户确认 Turbo Display 内置动画正常显示。30 秒末计数为 1799 次提交，**不是物理面板 60 FPS 测量**。长期运行、低电量、温度、故障恢复和其他固件均未验收。动画复用第八项 Turbo Display；第九项原生导航仍保留。本实验不是 GIF 上传、视频投屏或通用眼镜 App 安装平台。

附件 `StrixOS-1.0.4.12-TurboAnimation-ANIM60-CANDIDATE-NOT-APPROVED.zip` 是此次实刷的原样包，SHA-256：`46d7fd38fdfcb37804b9d8d549f6e224cbfd7dcf149f9855b5ab8afb4d25e579`。其中 `nuttx_ap.bin` SHA-256：`68c8f2949e6fb17d41b5d71d1221a303c83f0b29b8f5aabd5487cca0da0dc9ad`；另外 13 项 OTA 负载与原版字节相同，但完整 OTA 仍可能写入这些未修改项。

源码、素材、离线重建命令与验收边界见 [ANIM60 说明](https://github.com/Turbo1123/Turbo-IO/blob/main/firmware-research/strix-1.0.4.12/native-navigation/animation/README.md)。公开源码**没有 ANIM60 专用手机 OTA 授权门禁**；不要把 R3/TNV1 的授权和候选包混用或直接替换。这里只提供研究样本，不提供手机签名包、账号、密钥或刷机服务。原厂内容版权归各自权利人，本仓库原创代码许可不覆盖原厂固件。
