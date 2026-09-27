# 构建、校验与自行签名

先阅读 [风险与适配范围](README.md)。以下流程**不会操作眼镜或自动授权刷写**。在仓库根目录执行；所有 `YOUR_*` / `/absolute/...` 都要换成自己的值。无需任何作者私人工程。

## 1. 取得匹配文件并只读校验

```sh
git clone https://github.com/Turbo1123/Turbo-IO.git
cd Turbo-IO
mkdir -p firmware-research/strix-1.0.4.12/native-navigation/work/downloads
gh release download firmware-strix-1.0.4.12-tnv1 --repo Turbo1123/Turbo-IO \
  --dir firmware-research/strix-1.0.4.12/native-navigation/work/downloads
python3 firmware-research/strix-1.0.4.12/native-navigation/verify.py \
  firmware-research/strix-1.0.4.12/native-navigation/work/downloads/StrixOS-1.0.4.12-TurboNavigation-TNV1-EXPERIMENTAL.zip
```

没有 `gh` 也可在 Release 手动下载同名附件。验证精确 ZIP SHA-256、15个成员、AP 哈希、其余13项原厂哈希、清单 Size/MD5 和清单完整哈希。任一不符停止，不改校验常量来绕过。

## 2. 构建配套 iOS 扩展（通常只需本节，无需重编固件）

macOS + Xcode（本次使用 iPhoneOS27 SDK，最低 iOS16）、Node.js；按 [iOS扩展文档](../../../official-addon/README.md) 准备合法兼容、未加密、thin arm64 的官方 **1.0.5（201）`Runner.app`**，自己的开发证书、匹配 Bundle ID `com.rayneo.venus.pub` 和目标设备的 provisioning profile。输入不兼容时停止；本工具不解密、不改签名权限来冒充官方推送。

```sh
node official-addon/setup-amap.mjs --accept-sdk-terms
TIO_NATIVE_NAV=1 TIO_OTA_RESEARCH_ENABLED=1 TIO_AMAP_ENABLED=1 \
  bash official-addon/build.sh embedded com.rayneo.venus.pub
node --test official-addon/package.test.mjs
```

产物 `official-addon/build/native-navigation/TurboIOPrivateAddon.dylib`。高德依赖由已有脚本获取并校验，不含 Key；已有 SDK 可显式指定 `TIO_AMAP_SDK_ROOT=/absolute/amap-sdk`。**不设置 TIO_NATIVE_NAV 时仍走原有构建，不会默认装入试刷入口。**

自行签名/合并（输出必须是不存在的新目录）：

```sh
node official-addon/package.mjs \
  --app /absolute/Runner.app \
  --addon /absolute/Turbo-IO/official-addon/build/native-navigation/TurboIOPrivateAddon.dylib \
  --profile /absolute/YOUR_PROFILE.mobileprovision \
  --identity YOUR_CERTIFICATE_SHA1 \
  --device YOUR_DEVICE_UDID \
  --bundle com.rayneo.venus.pub \
  --amap-sdk-root /absolute/Turbo-IO/official-addon/build/amap-sdk \
  --experimental-ota TNV1 \
  --firmware /absolute/StrixOS-1.0.4.12-TurboNavigation-TNV1-EXPERIMENTAL.zip \
  --out /absolute/NEW_LOCAL_OUTPUT
```

该命令严格配对 TNV1 编译符号、原版宿主哈希及实测 ZIP，将精确 ZIP 作为 `TurboNavigationCandidate.zip` 内置。仅替换已定位的官方升级查询 URL 为**手机本机回环**来源，仍使用官方手机解包、校验和蓝牙 OTA 流程；不会自行调用升级。未知包、R3/TNV1 混用、带私有配置的输入、证书/设备不匹配均拒绝。可用 `--product YOUR_IPHONE_MODEL_IDENTIFIER` 为宿主设备白名单显式加入自己的机型，不是设备 UDID。

使用 Xcode Devices 或自己的开发者安装工具安装本地输出。不提供签名包；部分个人签名可能无法保留官方推送/登录权限，具体以自己的 provisioning profile 为准。首次打开查看「TurboIO → 诊断」出现 **TNV1 导航固件 · 默认锁定**，导航页出现 **开启眼镜原生导航**；不要立刻授权升级。

## 3. 固件源码复现（可选的开发研究）

原始 AP 不是我们的源码；本目录包含原创增量 C 模块、版本锁定的补丁/链接器、符号地址和测试。无需 BES 私有 SDK。**实测编译器为 OHOS clang 15.0.4，LLVM 提交 `39bec79f56c3b5a629e4bacac1dc022e1da552d0`**（DevEco Studio 所带 OpenHarmony native LLVM）。Apple clang21 / Homebrew clang22 产生不同 AP；不可当成此实测版。脚本显式要求 `--llvm`，不依赖机器上同名 `clang` 的偶然顺序；需自行准备这一工具链，仓库不打包工具链。

```sh
gh release download firmware-strix-1.0.4.12-turbophoto-r3 --repo Turbo1123/Turbo-IO \
  --pattern StrixOS-1.0.4.12-ORIGINAL-rollback.zip \
  --dir firmware-research/strix-1.0.4.12/native-navigation/work/downloads
python3 -m venv firmware-research/strix-1.0.4.12/native-navigation/.venv
firmware-research/strix-1.0.4.12/native-navigation/.venv/bin/pip install \
  -r firmware-research/strix-1.0.4.12/requirements.txt
firmware-research/strix-1.0.4.12/native-navigation/.venv/bin/python \
  firmware-research/strix-1.0.4.12/native-navigation/build.py \
  --llvm /Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native/llvm/bin \
  --stock firmware-research/strix-1.0.4.12/native-navigation/work/downloads/StrixOS-1.0.4.12-ORIGINAL-rollback.zip \
  --out firmware-research/strix-1.0.4.12/native-navigation/work/rebuild-01
```

脚本只创建新目录，验证基线，编译，运行九菜单/导航/TDP1 ARM模拟及独立 AP-only 审计；最后要求 AP 与实测版相同。重复运行换新的 `--out`。所有新增文件放在忽略的 `work/`。保留原始生成报告中的 `readyToFlash:false`：它只代表一次离线构建，不能自动授予真机刷写资格。

新 ZIP 因文件时间戳可以不同；**15个成员必须相同**。这不改变手机的整包锁定；手机操作请用 Release 原始 ZIP。若修改源码、参数或工具链得到新 AP，必须重新做完整审查和设备验收，不能沿用本次成功结论。

## 4. 离线测试

```sh
bash official-addon/test.sh
node --test official-addon/package.test.mjs
bash firmware-research/strix-1.0.4.12/native-navigation/test.sh \
  /absolute/StrixOS-1.0.4.12-TurboNavigation-TNV1-EXPERIMENTAL.zip \
  /absolute/rebuild-01/candidate/payload \
  /absolute/rebuild-01/firmware-inspection/StrixOS-1.0.4.12
```

包括手机协议/异步回执、显示差分与限流、文件任务关联、SHA/目录保护、OTA门禁、本机下载来源、导航随机坏包/有效场景/内存生命周期。测试会在本机开临时回环端口，不触碰眼镜。生成的 `navigation-trace.json` 为合成数据，可再给 `test_service_arm.py --phone-trace` 进行跨端协议回放。
