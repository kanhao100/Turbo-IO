# 实时字幕与全天智记 · 0.3.5 (12)

在已经通过用户镜片验收的字幕显示基础上，接入原生字幕收音、四家云 ASR 与可选的用户自建 Qwen3-ASR。底部“字幕”页分为实时字幕、全天智记、历史记录，右上角为统一设置。普通录音的问题继续单独保留在 DEVICE_ISSUES.md，本版不改变普通录音协议。

## 使用

1. 连接并认证眼镜，结束眼镜现有任务。
2. 字幕 → 设置，选择 Azure Speech / Deepgram Nova-3 / ElevenLabs Scribe v2 Realtime / 阿里云，或主动选择自己的 Qwen3-ASR OpenAI Realtime 兼容端点。阿里云再选择推荐的 Qwen-Audio 3.1 Streaming，或保留的 Qwen3 Realtime 兼容/实验模式。Azure 填 Region；阿里云粘贴中国北京或新加坡控制台中的完整 Workspace Host，并填写同地域 Key。自建服务必须填写完整 `wss://.../realtime` 地址；其余服务只需自己的 Key。不需要 DeepSeek，也不生成 AI 回答。
3. 选择识别语言、是否保存音频和时长上限，保存。保存或启动 App 不会开启收音。
4. 回到字幕页点击开始，或直接双击眼镜旋钮。启动不再弹出二次确认；请在使用前自行取得参与者同意。
5. 眼镜确认字幕起录后，音频只进入当前 ASR，中间稿与定稿更新镜片。手机显示音频时长、电平、定稿与缺口。
6. 再次双击眼镜，或在手机点击“停止并保存”。App 立即停止上传、完成文件保存并释放本轮，不再要求到手机点击“我确认眼镜已退出”。异常断连不会自动重开录音。

### 全天智记

“字幕 → 全天智记”是独立于页面生命周期的 App 级运行状态机。首次安装默认关闭；用户开启后会记住同一副已认证眼镜、自动/固定语言和镜片显示选择。App 正常重启或该眼镜重连后自动恢复 `life_log_guide/switch`，收到 A1 后回复 A2 并发送 A8 `inRealtimePage=true`，随后把 A3 中每个 240 字节 Opus 帧解码为 16 kHz 单声道 PCM，仅在内存中送入当前 ASR。

- 默认自动检测语言并在镜片显示；关闭镜片显示不会停止转写。Deepgram 在当前中文场景不允许自动模式，必须明确选择中文、美国英语或英国英语，不会偷偷换供应商。
- 只把 final、unfinished、gap 和系统状态写入 `Application Support/AlwaysOnTranscriptsV1/YYYY-MM-DD`；不创建 Opus、PCM、WAV、`.rnp` 或原始协议包。partial 只留在内存和镜片。
- A4 缓存包首版只验证 taskId、frameCount 和长度，记录一次可见 gap，不上传 ASR，避免未知顺序造成重复转写。客户端 VAD 和静音节费仍是 TODO。
- ASR 网络错误按 1、2、4 秒重连。连接中断本身会记 gap，因为断线前已上传但尚未定稿的音频可能丢失；重连期间最多缓存约 2 秒 PCM，溢出或任务结束前未恢复也会记 gap。认证、额度和配置错误不盲目重试。
- 修改供应商、模型、语言或精度时，可选择立即只重连 ASR、下一次 A1 生效或取消。眼镜采音不因云端重连而重启。
- 历史按本地自然日查看和搜索，支持 TXT、结构化 ZIP、确认删除；跨日未定稿留在旧日。App 异常中断后下次启动写入明确的缺失 gap。存储失败会立即关闭全天智记并向眼镜发送 A6、switch/guide OFF、A8=false。
- 全天智记与普通字幕、AI 对话、眼镜录音和提词互斥。普通字幕双击事件不能抢占全天智记。强制结束 App 后 iOS 不会继续接收音频；重新打开只能记录中断，不能补造期间内容。

旧版 `AlwaysOnLocalProbeV1` 的 `.rnp` 不会自动删除，也不会继续生成；全天智记页提供单独的确认删除入口。

### 阿里云双模型、双协议与地域

