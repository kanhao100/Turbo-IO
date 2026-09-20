# Azure 实时字幕 V1（实验，待真机验收）

入口：**会话 → Azure 实时字幕 · V1 实验**。这是单独的字幕模式，不是原有阿里云 + DeepSeek 对话的供应商替换。原有模式与字幕模式不能同时占用语音通道。

## V1 范围

| 功能 | 实现与边界 |
| --- | --- |
| 实时识别 | 眼镜语音 Opus → 本机 16 kHz/16-bit/mono PCM → Azure Speech SDK continuous recognition。没有手机麦克风回退、LLM 或 TTS。 |
| 流式显示 | recognizing 更新当前句，recognized 保存定稿；空的 NoMatch 不把旧草稿当定稿。手机显示历史，镜片提交最新不超过 480 UTF-8 bytes 的完整字素窗口。部分结果最多 4 次/秒；定稿立即提交。不是逐 token 显示，也不保证镜片行数或渲染回执。 |
| 长时会话 | 可选 30 / 60 / 120 分钟保护上限；独立于旧助手的 120 秒限制。120 分钟是策略上限，不是已通过的持续采音实测。 |
| 无人声退出 | 1 / 5 / 15（默认）/ 30 / 60 分钟，或不按静音退出。本地 WebRTC VAD 在 200 ms 窗口内有 120 ms 人声才更新计时；不以包到达或字幕到达判定人声，不据此切句。噪音可能误触发。 |
| 音频中断 | 5 秒无有效音频提示缺口，15 秒停止；已知队列丢包、解码失败和大于 200 ms 到达间隔也标记缺口。无法检测固件/传输层的全部缺失。 |
| 云连接 | 连接准备超时 15 秒；有持续人声但 30 秒无识别事件也触发恢复。重试间隔 1 / 2 / 4 秒，3 次未恢复后停止。仅有效识别结果重置预算；不补传离线音频。 |
| 字幕历史 | 本机按会话逐句写入 JSONL 并 synchronize；手动停止/重连时的草稿标为 unfinished，已知缺口写 gap。进程被杀时最后未完成句可能丢失；读取时忽略撕裂的最后一行，不改原文件。 |
| 可选录音 | 每次重新同意，默认关闭。将实际收到的 PCM 保存为最多 60 秒的 WAV，缺口另起一段；不缓存整段音频、不生成静音填补。约 115 MB/小时。 |
| 导出/删除 | 历史页面导出完整 TXT、单独分享 WAV、滑动删除并二次确认。只预览最近 200 条；运行中禁删。不是时间对齐 SRT，不含说话人分离或翻译。 |

## 使用与凭据

