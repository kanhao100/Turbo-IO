# ANIM60：Turbo Display 本地动图实验

> **高风险实验固件，不是推荐升级。** 仅供熟悉固件、可承担设备损坏风险的开发者在匹配的雷鸟 iO / Strix OS 1.0.4.12 研究机上复现。断电、传输中断、版本不匹配或 AP 错误可能使设备无法启动或失去 OTA；原厂回滚不保证救砖。普通 SDK/App 开发无需刷机。

这次验证的是：在 **application (`nuttx_ap.bin`)** 内置序列帧，眼镜端本地定时切换和绘制，而不是让手机每帧蓝牙传图。现有第八项 **Turbo Display** 仍是显示测试入口，第九项 TNV1 导航保留；它并非新的通用动画播放器、任意图片上传接口或视频投屏。

![动画素材预览（浏览器模拟，不是镜片实拍）](../src/official-addon/research/animation-runtime-v1/assets/encoded-v1/preview-approx-8fps.gif)

## 已验证与边界

| 项目 | 结果 |
| --- | --- |
| 研究机实刷 | 2026-09-22 用户确认进入页面并看到动画，30 秒结束时计数 1799，主观反馈播放稳定 |
| 实验节奏 | 目标提交 60 次/秒；12 张角色姿态每秒切换约 8 次，底部动态标记随提交更新。**1799/30s 不是光学面板 60 FPS 实测** |
| 图像 | 192×176 L8 内置 atlas，角色画面按眼镜单色显示；网页 GIF 仅供查看内容与节奏 |
| 本机离线测试 | 主机 ASan/UBSan、ARM 链接执行、原第八/第九项回归、AP-only 字节审计通过；这些不等于断电恢复或长期热稳定验收 |
| 未验证 | 长时间运行、全部电量/温度条件、所有终止分支、其他固件/眼镜、物理面板帧率及可靠回滚 |

实测 AP SHA-256：`68c8f2949e6fb17d41b5d71d1221a303c83f0b29b8f5aabd5487cca0da0dc9ad`。实测 ZIP SHA-256：`46d7fd38fdfcb37804b9d8d549f6e224cbfd7dcf149f9855b5ab8afb4d25e579`。ZIP 打包时间戳可能使重新构建 ZIP 的哈希不同；**只能用 AP 哈希与逐项负载审计判断是否重建了相同 AP，不能把新 ZIP 冒充实测原包**。

发布附件：[ANIM60 实验固件 Pre-release](https://github.com/Turbo1123/Turbo-IO/releases/tag/firmware-strix-1.0.4.12-anim60)。其中 ZIP 是上述实测原包，不是手机 IPA。固件内原厂代码/资源版权归各自权利人，本仓库的原创代码许可不覆盖它们。详见仓库 [第三方说明](../../../../THIRD_PARTY_NOTICES.md)。

## 离线重建 AP

源码在 [`src/official-addon/research/animation-runtime-v1`](../src/official-addon/research/animation-runtime-v1/)；帧 atlas、编码帧与可复现生成脚本一并公开。需要原版 Strix OS 1.0.4.12 OTA ZIP、自行安装的 OHOS LLVM 15.0.4、Node.js，以及 `capstone`、`unicorn` Python 依赖。在仓库根目录运行：

```sh
uv run --no-project --with capstone --with unicorn python firmware-research/strix-1.0.4.12/native-navigation/build-animation.py \
  --stock /path/to/StrixOS-1.0.4.12-ORIGINAL-rollback.zip \
  --llvm /path/to/openharmony/native/llvm/bin \
  --out /tmp/turbo-anim60-fresh-build
```

输出目录必须是不存在的新路径，脚本不会删除旧文件，也不会连接设备或触发刷机。成功时会核对 AP 为上述 SHA，并生成 `checks/receipt.json` 与字节审计。只修改 AP 内容，另外 13 个 OTA 负载保持原版字节；**官方完整 OTA 仍可能重新写入这些未变化的负载**，所以“AP-only 改动”不等于“设备只刷 AP”。

公开的官方 App 扩展源码目前**不包含 ANIM60 专用手机 OTA 授权门禁或自动升级入口**；不要把 TNV1/R3 的升级开关、版本号或候选包硬改成 ANIM60 来试刷。此页和 Release 用于源码审阅、离线重建与已实测样本研究；计划刷写者必须另行完成匹配版本、电量、空闲任务、完整包校验与可审计的授权流程。