两种阿里云模型不是新旧版本关系，App 不会只替换模型字符串，而是按选择切换完整协议：

- `qwen-audio-3.1-asr-flash-streaming`（新安装默认、推荐）：`/api-ws/v1/inference`，`run-task` 初始化，收到 `task-started` 后发送 binary PCM，读取 `result-generated`，停止时发送 `finish-task`。模型服务支持时间戳、热词与上下文能力；本版字幕先接入基础流式识别、语言提示和心跳，尚未提供热词/上下文编辑界面。
- `qwen3-asr-flash-realtime`（兼容 / 实验）：`/api-ws/v1/realtime?model=...`，`session.update` 初始化，收到 `session.updated` 后通过 Base64 JSON `input_audio_buffer.append` 上传音频，读取 `text + stash` 临时稿与 `completed.transcript` 定稿，停止时发送 `session.finish`。服务端 VAD 使用 threshold 0.2、静音 400 ms。

从 0.3.3 升级且已经保存阿里云设置时，旧记录没有模型字段，App 会继续选中 Qwen3 Realtime，避免升级后静默换协议；新安装和新建默认配置使用 Qwen-Audio 3.1 Streaming。两者复用同地域 Workspace Key，但网络事件完全隔离。

当前仅接受生产用 Workspace 专属 Host：`{WorkspaceId}.cn-beijing.maas.aliyuncs.com`（中国北京）或 `{WorkspaceId}.ap-southeast-1.maas.aliyuncs.com`（新加坡）。App 根据完整 Host 自动识别地域，不替用户猜选；DashScope 公共域名、trial 试用域名、URL/路径以及其他地域会被拒绝。北京与新加坡都支持上述两个模型，但 Workspace、API Key、模型权限和数据所在地域彼此隔离，不能交叉使用；一般选择更靠近手机网络与部署位置的一侧来降低网络延迟，价格、配额及区域功能仍以各自控制台为准。Keychain 也按完整 Host 分仓，切换地域不会把旧 Key 自动发往新地域。

这次只给“实时字幕”增加双模型选择。AI 语音对话和已保存录音的手动转写仍固定使用原有 `qwen-audio-3.0-asr-flash-streaming` Task 协议，不受字幕页模型选项影响。

### 双击快捷键

设置 → 读取眼镜快捷键 → 将双击设为字幕 → 再次读取，确认显示“双击已设置为字幕”。只改 `double=4`，保留完整原旋钮配置；备份原双击值按设备隔离，支持恢复，不猜测未知原值。

开启“双击启动实时字幕（永久记住）”后，选择会写入 `UserDefaults`，跨 App 重启保留。双击旋钮或在眼镜菜单打开字幕会按已保存配置直接启动；运行中再次收到同一眼镜的 type 1（即使附带新 SID），App 会把它当作停止手势，以当前活动 SID 通知眼镜退出、停止云端并保存文本/音频。首次启动后 1.5 秒内的重复 type 1 会被忽略。眼镜协议没有独立的“双击来源”字段，因此字幕菜单入口与双击共用此策略。

App 在每次认证连接后读取完整旋钮设置；若永久开关仍开启但眼镜的 `double=4` 丢失，会在保留长按及其他未知字段的前提下自动恢复。锁屏与正常后台使用已声明的 `external-accessory`、`bluetooth-central` 模式以及所选服务的流式保活机制；不会用静音播放等方式绕过 iOS。用户从多任务界面强制结束 App 后，iOS 不保证由眼镜事件冷启动。旧 AI 语音待命在开启快捷启动时暂停。

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
| 设置 | `mode=classic`、同一 source/target language（仅转写）、`save_audio`；方向默认 `around`，可选静态逆向得到的 `ahead`（待真机验证） |
| 显示 | 已验的 type 7 → type 8 同 SID 回执 → type 5/mode 3/status 0/source_transcript |
| 音频 | **type 4**，JSON `sid/seq` 与二进制 Opus；不是 AI 对话 business 13/type 3 |
| 结束 | **type 3/reason_code=2**；不同于纯显示预览的 reason_code 10 |
| 双击 | 官方 CrownDoubleTapAction.liveCaptions 的实际值为 4，不是枚举序号猜测 |

