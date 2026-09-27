# 先离线研究：核对、测试、构建

**下列命令不会连接眼镜、安装手机 App 或发起 OTA。新生成的包不是自动安全可刷。** 先读 [SAFETY](SAFETY.md)。推荐在临时开发目录操作，保留原始下载件；脚本拒绝覆盖已有输出。

## 环境

- Python 3.11+、Node.js 20+，Python 依赖见 `requirements.txt`。
- 主机 C 编译器；ARM 交叉工具 `clang`、`ld.lld`、`llvm-objcopy`、`llvm-nm` 放入 PATH。必须是支持 `arm-none-eabi` 的 LLVM 工具链，不要误用只能链接 macOS 的 Apple ld。
- 可用独立虚拟环境或 `uv run --with-requirements requirements.txt`；不要往系统 Python 强行安装依赖。
- macOS 上 iOS 参考逻辑测试需 Xcode Command Line Tools（Foundation）。

以下从仓库 `firmware-research/strix-1.0.4.12` 目录执行。

## 1. 仅下载并校验参考附件

阅读实验 Release 警告后，把两个 ZIP 与 SHA256SUMS 保存到 `work/downloads/`，不要解压到系统目录。校验 SHA-256：

```sh
shasum -a 256 work/downloads/*.zip
```

必须逐个和 Release/本文档的固定值比对，不是只看命令执行成功。基线 ZIP：`22c1d844a7b30715f7f2406032042a2caa74a4442e2bd9437c1ac67a6e3990a3`；R3 ZIP：`658352deed03c27102ad4151b104389d7f19a7690c505486d188261a483a32ff`。

```sh
python3 src/prepare-baseline.py work/downloads/StrixOS-1.0.4.12-ORIGINAL-rollback.zip
python3 src/preflight-menu8-ota.py work/downloads/StrixOS-1.0.4.12-TurboPhoto-menu8-EXPERIMENTAL-UNFLASHED.zip
python3 src/test-preflight-menu8-ota.py
```

第一步只安全提取固定原厂 ZIP 到新的 `work/baseline/`，校验成员，再附带公开的符号与哈希元数据。第二步验证 R3 原样包、AP 修改范围和另 13 项不变；第三步跑负面样例。**PASS 不证明你的设备能启动。**

## 2. 主机控制器与渲染测试

```sh
mkdir -p work/tests
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -g src/menu8-sidecar.c src/menu8-sidecar.test.c -o work/tests/controller
work/tests/controller
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -g src/menu8-renderer.c src/menu8-renderer.test.c -o work/tests/renderer
work/tests/renderer
```

这两项使用主机和 mock，不是真正的 LVGL、PNG 解码器或完整 AP 启动模拟。

## 3. 构建新的离线候选

准备好 LLVM PATH 后：

```sh
uv run --no-project --with-requirements requirements.txt python src/build-menu8-experiment.py work/candidate-01
uv run --no-project --with-requirements requirements.txt python src/test-menu8-arm.py work/candidate-01
```

构建器保留严格的原 AP 和图片哈希：先复现小实验，而不是接受任意文件或任意版本。生成报告包含 patch 白名单、目标符号、跳板、AP 增长与成员差异；ARM 模拟仍 mock 原生服务。**公开化只调整输入路径/元数据组织，不放松原 AP、图片、成员或容量检查。**

默认图片输入是 `assets/turbo-photo-firmware.png`，它保留实测固件的 88×98 原字节；`assets/turbo-photo.png` 是作者的彩色展示原图，不参与构建，不能拿它替换固定哈希输入。

工具链变化可能导致新 AP 不与 R3 相同，ZIP 重建也包含时间戳变化。先比较 `payload/nuttx_ap.bin` 和指定 R3 AP 的 SHA-256，逐成员审核；不要直接拿新候选去刷。实验固件文件名保留 UNFLASHED，生成报告保持 runtimeValidated=false。

### 精确复建记录

