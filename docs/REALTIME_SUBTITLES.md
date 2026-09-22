# 实时字幕 · 0.3.4 (10)

在已经通过用户镜片验收的字幕显示基础上，接入原生字幕收音与四家 ASR。底部“字幕”页分为正在转写、会话历史，右上角为设置。普通录音的问题继续单独保留在 DEVICE_ISSUES.md，本版不改变普通录音协议。

## 使用

1. 连接并认证眼镜，结束眼镜现有任务。
2. 字幕 → 设置，选择 Azure Speech / Deepgram Nova-3 / ElevenLabs Scribe v2 Realtime / 阿里云。阿里云再选择推荐的 Qwen-Audio 3.1 Streaming，或保留的 Qwen3 Realtime 兼容/实验模式。Azure 填 Region；阿里云粘贴中国北京或新加坡控制台中的完整 Workspace Host，并填写同地域 Key。其余服务只需自己的 Key。不需要 DeepSeek，也不生成 AI 回答。
3. 选择识别语言、是否保存音频和时长上限，保存。保存或启动 App 不会开启收音。
4. 回到字幕页点击开始，或直接双击眼镜旋钮。启动不再弹出二次确认；请在使用前自行取得参与者同意。
5. 眼镜确认字幕起录后，音频只进入当前 ASR，中间稿与定稿更新镜片。手机显示音频时长、电平、定稿与缺口。
6. 再次双击眼镜，或在手机点击“停止并保存”。App 立即停止上传、完成文件保存并释放本轮，不再要求到手机点击“我确认眼镜已退出”。异常断连不会自动重开录音。

### 阿里云双模型、双协议与地域

两种阿里云模型不是新旧版本关系，App 不会只替换模型字符串，而是按选择切换完整协议：

- `qwen-audio-3.1-asr-flash-streaming`（新安装默认、推荐）：`/api-ws/v1/inference`，`run-task` 初始化，收到 `task-started` 后发送 binary PCM，读取 `result-generated`，停止时发送 `finish-task`。模型服务支持时间戳、热词与上下文能力；本版字幕先接入基础流式识别、语言提示和心跳，尚未提供热词/上下文编辑界面。
- `qwen3-asr-flash-realtime`（兼容 / 实验）：`/api-ws/v1/realtime?model=...`，`session.update` 初始化，收到 `session.updated` 后通过 Base64 JSON `input_audio_buffer.append` 上传音频，读取 `text + stash` 临时稿与 `completed.transcript` 定稿，停止时发送 `session.finish`。服务端 VAD 使用 threshold 0.2、静音 400 ms。

从 0.3.3 升级且已经保存阿里云设置时，旧记录没有模型字段，App 会继续选中 Qwen3 Realtime，避免升级后静默换协议；新安装和新建默认配置使用 Qwen-Audio 3.1 Streaming。两者复用同地域 Workspace Key，但网络事件完全隔离。

当前仅接受生产用 Workspace 专属 Host：`{WorkspaceId}.cn-beijing.maas.aliyuncs.com`（中国北京）或 `{WorkspaceId}.ap-southeast-1.maas.aliyuncs.com`（新加坡）。App 根据完整 Host 自动识别地域，不替用户猜选；DashScope 公共域名、trial 试用域名、URL/路径以及其他地域会被拒绝。北京与新加坡都支持上述两个模型，但 Workspace、API Key、模型权限和数据所在地域彼此隔离，不能交叉使用；一般选择更靠近手机网络与部署位置的一侧来降低网络延迟，价格、配额及区域功能仍以各自控制台为准。Keychain 也按完整 Host 分仓，切换地域不会把旧 Key 自动发往新地域。

这次只给“实时字幕”增加双模型选择。AI 语音对话和已保存录音的手动转写仍固定使用原有 `qwen-audio-3.0-asr-flash-streaming` Task 协议，不受字幕页模型选项影响。

### 双击快捷键

设置 → 读取眼镜快捷键 → 将双击设为字幕 → 再次读取，确认显示“双击已设置为字幕”。只改 `double=4`，保留完整原旋钮配置；备份原双击值按设备隔离，支持恢复，不猜测未知原值。

开启“双击启动实时字幕（永久记住）”后，选择会写入 `UserDefaults`，跨 App 重启保留。双击旋钮或在眼镜菜单打开字幕会按已保存配置直接启动；再次双击发出的同会话停止事件会立即停止云端、保存文本/音频并释放会话。眼镜协议没有独立的“双击来源”字段，因此字幕菜单入口与双击共用此策略。

App 在每次认证连接后读取完整旋钮设置；若永久开关仍开启但眼镜的 `double=4` 丢失，会在保留长按及其他未知字段的前提下自动恢复。锁屏与正常后台使用已声明的 `external-accessory`、`bluetooth-central` 模式以及四家服务各自的流式保活机制；不会用静音播放等方式绕过 iOS。用户从多任务界面强制结束 App 后，iOS 不保证由眼镜事件冷启动。旧 AI 语音待命在开启快捷启动时暂停。