### 定向收音：Android 1.0.5 静态逆向结果

官方包的字幕方向选择列表是 `around`（四周）和 `ahead`（前方），位于 Dart AOT 常量池 `pp+0x102118`；切换逻辑把 `ahead` 映射为 `PickupDirectionFront` 埋点动作。`front`、`surround` 也出现在包内，但属于埋点/文案相关常量，不能用作字幕协议的取值。Turbo-IO 已接入两种取值；尚未在目标眼镜上抓到 `ahead` 包，也未测量两种模式的实际收音差异。

静态调用链进一步表明：字幕启动时，`CaptionData` 中的方向经 `direction` 键转换为 `GlassesCaptionTranslateSettings`，进入 business 19/type 1 的 `settings.direction`；眼镜发起会话的 type 2 `final_settings.direction` 走相同转换。`CaptionData` 的本地配置 JSON 还写 `listening_direction`，但业务 19 的 `settings` 序列化器只写 `mode/source_language/target_language/save_audio/direction`，不能把本地配置键额外加到设备包里。

| 静态证据（官方包 `libapp.so` 地址或 `pp.txt` 偏移） | 支持的结论 |
| --- | --- |
| `pp+0x102118`；`0x19f398c–0x19f39b8` | 字幕选项为 `around/ahead`，`ahead` 对应前方埋点动作 |
| `0x2858e58 → 0x17cf004 → 0x17cedcc → 0x180061c` | 本地 `CaptionData` 方向转换后进入启动 type 1 的 `settings.direction` |
| `0x2770688 → 0x17cf004 → 0x17cedcc → 0x17ceb6c` | 同一方向进入 type 2 的 `final_settings.direction` |
| `0x2770338–0x2770384`；`BusinessID.aiSubtitle=0x13`；`syncServiceSettings=0x0a` | 会话内 type 10 消息的嵌套 JSON 和业务号 |

这些字段说明 App 怎样要求眼镜选择收音模式；眼镜内部的麦克风处理算法、切换耗时和实际指向性仍要靠设备实验确定。

会话中切换方向时，官方 App 调用 `sendSyncServiceSettingsCmd(taskId, direction)`，发送 business 19/type 10：

```json
{"sid":"<当前字幕会话 SID>","settings":{"direction":"ahead"}}
```

切回四周时将 `direction` 改为 `around`。这个值由调用方传入。`GlassesCaptionEventType.syncServiceSettings` 的值为 `0x0a`，公共发送函数选用 `BusinessID.aiSubtitle=0x13`。静态代码中的 `Future<bool>` 只能证明发送调用报告成功或失败；目前没有确认固件已应用方向的独立回执或错误码。另一个日志“收音方向，热同步 0x02”属于 ProactiveAI 路径，不能拿来解释字幕 type 10。

Turbo-IO 的协议层现已定义仅接受 `around/ahead` 的方向类型；type 1 `settings`、type 2 `final_settings` 使用所选值，`validateOutbound` 同步校验；活动会话以当前 SID 构造 type 10 的嵌套 `settings.direction`。运行层只在 `listening` 阶段发送切换命令，记录脱敏方向、发送状态和音频包计数；同步或异步失败不终止字幕，界面显示失败并提供“重试收音切换”。发送失败按 SDK 消息 ID 匹配，迟到的旧失败记为 `stale_send_failed`，不覆盖最新请求状态。若眼镜返回 type 10，诊断只记其类型和 code，不能预先解释为固件已应用的回执。界面把发送成功表述为“指令已发送，实际效果待确认”。

### 定向收音真机验收

现有官方 Android 包的静态调用链已给出 `around/ahead` 和业务 19/type 1、type 2、type 10 的实现依据；iPhone 与眼镜即可进行 Turbo-IO 的发送、音频连续性和声学验收。下面的 3 dB 等门槛是本项目的实验验收线，不是厂商公布的性能指标。保留 App、眼镜固件、手机系统版本及原始实验记录。同一副眼镜只连接一个客户端；以后若增加官方 App 对照，按各自正常解绑/连接流程操作。

