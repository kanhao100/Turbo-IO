# TLC1 · 全天智记与扩展应用共存

2026-09-30 · **高风险实验版，非开发者请保留官方固件，不要刷。**

**[下载 TLC1 完整 OTA、SHA256SUMS 和审计报告](https://github.com/Turbo1123/Turbo-IO/releases/tag/firmware-strix-1.0.4.12-tlc1)** · [原厂归档与恢复限制](../stock/README.md) · [TGR1 基线](../../../watch-remote/FIRMWARE_RELEASE.md)

## 本次解决什么

此前打开官方「全天智记」，导航、音乐、读书、番茄、滴滴和小应用可能从眼镜菜单点不进去。它们共用的原厂空闲判断把「智记开关开启」直接当作忙碌，即使当前没有需要独占前台的页面。

TLC1 仅对这六个扩展应用的进入/运行判断放开**后台智记开关这一条件**，不关闭智记，不改录音内容，不接管音频，不绕过前台占用或助手活动检查。相对 TGR1 只增加 **192 字节 AP**，无新增常驻内存、堆分配、线程、定时器或设置写入。

**实机反馈（2026-09-30）：** 用户刷入本包后确认「打开全天智记也不影响打开其他 App」。随后音乐画面未同步的日志显示：眼镜请求已到手机，但手机仍保留 `OTA stage=2`，未发送音乐包；在说明退出重开手机 App 的收尾方法后，用户再次确认正常。共存入口及这轮音乐显示获得反馈确认；持续智记实际采集、音频资源长期共存、反复抬头亮屏、功耗及长期稳定性尚未完成验收。不能解读成所有音频任务都能并行。

## 修改范围与继承问题

- 基于精确 TGR1，不以 TBL1 为底包，**不包含手动锁定/自动平滑亮度补丁**。
- 原厂 `LauncherAPI::isBussinessIdle`（`0x106d334c`）保持不变；新增重定位副本 `tlc_display_idle`，只略过 `0x106d336e` 的 `isLifeLogEnabled` 拒绝分支。
- 仅重定向六个扩展的 `home` / `safe_home` 末尾分支：导航、音乐、读书、番茄、滴滴、小应用。菜单、手机 OPEN 及运行中所有权检查沿用同一判断。
- launcher 前台、折叠、页面所有权、配对、渲染 idle 和助手活动检查保留；原厂函数其他快捷返回和缺失服务回退行为也原样继承。这不是新的全面资源仲裁器。
- 原厂 AlwaysOn、助手、录音、亮度和抬头逻辑不改；诊断仍走严格原厂 idle；Turbo Display 测试页本来不使用此判断，本次不改。
- **继承 TGR1 的已知 Watch 全局翻页问题**，未宣称本版解决。真正前台冲突仍可能静默拒绝，未增加错误 toast。

为什么只改 application：目标逻辑都在 AP；保留其他核、资源和升级组件，减少变量并便于审计。**只改 AP 内容不等于安装时只写 AP，更不保证不变砖。**

## 固定产物

| 项目 | 值 |
| --- | --- |
| 构建 / 固定 ABI | TLC1-01 / Strix OS 1.0.4.12 |
| ZIP 大小 | 9,322,471 字节 |
| ZIP SHA-256 | `5e2b85acb9cd25e0b245838e665e39d291eae4aae640308f126718eb3185e519` |
| AP 大小 | 9,593,736 字节 |
| AP SHA-256 | `bb3fee35ac7ff7f5b76295235323249634cdaf582069972d7b89cff4020f855d` |
| AP MD5 | `9e81aa35fc41efd5cd6089bfd8f1d987` |
| 相对 TGR1 增量 / 当前保守预算余量 | 192 / 6,264 字节（预算 9,600,000，不是物理容量声明） |

上传**实刷原样 ZIP**，不重压缩、不替换内容。历史文件名 `CANDIDATE-NOT-APPROVED` 保留，不表示稳定性已获批准。14 个负载中仅 `nuttx_ap.bin` 改变，清单仅更新 AP Size/MD5，其他 13 个负载与原厂逐字节一致。

发布审计见 [firmware-audit.json](firmware-audit.json)，ARM 模拟测试见 [coexist-arm.json](coexist-arm.json)。后者的 `hardwareValidated: false` 表示该测试本身是模拟器测试；真人反馈单独记录在本文和发布审计中，不冒充自动硬件验证。

## 下载后怎么用：先确认配套安装器

**本次发布源码、固件与 iOS OTA 接入参考，不发布预签名 IPA，也没有新的 TLC1 Android APK。** 旧 GUARD-07 APK 固定 TAP1-TEST-01，旧 TGR1/TBL1/TAP1 门禁不能拿来刷本包；不能改名、替换缓存、跳过哈希或删保护来强刷。

只有已自行完成配套 iOS 1.0.5（201）集成、签名并审核门禁的开发者，才能进行下面流程；未具备条件请止步离线研究。参考代码见 [ios-reference](ios-reference/README.md)，不是一键打包安装器。

1. 下载本 Release ZIP、SHA256SUMS，在同目录执行 `shasum -a 256 -c SHA256SUMS`。有原厂解压基线时，再运行下节的完整审计。
2. 保持手机解锁、眼镜电量至少 50%、回到首页，结束**包括全天智记**在内的所有任务。共存是升级后的功能，不表示刷写时可继续录音。
3. 配套页提示「内置 TLC1 候选校验通过」后，开启「15 分钟只下载验收」，回官方固件页检查并下载；到「软件就绪」先停下。
4. 「核对官方解压目录」必须通过：全部 15 项、AP Size/MD5/SHA-256 与固定候选一致。下载/校验通过不是刷写授权。
5. 同设备官方版本读取需在 120 秒内；点「允许一次 TLC1 共存试刷」，输入 `TLC1`。确认授权为 1 后，回官方页只点一次「开始安装」。超时重新正常检查，不改计时器或伪造状态。
6. 完整传输/安装期间不重启、强停、断电、切换连接或重复发送。异常先保存脱敏日志，不能盲目重试或强制解除保护。
7. **必做收尾：等眼镜自然重启回首页，确认升级确实完成、没有仍在传输/安装后，彻底退出并重新打开手机雷鸟 App，结束本次进程内升级保护。** 本版保护不会仅因眼镜回首页自动清除；残留 `OTA stage=2` 会阻止音乐等文件同步，出现“能打开页面但没有内容”。只读回查确认状态后再收尾；iOS 流程不能照搬 Android 的 GUARD-07 按钮。**升级未结束或状态不明时，禁止强停或重开 App。**
8. 先测实体按键、息屏/抬头、原厂功能，再开启全天智记测试扩展，并确认实际记录仍持续。异常停止实验，保留日志。

掉电、中断、错包或 AP 缺陷可能导致无法启动、失去蓝牙/OTA、数据丢失或设备损坏。原厂回滚不保证救砖，当前原厂归档也不是同版本一键恢复工具。项目按现状提供；在适用法律允许范围内，作者不承担试验损失、恢复或售后义务。

## 离线审计与复现

从仓库根目录运行；无需连接设备，不要使用 `python -O`（安全断言不得禁用）。

```sh
python3 firmware-research/strix-1.0.4.12/lifelog-coexist/audit_firmware.py \
  /absolute/TLC1.zip /absolute/stock-1.0.4.12
```

原厂输入来自[原厂 Release](../stock/README.md)，TGR1 输入来自[此前的 TGR1 Release](../../../watch-remote/FIRMWARE_RELEASE.md)。脚本只接受固定哈希，不能套用其他固件。依赖 Python、Capstone 5.0.6、Unicorn 2.1.4，以及带 ARM target 的 LLVM（clang、ld.lld、llvm-nm、llvm-objcopy）。

```sh
python3 -m venv .venv-tlc1
.venv-tlc1/bin/pip install -r firmware-research/strix-1.0.4.12/requirements.txt
.venv-tlc1/bin/python firmware-research/strix-1.0.4.12/lifelog-coexist/build.py \
  --tgr1 /absolute/TGR1.zip --stock /absolute/stock-1.0.4.12 \
  --llvm-bin /absolute/llvm/bin --out /absolute/new-tlc1-output
.venv-tlc1/bin/python firmware-research/strix-1.0.4.12/lifelog-coexist/test_arm.py \
  /absolute/new-tlc1-output --tgr1 /absolute/TGR1.zip --stock /absolute/stock-1.0.4.12
```

输出目录必须不存在，不覆盖已有成果。公开脚本在本机重新构建的 AP 和 ZIP 均与实刷包逐字节相同；工具链差异若导致 AP 哈希不同，脚本停止。旧 ELF 只用于提取固定基线的六处函数/分支映射；公开版使用明示映射、精确输入哈希和指令复核，不依赖私人工程。

480 组差分执行覆盖 LifeLog/充电/折叠/助手/页面/服务组合；另测六个真实扩展函数、缺失监控、ABI 寄存器、栈恢复和非栈写保护。原厂 preference 路径执行，服务/状态为模型；不是硬件长稳测试。历史 TGR1 Watch ARM 98 项回归也通过，但不等于实体输入验收。

macOS 可单独测试手机 ZIP、目录、传输、保护及本机 HTTP 来源：

```sh
python3 firmware-research/strix-1.0.4.12/lifelog-coexist/test_phone.py \
  --tlc1 /absolute/TLC1.zip --tgr1 /absolute/TGR1.zip --stock /absolute/stock-1.0.4.12
```

只用本机临时目录和 loopback，不读写手机或眼镜，不自动安装/刷写。

## 公开范围、隐私与许可

公开本次共存修改构建器、测试、固定候选 OTA 参考、脱敏审计和原样固件；不包含用户 Cookie、API Key、Apple 账号、签名证书/私钥、描述文件或私用 App。也不新增发布微信读书网页正文适配。原厂固件/资源仍归各自权利人，原创部分沿用仓库 PolyForm Noncommercial 1.0.0；不是取得原厂全部源码，也不是无限制商用授权。