1. 使用完整仓库，在 Mac 安装 Xcode、XcodeGen。执行 `node scripts/start.mjs --device`，选择 `RayNeoCompanionDevice`、自己的 Team 和 iPhone。Windows 不能直接构建/签名 iOS App；CI 可以检查未签名编译，但不会生成可直接安装的签名 IPA。
2. 真机工程通过微软官方 [speech-sdk-spm](https://github.com/microsoft/speech-sdk-spm/tree/253f49a30de749996e142ccee573da9a431a034f) 引入 `MicrosoftCognitiveServicesSpeech-iOS`。固定 revision `253f49a30de749996e142ccee573da9a431a034f`（SDK 1.51.2）；没有复制 SDK 二进制到源码。首次解析包需能访问 GitHub 及微软下载域名。本地预览工程不依赖 Azure SDK。
3. 在字幕页填写你自己的 Azure Speech 资源的 **Key + Region**（仅区域 ID，不是 URL）。选择 en-GB、en-US 或 zh-CN。V1 不包含私有端点、中国云、自定义模型端点或自动语言检测支持。
4. Key 按 Region 隔离保存在本机 Keychain，`AfterFirstUnlockThisDeviceOnly`；从不写入 UserDefaults、字幕、录音、日志或源码。重启 iPhone 后必须先解锁一次。面向多人发布时应另外设计后端短期 token，不要把组织共用 Key 打包进 App。
5. 确认上传/存储提示（请先取得参与者同意），开启字幕待命，再**主动唤醒眼镜**。5 分钟不唤醒自动退出。切入模式会关闭旧助手自动待命，结束后也不会擅自恢复。
6. 点“停止字幕、上传和本地录音”才是停止；关闭设置页面不是停止。停止时同时提交眼镜停止采音和退出命令。断连时无法确认眼镜是否收到，需查看眼镜指示/手动退出。

开启模式不会假造唤醒、直接调用手机麦克风或不断重发开始采音命令。眼镜 type 8 主动退出后立刻停止本地上传/录音；连接恢复、回到前台、重启 App 都不会自动重新采音。需再次明确开启并唤醒。

## 后台能力：不能承诺不被系统杀掉

沿用工程已经声明的 `bluetooth-central` / `external-accessory` 后台能力，实际可用性取决于配件会话、iOS、眼镜固件、电量与热状态。没有添加静音播放、假音频后台模式或无限后台任务。有限后台任务只用于停止后的文件收尾，不能作为持续运行保证。

若系统挂起，定时器和 SDK 回调可能一起停；恢复后按单调时间检查缺口/会话上限，不重放过期音频。若强制退出/内存回收，结束回调可能根本不会运行；历史没有 stopped 的会话显示为进行中或中断，未完成句和最后一小段 WAV 尾部可能丢失。WAV 每约一秒更新头部并同步，但不保证断电恢复完整。**必须分别做前台、锁屏、切后台的真机验收。**

## 存储与资源上限

- 位置：App Application Support / `AzureCaptionsV1`，排除 iCloud 备份；iOS 文件保护为首次解锁后可用。文字和音频是敏感内容，用户分享出的副本不受 App 管理。
- 每会话：16 MiB JSONL、单句 32 KiB；音频 256 MiB、最多 512 段。硬盘满、写入过慢或超过限制时停止并提示，不假装录音完整。
- 最多 100 次历史；已有数据达到 736 MiB 时不新建会话，为当前会话音频、日志和导出预留空间。不自动删除用户历史；先导出再手动删除。
- PCM SDK 操作队列与写盘队列各最多 64 个待处理块；接收主队列沿用 32 包上限。已知丢包会上报，取消后 SDK 回调由 generation 隔离。SDK 自身内部缓冲属于微软实现；没有声称整个进程的内存上限。
- 文字时间是手机收到事件的时间，不是音频采样级定位。录音缺口期间不合成或重新上传数据，不能用于要求无遗漏的证据记录。

## 验证

GitHub workflow `.github/workflows/azure-captions.yml` 使用只读权限，无 Azure Key、签名证书、上传音频或安装动作：

```sh
node --test scripts/check-source.test.mjs
node scripts/check-source.mjs
swift test --package-path rayneo-captions
swift test --package-path rayneo-protocol
node scripts/start.mjs --local --no-open
node scripts/test-caption-boundaries.mjs
node scripts/start.mjs --device --no-open
xcodebuild -project apps/RayNeoCompanion/RayNeoCompanion.xcodeproj \
  -scheme RayNeoCompanionDevice -destination 'generic/platform=iOS' \
  -derivedDataPath apps/RayNeoCompanion/build-captions-device CODE_SIGNING_ALLOWED=NO build
```

Fork 若未开启 Actions，需要仓库所有者在 GitHub 开启；请以该 PR 的实际检查结果为准。Swift 单测覆盖静音/缺音区别、2 小时策略、VAD 抑制短噪音、重试预算、Unicode 截断、JSONL 恢复、WAV 分段/头部/字节限额。模拟器测试覆盖不上传、不恢复录音同意和钥匙串隔离。不能替代真机 SDK/协议端到端测试。

真机验收（合并前逐项记录，不预填通过）：

- [ ] 未开启/仅待命时没有音频上传；真实唤醒后收到中间结果和定稿；手机/镜片文本一致。
- [ ] 旧语音助手、普通录音、提词器与字幕互斥；诊断界面也不能抢发语音通道命令。
- [ ] 1 分钟静音退出、不按静音退出、有短噪声/持续人声；音频断流 15 秒单独停止。
- [ ] 前台 10 分钟 → 30 分钟 → 120 分钟，监控延迟、内存、温度、电量和实际 Azure 用量。
- [ ] 锁屏和切后台各测试同样时长；电话/音频中断、低电量、网络切换、眼镜断连/退出。
- [ ] 错误 Key/Region/额度与断网重试；停止后迟到回调不更新字幕、不重开录。
- [ ] 音频开关默认关闭、每次需再确认；播放分段 WAV、导出全文、模拟磁盘满与强杀后恢复。

API 依据：[音频流格式](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/how-to-use-audio-input-streams)、[PushAudioInputStream](https://learn.microsoft.com/en-us/objectivec/cognitive-services/speech/spxpushaudioinputstream)、[AudioConfiguration](https://learn.microsoft.com/en-us/objectivec/cognitive-services/speech/spxaudioconfiguration)。未修改微软 SDK 的隐私/服务端保留策略；云端数据管理需遵循你所用 Azure 资源的配置及条款。