1. **协议证据与可选交叉验证**：先保留上述官方包静态逆向依据，并用协议测试核对 Turbo-IO 构造的 type 1 `settings.direction`、type 2 `final_settings.direction` 及当前 SID 的 type 10 `settings.direction`。在现有 iPhone 与眼镜上，记录请求方向、SDK 发送/异步失败结果、活动会话和切换前后的 type 4 音频计数；脱敏诊断不含原始 SID 或完整 JSON，SDK 提交成功也不是固件应用成功的 ACK。若以后具备受控 Android 设备、同一官方 App 和眼镜，可加强交叉验证：依次“四周启动 → 活动会话切前方 → 切回四周 → 停止 → 前方启动”，另做一次眼镜主动启动；在应用层记录 business 19 的 type 1 `settings.direction`、type 2 `final_settings.direction`、两次 type 10 完整 JSON、活动 SID、时间和可能的错误/回执，并确认切换前后 type 4 继续到达。若从 HCI 采集，先完成链路重组及必要的应用层解码，不能把原始蓝牙字节直接当作业务 JSON。只保留协议元数据，不保存参与者语音。没有 Android 时将“官方 App 动态抓包”记为未完成的交叉验证，不阻断以下 iPhone 真机实验。
2. **准备声源和客户端**：有 Mac 时按 `docs/CONFIGURATION.md` 的 `project-device.yml` 路线构建；无 Mac 时，提交本次改动、推送到 GitHub 功能分支，并创建或更新对应 PR，使 `.github/workflows/ios-rollback-build.yml` 的 `pull_request` 事件运行 **iOS realtime subtitles**。该工作流限定了触发路径，PR 必须包含 `apps/RayNeoCompanion/`、`rayneo-*/`、`scripts/` 或工作流文件等匹配改动；仅修改本文档不会触发。当前工作流文件若尚未进入默认分支，不能依赖在 Actions 页面选择功能分支手动运行：GitHub 要求 `workflow_dispatch` 工作流文件先存在于默认分支（[GitHub 文档](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_dispatch)）。若 PR 有合并冲突、仓库 Actions 被禁用或其他策略阻止运行，先排除触发问题，未出现成功运行就不能声称 CI 已验证。运行成功后，在 PR 对应的运行中确认源码检查、分析工具测试、Swift 包测试、模拟器测试和设备构建全部通过，再下载 `TurboIO-realtime-subtitles-v0.3.5-build12-unsigned-ipa` 产物，核对其中 `SHA256SUMS.txt` 的 SHA-256，并记录 PR、Actions 运行号和工作流摘要的 `Source commit`；PR 事件的这个提交通常是 GitHub 测试用合并提交。按自己的既有个人开发者签名流程给 IPA 签名并装到 iPhone；未签名 IPA 不能直接安装，也不要把旧版同名 IPA 当作本次构建。在“字幕 → 设置”配置同一家 ASR、同一模型和语言，打开“同时保存音频”，保存设置；ABBA 轮开始前选“四周”，BAAB 轮开始前选“前方”。把眼镜固定在同一位置，正前方 0° 放目标语音扬声器，侧方约 90° 放干扰语音扬声器；距离和输出音量全程不变，在眼镜位置先测量并记录两声源的声压级。优先由同一播放设备的两个独立输出声道分别驱动两只扬声器，预制目标单独、干扰单独和混合片段，以固定时序和音量播放；保留播放源文件及声道分配。关掉其他主动语音源。背后 180° 可以作为独立的第二组实验，不能混入 90° 的统计。
3. **建立活动会话并切换**：在“字幕 → 实时字幕”点击“开始实时字幕”，等待页面进入“正在听”且“已收音频”增长；记下首次请求的 type 1 方向。运行中打开“字幕设置 → 实时字幕收音方向”，切换“四周/前方”；页面出现“已发送…切换指令”只表示提交。每次切换后至少等待 5 秒，若音频有明显过渡则延长并记录实际等待时间。最新请求出现 `send_failed`、断连、缺口或 type 4 停止时，本区块作废，记录错误；`stale_send_failed` 是旧请求的迟到失败，应结合时间线判断。重试后另起区块。实验结束后用“显示测试与诊断 → 分享脱敏诊断”保存报告，其中应有 type 1/2/10 的方向、提交/失败状态、包数及缺口数；报告不含完整 JSON 和原始 SID。
4. **ABBA/BAAB 播放表**：定义 A=`around`、B=`ahead`；按 ABBA、BAAB 交替，各做 3 轮，共 6 轮、至少 24 个有效区块。每轮从新字幕会话开始，四块保持同一 SID，分别固定配对 **第 1↔2 块、第 3↔4 块**；每对使用完全相同的目标、干扰、混合预录源文件和声源位置，不在看到结果后重新选配对。各对使用不同素材 ID，避免同一语句反复播放；失败时整对重录，原始失败记录仍保留。每个区块的流程是“检查方向，需要时切换 → 统一等待至少 5 秒并预热声源 → 播放区块和三段各自的可辨声学标记 → 目标单独播放 → 干扰单独播放 → 目标与干扰同时播放 → 等待混合段 ASR 定稿并记录”。相邻的 B/B 或 A/A 保持原方向并使用相同等待时间；由于这两块使用不同素材，不能直接把它们的电平差当作同方向噪声基线。三段之间预设相同且足够让 ASR 断句的静音，分别记录单独播放段的转写并从混合段结果中排除；若转写跨段合并而无法分清，整对重录。目标单独、干扰单独用于电平校准，混合片段只用于转写准确率，不能从混合单声道 WAV 反推出两种声源各自的能量。另做四周/前方各一次**新会话启动**，核对 type 1 方向和效果是否与热切换一致；眼镜主动启动则另核对 type 2。
5. **导出与对齐**：停止并等待保存结束，从“字幕 → 历史记录 → 本次会话 → 打包文本与音频 → 分享导出文件”取 ZIP。ZIP 内有 `字幕.txt`、`session.json` 和 `audio-0000.wav` 等；WAV 是 App 将眼镜 Opus 解码后的 **16 kHz、16-bit、单声道 PCM**，按 60 秒或检测到的缺口分片。ZIP **没有**方向切换与 WAV 样本对齐的时间线，字幕日期也不是音频采样时间；不能单凭文件名和播放墙钟时间推算样本位置。须在录得的 WAV 波形/频谱中逐一找到预录声学标记，人工记录每个目标、干扰、混合窗口所属 WAV 和样本起止位置，并保存标记识别依据。测量窗口须在录制前根据源文件内容预定，只按每段固定的头尾过渡长度剔除，不能按录得声音大小或 VAD 重新挑“非静音”区。一个窗口跨分片、标记无法辨认或检测到缺口时，整对区块重录；不补静音、不跨缺口拼接。保留原始 ZIP、播放日志、区块清单和所有排除原因。
6. **逐对计算**：在配对两块的相同源文件、相同长度的预定窗口内，分别算目标单独片段的 `L_target=20log10(RMS_target/32768)` dBFS、干扰单独片段的 `L_interferer=20log10(RMS_interferer/32768)` dBFS；每个区块的方向选择性代理量为 `R=L_target−L_interferer` dB。按事先固定的 1↔2、3↔4 配对，算 `ΔR=R_ahead−R_around` 和前方保真差 `ΔF=L_target,ahead−L_target,around`。混合段参考文本只包含目标声内容；干扰声若被转写，计入插入错误。逐块保存原始定稿并人工按标记与固定静音边界归属，跨区块或无法确定归属的定稿不得硬分，整对重录。中文 CER 在 Unicode NFKC 后去空格/标点、保留繁简和数字，按字符算编辑距离除以参考字数；英文 WER 在 NFKC、小写后将空格和标点视为词界，按词计算。记录替换、删除、插入数；比较 `ΔCER=CER_around−CER_ahead`（或 `ΔWER`），正值才表示前方模式改善。安静环境还要比较前方目标语音本身是否明显受损。RMS 是单独播放时的代理量，若设备有非线性 AGC/降噪，不能把它称为混合场景的真实 SNR。