发布前从隔离的公开源码目录复建，使用 DevEco SDK 自带的 **OHOS clang 15.0.4 / llvm-project 39bec79f56c3b5a629e4bacac1dc022e1da552d0** 及同目录 `ld.lld`、`llvm-objcopy`、`llvm-nm`。AP 的 SHA-256 与实测 R3 完全一致，15 个负载/清单成员也逐字节一致；ZIP 容器时间戳导致整包 SHA 不同。使用 Apple clang 21 或其他 LLVM 版本生成的 AP 不同，未在设备验证。

将所需 LLVM 工具链目录显式放到 PATH 最前并用 `clang --version` 检查；不要因为本机装了某版本就认为构建实际用了它。Release 始终保留实测 ZIP 原字节，不用复建 ZIP 替换。

## 4. 手机实验版：从源码到自有签名

从仓库根目录运行，默认日常构建不启用实验 OTA：

```sh
TIO_OTA_RESEARCH_ENABLED=1 bash official-addon/build.sh embedded
node official-addon/package.mjs \
  --app /absolute/authorized/Payload/Runner.app \
  --addon /absolute/Turbo-IO/official-addon/build/ota-research/TurboIOPrivateAddon.dylib \
  --profile /absolute/private/development.mobileprovision \
  --identity YOUR_CERTIFICATE_SHA1 \
  --device YOUR_DEVICE_ID \
  --out /absolute/private/new-r3-output \
  --experimental-ota R3
```

仅接受官方 **iOS 1.0.5（201）**、原始 Bundle ID 和精确 App.framework 哈希；使用仓库首页的兼容原厂输入或自己合法准备的副本。输入不能已嵌入扩展，不能含维护者配置；不会自动下载、解密、查找个人证书或安装到设备。证书/描述文件/设备参数必须由你填写，打包沿用仓库现有 profile 检查与嵌入工具。可选高德 SDK 仍按导航文档自行准备，与本次固件实验无关。

打包得到你本机的签名 `.app` / IPA；**构建/签名成功不等于你的手机和眼镜已验收**。自行确认设备、备份和安装授权后，按 [V2 安装说明](../../../official-addon/README.md#本地合并签名安装) 使用自己的开发工具安装；仓库不提供作者的签名包。

发布前已从公开源码完成 arm64 编译，使用兼容的未加密原厂输入走通合并、个人签名、`codesign --verify --deep --strict` 和 IPA ZIP 完整性检查，结果为 `SIGNED_NOT_DEVICE_ACCEPTED`，`privateBootstrapIncluded=false`、`flashAuthorized=false`。该签名测试包仅留本机，未安装、未上传。带加密标志的旧缓存输入会被拒绝，不能仅凭文件夹名字认为输入可用。

实验页面在 **TurboIO → 诊断 → R3 试验用品**。先确认 UI 标记 `R3 SOURCE 01`，在手机“文件”中导入 Release 的原样实验 ZIP，等完整 SHA-256 校验通过。关闭官方自动更新，手动开启 15 分钟**仅下载**来源，再到官方软件版本页检查并下载，核对官方解压目录。此时尚未授权眼镜传输。若服务不通、目录不符或没有真实版本回读，停止，查看当前进程报告，不要重复点安装。

只有具备调试/恢复准备且接受风险的开发者，才能在上述前提齐全后选择“允许一次 R3 实验试刷”，输入 `R3`。它会冻结已校验文件、绑定当前设备，并给开始动作 15 分钟有效期；随后官方“开始安装”才可能实际发送。**这一步可能损坏设备，不是推荐操作。** 开始后不要重启 App、解绑、断电或换包。看到进度 100% 仍需等待眼镜重启与实际功能验收，不能立刻拔电。

[ios-reference](../ios-reference/README.md) 说明协议保护和 SOURCE 01 与私用前身的差异。公开集成已做本机编译/逻辑测试，**没有为了发布再次给用户眼镜刷写**，手机端完整现场验收仍需各开发者执行。

本仓库不提供“运行即刷”的工具，不在技能快速安装里引导自动刷机。研究应优先让离线模型和小页面逻辑可测试，而不是让刷写更容易误触。
