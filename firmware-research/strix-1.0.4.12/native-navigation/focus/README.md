# FOCUS-04 · 四项菜单与原生番茄时钟（TFP1）

**2026-09-25 · 实验固件，非开发者请勿刷。** 此研究用于探索 BES2800 application 内的原生应用与 UI 能力，不是日常成品固件。可能无法启动、丢失数据或失去 OTA；即使保留原厂 ZIP，也不保证能救砖。断电、意外中断、错误版本和运行时缺陷均有风险。原厂回滚机制不是安全承诺。

[下载精确实测 ZIP、清单与 SHA256](https://github.com/Turbo1123/Turbo-IO/releases/tag/firmware-strix-1.0.4.12-tfp1-focus04) · [配套 iOS UI / 构建 / 签名](../../../../official-addon/focus-edition/README.md)

## 这次更新

1. **菜单重构**：12 个入口，四项同屏、清晰选中框，左上角时间和电量；进入详情隐藏菜单及原滚动指示器，返回恢复原选择。
2. **遗留交互修复**：音乐旋钮累计/去抖降低轻触误切歌，封面下文字内移；阅读长按先回书架、再退出，并防止迟到正文重新打开阅读页；番茄页倒计时与状态分区，避免重叠。
3. **第十二项原生番茄时钟**：手机与眼镜双向控制，眼镜短按暂停/继续、长按停止并退出；短暂查看后释放亮屏，计时不因页面隐藏停止，到时在空闲条件下提醒。不保证系统深度休眠、关机或蓝牙中断期间所有行为与前台完全一致，不能当作关键提醒设备。
4. **配套插件新 UI**：深色暖光首页、眼镜动效、音乐/阅读/导航/番茄入口与整理后的设置；只重构 Turbo IO 插件，不重做官方 App 页面。

保留 Turbo Display 开发测试、原生导航、音乐、书架与本地正文阅读、诊断功能。为节省空间，ANIM60 素材只保留一帧；本包不是之前的 60 帧动图演示包。微信读书网页正文适配不在公开版内，书架 API 不提供全文，需自行导入有权使用的 TXT/EPUB。

## 仅修改 application 的含义

基线固定为 **Strix OS 1.0.4.12**。14 个固件负载中仅 `nuttx_ap.bin` 改变；其他 13 个负载逐字节不变。`OtaFileInfo.json` 只更新 AP 的 Size / MD5，保留目标地址及烧写字段。ZIP 自身重新生成，发布其新 SHA-256。

这样做是把改动限制在应用/UI 层，避免同时改变引导、Recovery 和蓝牙核；**降低变量，不等于消除风险，也不等于 OTA 只写 AP**。仍沿用原厂整包下载、校验、解压、传输与安装链路，不提供强制写裸 AP 的命令。

| 项目 | 本次精确发布值 |
| --- | --- |
| AP 大小 | 9,558,216 字节；硬门限 9,600,000 字节（十进制） |
| AP SHA-256 | `40b08299d66b08a909c9167400f2f660b17904d6b20026477ac470e860942a24` |
| AP MD5 | `2d5c14d7c348d01c333f3561423cb47e` |
| ZIP 大小 | 9,300,112 字节 |
| ZIP SHA-256 | `ad5054e3d7bda90e94d293bea882bd8dd5a125bcc8f42c13a59b2e149313c9e3` |
| 配套宿主 | 雷鸟 AI iOS 1.0.5（201） |

本包余量仅 41,784 字节；不要把其他实验模块随意叠加。所有原创改动沿用仓库非商业许可，原厂负载版权归原权利人。本包不含手机 Key、Cookie 或开发者签名。

## 下载后先离线校验

从仓库根目录运行（替换文件路径）：

```sh
python3 firmware-research/strix-1.0.4.12/native-navigation/focus/verify.py /absolute/StrixOS-1.0.4.12-TurboFocus-TFP1-FOCUS04-EXPERIMENTAL.zip
python3 firmware-research/strix-1.0.4.12/native-navigation/focus/test-verify.py /absolute/StrixOS-1.0.4.12-TurboFocus-TFP1-FOCUS04-EXPERIMENTAL.zip
```

检查精确 ZIP、15 个成员、AP、其他 13 个负载、清单 Size/MD5 和不变烧写字段。任一不符立即停止，不要修改哈希门禁来放行。

## 从公开源码复现 AP

需要自己合法准备固定基线原厂 OTA ZIP，Python 虚拟环境及 `unicorn`、`capstone`，macOS Xcode 命令行工具；编译器固定 OHOS clang 15.0.4（脚本检查完整版本），可使用相应 DevEco SDK LLVM。不下载设备数据、不调用刷写接口。

```sh
python3 -m venv /absolute/firmware-venv
/absolute/firmware-venv/bin/pip install unicorn capstone
/absolute/firmware-venv/bin/python firmware-research/strix-1.0.4.12/native-navigation/focus/build.py \
  --stock /absolute/StrixOS-1.0.4.12-ORIGINAL.zip \
  --out /absolute/new-focus-build \
  --llvm /absolute/openharmony/native/llvm/bin
```

输出目录必须不存在。脚本重建 AP、执行 ARM 模拟和主机内存检查，再比对发布 AP 哈希。ZIP 时间戳可能不同，因此重建 ZIP 不会通过手机的“精确发布 ZIP”门禁；实测安装使用 Release 原样 ZIP，不改门禁。

## 配套手机端及升级顺序

先按[配套手机教程](../../../../official-addon/focus-edition/README.md)自行构建、签名和安装；确认 FOCUS-04 与内置候选校验通过。不要把旧 TWR1/TMU1 门禁与新包混用。

1. 保存原厂基线及现有数据，关闭官方自动更新；确认版本、连接和充足电量（至少 50%），结束录音、导航、音乐、阅读、计时及对话。
2. 诊断 → FOCUS-04 → 开启 15 分钟**只下载验收**；回官方更新页下载。此时未授权眼镜刷写。
3. 回诊断页核对官方解压目录，确保 15 成员均一致。停止于任何错误，不重复碰运气。
4. 充分理解风险后，重新查询设备版本，按门禁提示输入 `TFP1` 授权一次，再由自己手动点官方开始安装。程序不会因为打开页面就自动刷。
5. 传输/安装期间不退出 App、不切换连接、不操作其他任务；等待眼镜完成并重启，再验收菜单和各页面。出错先保留日志，不循环重刷。

## 内存与验收边界

四项菜单控制器 48,256 字节，另有 12 个 LVGL 对象，不能把该数字当成总 RAM。使用固定图标缓冲、单实例、退出/销毁清理、绘制忙时延后释放；未收到删除回调注册成功时不挂接子资源。保留原厂选择与启动索引，未把固定数组任意扩长。

公开构建包含菜单 120 场景、20 次创建/销毁及 20 次快速销毁、分配失败、绘制忙、父页面删除、阅读返回/迟到包、音乐输入、导航、诊断、显示和计时回归；这些是模拟原厂接口的测试，不能替代真实硬件。发布 AP 与 2026-09-25 实刷 AP 一致，用户确认“完美”。没有完成多设备、长时续航、所有休眠/到时提醒条件的完整验收。