**离线分析清单**：把六轮各自的 ZIP 放在同一目录，为每轮填写一个 `round_id`、`export_zip`、`sequence` 和按播放顺序排列的四个 `blocks`。`export_zip` 相对清单文件所在目录解析；每个 ZIP 的 `session.json.id` 应是不同的会话 UUID，分析器会检查轮次独立性，但这个 UUID 不是业务协议 SID。下面只演示一轮 ABBA 的格式，样本数字和转写均为占位示例，必须替换为从实际 WAV 声学标记核准的窗口和现场归属的定稿；不要按这个示例的连续 1 秒位置猜测录音时间。

```json
{
  "schema_version": 1,
  "text_metric": "cer",
  "rounds": [
    {
      "round_id": "round-01",
      "export_zip": "round-01.zip",
      "sequence": "ABBA",
      "blocks": [
        {
          "direction": "around", "material_id": "speech-pair-01", "geometry_id": "target-0deg-interferer-90deg",
          "windows": {
            "target": {"wav": "audio-0000.wav", "start_sample": 0, "end_sample": 16000},
            "interferer": {"wav": "audio-0000.wav", "start_sample": 16000, "end_sample": 32000},
            "mixed": {"wav": "audio-0000.wav", "start_sample": 32000, "end_sample": 48000}
          },
          "reference": "请向前看", "recognized": "请向前看"
        },
        {
          "direction": "ahead", "material_id": "speech-pair-01", "geometry_id": "target-0deg-interferer-90deg",
          "windows": {
            "target": {"wav": "audio-0000.wav", "start_sample": 48000, "end_sample": 64000},
            "interferer": {"wav": "audio-0000.wav", "start_sample": 64000, "end_sample": 80000},
            "mixed": {"wav": "audio-0000.wav", "start_sample": 80000, "end_sample": 96000}
          },
          "reference": "请向前看", "recognized": "请向前看"
        },
        {
          "direction": "ahead", "material_id": "speech-pair-02", "geometry_id": "target-0deg-interferer-90deg",
          "windows": {
            "target": {"wav": "audio-0000.wav", "start_sample": 96000, "end_sample": 112000},
            "interferer": {"wav": "audio-0000.wav", "start_sample": 112000, "end_sample": 128000},
            "mixed": {"wav": "audio-0000.wav", "start_sample": 128000, "end_sample": 144000}
          },
          "reference": "今天下午开会", "recognized": "今天下午开会"
        },
        {
          "direction": "around", "material_id": "speech-pair-02", "geometry_id": "target-0deg-interferer-90deg",
          "windows": {
            "target": {"wav": "audio-0000.wav", "start_sample": 144000, "end_sample": 160000},
            "interferer": {"wav": "audio-0000.wav", "start_sample": 160000, "end_sample": 176000},
            "mixed": {"wav": "audio-0000.wav", "start_sample": 176000, "end_sample": 192000}
          },
          "reference": "今天下午开会", "recognized": "今天下午开会"
        }
      ]
    }
  ]
}
```