### 文本与音频

- 每次会话独立保存到 Application Support/RealtimeSubtitlesV1，排除 iCloud 备份；Key 不进历史文件。
- 定稿逐条保存为 JSONL；停止时临时稿明确标为未定稿。音频为 ASR 使用的处理后 PCM16/16kHz/mono WAV，不宣称原始双声道无损。
- 60 秒分段，已知断流另起片段、不合成静音、不补传云端。最多 256 MiB 音频/16 MiB 文字/100 次历史，存储失败会停止并保留已收到的文件。
- 历史支持名称/最近字幕搜索、改名、按顺序回听、文字 TXT 和文本+WAV ZIP 导出、二次确认删除。运行期间不能删除、改名或导出活动会话。
- 字幕时间是手机收到事件的时间，不是逐字对齐。强杀时最后数据可能不完整，未完成会话明确标记。

### 延迟实验

字幕设置中可永久开启“记录分阶段延迟”。实时页展示最近值与平均值，并可分享脱敏报告。统计覆盖：启动确认到首个音频包、音频包到达间隔、原生接收回调到 App 主线程、ASR 启动到服务就绪、首包到首条结果、最近音频包到识别结果、识别结果到提交眼镜。统计只保留在内存中，App 重启自动清空；开关本身永久保存。

眼镜音频协议未携带能与手机单调时钟对齐的采集时间戳，因此“启动确认 → 首包”只能用于发现链路等待，不能解释为麦克风到 App 的绝对单向传输延迟。云端指标也包含识别/VAD/断句时间；它适合比较异常会话和供应商，不冒充服务端内部耗时。报告不包含音频、字幕正文、密钥、原始序号或设备标识。

## 原生协议依据与边界

互操作字段核对使用雷鸟官网公开 Android 1.0.5 包，SHA-256 `770ba0793d31609aa1e4477db2f8a7aec2c8acc4d9c6ab43d57b0dfc720d3ab3`。包、厂商代码和反汇编只用于本机临时分析，不提交源码或分发。

| 阶段 | 实际消息 |
| --- | --- |
| App 发起 | business 19/type 1，`sid`、`trigger=1`、`code=0`、`settings`；不强制抢占 |
| 眼镜发起 | 同 business/type 1；用户已允许且本地空闲时，以相同 SID 回复 type 2/code 1/`final_settings` |
| 启动回执 | type 2，code 1 才接受；冲突/权限/低电量等其他码停止，不盲目覆盖 |
| 设置 | `mode=classic`、同一 source/target language（仅转写）、`save_audio`、`direction=around` |
| 显示 | 已验的 type 7 → type 8 同 SID 回执 → type 5/mode 3/status 0/source_transcript |
| 音频 | **type 4**，JSON `sid/seq` 与二进制 Opus；不是 AI 对话 business 13/type 3 |
| 结束 | **type 3/reason_code=2**；不同于纯显示预览的 reason_code 10 |
| 双击 | 官方 CrownDoubleTapAction.liveCaptions 的实际值为 4，不是枚举序号猜测 |

字幕与显示共用同一个协议 SID，不开启另一条 AI 语音会话。音频按 SID、设备、接收时间和序号检查；重复、倒序及到达时间倒退的包丢弃。实机表明 `seq` 不是可假定逐包 `+1` 的公开契约，因此严格递增但步长不为 1 只计入脱敏诊断，不再伪造缺口或切 WAV；只有字幕接收队列明确溢出、有效音频到达明显中断或解码失败才记录缺口。libopus 解码到 16kHz mono（库内下混），不把 stereo 的单侧误当整体；不能解码的包停止并提示，而不伪造音频成功。

手机与眼镜固件兼容性仍需本机实测：Android 字段依据不等于所有 iOS/固件组合都相同。显示、转写与录音已通过当前设备实测；永久快捷键恢复、再次双击停止以及长时间锁屏后台仍不能由 CI 代替验收。

## 验证

源码检查；rayneo-protocol 原生字幕/快捷键测试；rayneo-captions 服务请求/格式/日志/WAV 测试；模拟器运行时测试使用假眼镜、假 ASR 与合成音频检查四家链路、正确 SID/启动回执、重复/缺口、断连、准备取消、超时、停止后的迟到回调和存储边界；UI 测试检查实时/历史/设置页。

不使用真实服务 Key、用户音频或 Apple 签名凭据。设备 CI 输出未签名 0.3.4 (10) IPA；IPA 文件名与 Actions 产物名包含 `v0.3.4-build10`，仍需用户自己的签名才能安装。
