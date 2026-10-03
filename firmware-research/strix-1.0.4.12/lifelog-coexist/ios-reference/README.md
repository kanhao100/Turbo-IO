# TLC1 · iOS OTA 接入参考

来自本次 iOS 1.0.5（201）TLC1 配套源码的定向导出。只含固定候选校验、目录核对、Mode 2 单次授权、loopback 来源和 UI；**不是完整插件快照，不直接改变仓库默认构建，也不是安装器**。不含登录态、网页正文适配或签名配置。

- `ExperimentalOTA.m` 固定 ZIP/15 个成员哈希与大小，拒绝旧包、错误清单和路径。不能仅改一个总 SHA 就当作新候选。
- `ExperimentalOTAFlash.m` 保留同设备、120 秒版本读取、冻结文件、900 秒授权、清单/分片逐项检查；未授权不得传输。`ExperimentalOTAGuard.m` 保留只下载隔离。
- `ExperimentalOTAFeed.m` 仅在 loopback 提供固定元数据与 ZIP，15 分钟下载期限不等于刷写授权；官方 1.0.5 的固定宿主地址不可跨版本复用。
- `ExperimentalOTAUI.m` 导入、校验、只下载、单次文字确认和官方页启动仍分开；历史 UI 中“尚未验证/PRIVATE”是构建时提示，最新验收以[发布说明](../README.md)为准。

接入现有、已审核的 iOS 插件时须保留：

1. 原有传输 hook 在官方发送前调用 `TIOOTABlockPreparationCall` / `TIOOTAFlashBlockCall`，不能旁路；调用 `TIOOTARecordTransportHookReady` 也不能代替实际 hook。
2. 官方事件输入 `TIOOTAFlashObserveEvent`，确保版本读取与设备关联；原有来源安装/状态记录逻辑应完整接入。
3. 研究页使用 `TIOExperimentalOTAController()`；固件资源名 `TurboWeReadCandidate.zip` 是历史资源名，内容必须是本 Release 的 TLC1。Info.plist routing 必须精确为 `ios105-tlc1-loopback-flash-gated`。
4. 编译宏 `TIO_OTA_FLASH_ENABLED`、`TIO_DISPLAY_FLASH` 及业务宏必须和宿主集成一致。仅打开宏、添加页面或改 Info.plist 不足以完成集成。
5. UIKit 页面依赖项目的 `ResearchUI`；开启相应业务时依赖 Music/Reader/App/Focus/Ride/TD、ImageUpload/DisplayPhone/TNV transport 的 scoped-call 判定。缺少模块请先完成依赖集成，不能用“总返回 true”的桩函数跳过保护。
6. 抽取版只将未启用的业务头文件 import 放入原有业务宏条件内，未更改运行门禁。运行 `../test_phone.py` 可做五套离线测试；手机 arm64 完整集成仍需单独编译、签名和只下载验收。

本次私用配套手机经过 arm64 编译和签名检查、实际安装与下载验收；公开抽取版五套 macOS 离线测试通过，**不能当作公开完整 App 已重新装机验收**。不提供可直接重签的私用 IPA，不自动开启实验来源，不自动授权或刷写。