为其余五轮复制轮次对象，按实际顺序填写 3 轮 ABBA 和 3 轮 BAAB；同一对的 `material_id` 与参考文本须一致，不同有效配对使用不同素材 ID，所有轮次使用同一 `geometry_id`，180° 实验另建清单。可在每个轮次额外填写 `"archive_session_id": "<该轮 session.json.id>"`；分析器会核对它与 ZIP 内容一致，此值不是业务协议 SID。中文选 `cer`，英文选 `wer`。在仓库根目录运行：

```powershell
python -B .\scripts\analyze-pickup-direction.py .\pickup-manifest.json --output .\pickup-result.json
```

也可用 `python -B .\scripts\analyze-pickup-direction.py --example-manifest` 查看脚本当前自带的一轮示例。输出包含逐块 RMS/转写错误数、固定配对的 `delta_r_db`/`delta_f_db`/`delta_text_error_rate`，以及 `summary.full_design_evidence` 和四项量化门槛。汇总统计只纳入四块完整、且 ZIP 与归档会话 ID 均独立的有效轮次；失败旧轮次仍保留在原始 `blocks/pairs` 中，并显示 `included_in_quantification=false`，`raw_valid_blocks/raw_valid_pairs` 另列原始计数。一次示例轮次只能得到预分析结果；六轮各自有效且各有独立 ZIP/会话时才能满足完整实验设计。`summary.device_effect_confirmed` 始终为空，仍需现场核对 type 10、type 4 连续性、声源布置、往返复现和安静语音质量，不能把脚本数值当作眼镜已应用指令的证明。

