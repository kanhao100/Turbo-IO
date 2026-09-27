# iOS OTA 参考：默认锁定，不是完整手机成品

这些文件基于本次 FLASH READY 04 研究逻辑，供开发者审阅协议/防误传机制。**已接入 `official-addon` 可选研究构建，普通构建默认不包含，没有预签名 IPA。** 完整合并流程见 [BUILD](../docs/BUILD.md#4-手机实验版从源码到自有签名)。不要自动开启编译宏或删保护来“试试看”。公开 UI 标记为 R3 SOURCE 01，与原先私用 FLASH READY 04 区分。

## 组件

- `ExperimentalOTA`：固定 ZIP 哈希、15 成员快照、原厂缓存只读核对。
- `ExperimentalOTAGuard`：只下载准备阶段的发送隔离。
- `ExperimentalOTAFlash`：人工授权后的设备/Mode 2/文件片段白名单。默认禁用；需要编译开关、指定宿主 marker、有效 transport hook、关闭自动更新、近期真实版本回读及冻结 R3 文件。
- `ExperimentalOTAFeed`：仅监听 localhost 的固定包查询/下载源；正常启动不授权刷写，下载授权和传输授权分离。
- `*Tests.m`：主机逻辑测试，不连接眼镜。
- `../src/patch-ios105-ota-source.mjs`：严格匹配原版 1.0.5（201）App.framework 哈希的离线路由补丁；保留 Dart 字符串长度和非密码学缓存哈希。**不是绕过固件 MD5，也不生成完整安装包。**

宿主接入时需在真实发送回调先调用 `TIOOTAFlashBlockCall` 并保留原厂返回语义；接收事件正规化为 NSData 后调用 `TIOOTAFlashObserveEvent`。`TIOOTARecordTransportHookReady` 只能在实际安装且验收发送保护后调用，不能为了授权而伪造。不要把本参考作为已验证的任意宿主集成配方。

## 已修和未修

04 已允许严格空负载的 type 11 空闲查询，避免保护拒绝开始后又阻断官方恢复；带内容的 type 11 仍拒绝。366 分片测试只验证固定文件与顺序检查，不意味着设备发过 366 片。

**历史缺陷：** 安装后快速重启曾导致 localhost 请求 connectionError；早期状态文件是旧进程快照，不能代表新进程服务可达。公开 SOURCE 01 加入 SO_REUSEADDR（不使用 SO_REUSEPORT）、端口 errno、当前 PID、服务失败也写状态，并补上同端口停止/重启及拒绝第二个活跃监听器的主机测试。**这些修复尚未在手机完成重启压力验收**，不能声称彻底修好；仍需同时核对当前 PID、时间与真实 HTTP 请求。

UI 标题中的 READY 指保护构建，不代表固件经过全面稳定性/救砖验收。参考源码的 `runtimeValidated=false` 和目录审计 `flashAuthorized=false` 是本机工具证据边界；真实传输授权须看当前 `flashGate`，不能改常量伪造成功。

## 不含的材料

不含官方 App 二进制、个人签名/证书/描述文件、账号配置、原始手机日志、远程控制接口或自动点击工具。请使用自己的合法兼容输入和自有签名，并分别验收宿主、权限、连接与研究功能。原厂应用及固件版权归对应权利人。
