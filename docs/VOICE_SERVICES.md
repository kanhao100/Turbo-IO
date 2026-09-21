# 统一语音服务

旧版将阿里云 ASR 和 DeepSeek 的凭据检查、转写连接写死在对话链路，新增 Azure / Deepgram / ElevenLabs 则只用于字幕。结果是“字幕配置成功，但对话仍要求阿里云”。本次将转写配置、凭据、供应商适配和对话轮次分开，共用实际运行配置。

## 使用

进入 **语音**，选择 **实时字幕** 或 **AI 语音对话**。两种模式都从 **语音服务设置** 选择转写服务；工具页和诊断页也打开同一编辑器。

| 模式 | 必要配置 | 处理过程 |
| --- | --- | --- |
| 实时字幕 | 所选转写服务的 Key；Azure 另需 Region，阿里云另需 Host | 眼镜音频 → 所选 ASR → 字幕显示与历史 |
| AI 语音对话 | 同一转写配置 + DeepSeek Key | 眼镜音频 → 所选 ASR → 整句定稿 → DeepSeek → 手机/镜片文字回答 |
| 已保存录音的文件转写 | 已保存的阿里云 Host + Key | 单独确认上传该文件，仍使用原有文件转写协议；暂未扩展到另外三家 |

只配置 Azure、Deepgram 或 ElevenLabs 的用户，无须为了启动 AI 对话另配阿里云。没有 DeepSeek Key 时仍能使用字幕；对话页明确列出缺少的 DeepSeek 配置。文件转写的供应商限制单独标明，不参与实时字幕/对话的启动检查。

| 转写服务 | 模型 / 输入 | 凭据范围 |
| --- | --- | --- |
| Azure Speech | 原有 Speech SDK，PCM16/16 kHz/mono | Azure Region + Key，区域不含 `/` 或 URL |
| Deepgram | Nova-3，PCM 二进制 WebSocket | 独立 API Key，固定官方地址 |
| ElevenLabs | Scribe v2 Realtime，Base64 PCM WebSocket，VAD 自动定稿 | 独立 API Key，固定官方地址 |
| 阿里云流式 ASR | qwen-audio-3.0-asr-flash-streaming，DashScope run-task + PCM | 用户的 aliyuncs.com Host + Key |

保存设置只保存设置，不自动开启待命、采音或上传。启动仍需要唯一已认证的眼镜、空闲语音通道和用户确认，再等待眼镜真实唤醒。运行中锁定服务配置和模式切换；先停止再换模式。重启不恢复旧版保存 Key 时产生的自动待命标志。设备连接维护独立保留。

## 代码边界

- `SpeechConfiguration`：共享的服务、区域/Host、语言；字幕时长/录音同意不进入共享 ASR 配置。
- `SpeechSettingsStore`：唯一生产配置与凭据入口，分别计算字幕和对话所缺的条件。`CompanionStore` 创建一个实例，传给对话、字幕和各入口。
- `CaptionASRFactory` / `CaptionASRProvider`：沿用原内部名字，但已是两种实时模式的共享适配器。阿里云由一个 `AliyunSpeechSession` 实现；Azure 使用 SDK，Deepgram/ElevenLabs 使用 WebSocket。
- `VoiceRecognitionPort`：将选中的 ASR 注入 `CloudVoicePipeline`。设备 App 没有隐式回退到阿里云的分支。独立诊断宿主保留旧阿里云配置兼容，但复用同一个阿里云传输实现。
- `SpeechTurnAssembler`：组装语音轮次。片段定稿与整句结束分开；Deepgram 累积 `is_final` 片段，等 `speech_final` 后才调用模型。Azure recognized、ElevenLabs committed_transcript、阿里云 sentence_end 则结束当前句。空事件不打断，未定稿文字不作为最终模型输入。
- `CloudVoicePipeline`：统一的 DeepSeek 流式响应、对话历史和取消逻辑。有效新句取消旧回答；会话 ID 和回答 ID 拦截停止/替换后的旧回调。
- `StandbyVoiceSession`：眼镜采音、等待识别、生成、显示、退出的状态机。转写供应商不决定眼镜控制协议。

实时字幕沿用历史/分段 WAV/静音退出策略；AI 对话沿用 120 秒会话保护和回答发完后 10 秒无新句退出。二者不共用这些不同的会话策略，也不能同时占用眼镜语音通道。目前没有 TTS，回复显示为文字。

## 升级与凭据

首次升级优先迁移已保存的字幕供应商；没有字幕配置但有旧阿里云 Host 时，选择阿里云。新设置存储键为 `companion.speech.configuration.v2`。保留旧字幕目录和本次会话偏好，录音同意仍不恢复。

Azure 仍使用 `io.turboio.companion.azure-speech.v1` + Region；Deepgram/ElevenLabs 仍用之前独立的 service。阿里云保留 `RayNeo.CloudASR.https.<host>` + `user-api-key`，DeepSeek 保留原固定 service 和 account。不复制或导出原密钥，不在日志、URL、配置文件中写 Key。

已移除旧“任意模型地址”的未接入草稿编辑器和废弃会话界面（代码可从 Git 历史恢复）；原草稿数据未删除，也不会被悄悄视为可用的 DeepSeek 或 ASR 凭据。

## 验证

CI 执行纯策略/协议测试，以及模拟器的 `CaptionBoundaryTests`、`CaptionSocketTests`、`UnifiedSpeechTests`、`VoicePipelineIntegrationTests`、`CloudASRConfigurationTests`。新增回归检查覆盖：

- 四家各自只有自己的 ASR Key 时的模式依赖，另加模型 Key 后对话配置就绪；不要求别家密钥。
- 旧配置迁移、跨服务不混用密钥、配置保存不启动、运行中禁止改配置。
- 选中适配器 → PCM → 分段定稿 → 整句结束 → 模拟 DeepSeek SSE → 眼镜会话状态完成的完整链路。
- 空句、撤回、连续片段、插话打断、旧会话回调、停止和恢复待命。
- 阿里云 task ID、sentence ID、心跳和重复定稿过滤。

测试使用假识别器、URLProtocol 和合成文本，不上传用户音频、不使用真实服务 Key。未签名模拟器的 Keychain 往返测试可能按明确的系统错误跳过。设备编译成功后上传 build 4 的未签名 IPA；Windows 用户按原方式用 Sideloadly 签名安装。

仍需在签名 iPhone 和眼镜上分别验证四家真实账户、网络时延、镜片显示、锁屏/后台与插话效果；编译通过不代表这些已验收。

接口依据：[阿里云客户端事件](https://www.alibabacloud.com/help/en/model-studio/fun-asr-client-events)、[阿里云服务端事件](https://www.alibabacloud.com/help/en/model-studio/fun-asr-server-events)、[Deepgram 定稿与端点](https://developers.deepgram.com/docs/understand-endpointing-interim-results)、[ElevenLabs Realtime](https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime)。