每个有效区块至少记录：轮次/区块号、固定配对号、A/B 顺序、App/系统/固件版本、眼镜电量、声源角度/距离/声压级、三个源文件的素材 ID、ASR 服务/模型/语言、方向操作与提交时间、等待时长、type 10 发送/异步结果、区块开始/结束时的累计 type 4 包计数与检测到的缺口数、播放时间、三个声学标记及其 WAV 文件和样本区间、预定分析窗口、目标/干扰单独 RMS、混合段原始转写/参考文本/归属判断与替换/删除/插入数。区块边界的累计计数需现场截图或抄录；现有导出文件不保存逐块包数。汇总配对数、中位 `ΔR/ΔF/ΔCER` 及各对的正负号，保存所有原始值与排除原因，不能只报最佳一次。

**现有 iPhone 与眼镜的功能及声学通过条件**：官方包静态证据与 Turbo-IO 协议测试吻合；Turbo-IO 的切换没有最新请求发送失败，区块前后 type 4 计数持续增长，录得标记及预期 PCM 时长相符且有效区块**无检测到的缺口**；至少 24 个有效区块构成 12 对，`ΔR` 中位数 ≥3 dB 且至少 10/12 对为正，`ΔF` 中位数不低于 −3 dB；有干扰的混合片段汇总 CER/WER 在 B 下低于 A，安静目标语音没有明显退化，并能在 A→B→A 往返时复现。3 dB、10/12 等是实验前锁定的工程验收线，非厂商性能承诺；当前缺口计数无法保证发现所有短时丢包。若达到这些条件，可报告“Turbo-IO 方向切换与定向收音效果在该 iPhone/眼镜/固件组合上通过实验验收”，同时标明官方 App 动态抓包是否完成；未做时不能宣称已完成官方动态协议对照，也不能声称取得固件应用 ACK。若声学变化不足或重复性不够，应报告“已发出方向命令，固件效果未确认”，不能仅凭按钮状态、发送成功或音频不断流宣称生效。

字幕与显示共用同一个协议 SID，不开启另一条 AI 语音会话。音频按 SID、设备、接收时间和序号检查；重复、倒序及到达时间倒退的包丢弃。实机表明 `seq` 不是可假定逐包 `+1` 的公开契约，因此严格递增但步长不为 1 只计入脱敏诊断，不再伪造缺口或切 WAV；只有字幕接收队列明确溢出、有效音频到达明显中断或解码失败才记录缺口。libopus 解码到 16kHz mono（库内下混），不把 stereo 的单侧误当整体；不能解码的包停止并提示，而不伪造音频成功。

手机与眼镜固件兼容性仍需本机实测：Android 字段依据不等于所有 iOS/固件组合都相同。显示、转写与录音已通过当前设备实测；永久快捷键恢复、再次双击停止以及长时间锁屏后台仍不能由 CI 代替验收。

## 验证

源码检查；rayneo-protocol 原生字幕/快捷键测试；rayneo-captions 服务请求/格式/日志/WAV 测试；模拟器运行时测试使用假眼镜、假 ASR 与合成音频检查五个可选服务、正确 SID/启动回执、重复/缺口、断连、准备取消、超时、停止后的迟到回调和存储边界；全天智记另测 A1/A2/A3/A4/A8、永久恢复、文本专用归档、断点尾行、跨日/时区、ASR 重连缓冲、镜片隔离和存储失败停机；UI 测试检查实时/全天/历史/设置页。

不使用真实服务 Key、用户音频或 Apple 签名凭据。设备 CI 预期输出未签名 0.3.5 (12) IPA；IPA 文件名与 Actions 产物名包含 `v0.3.5-build12`，仍需用户自己的签名才能安装。真实 A3 持续到达、第二次双击事件、锁屏后台、休眠重连和 30 分钟运行仍必须在目标眼镜上验收，CI 编译不等于这些已通过。
