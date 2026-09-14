# Cropmark

**简体中文** | [English](README.md)

macOS 轻量截图工具。按一下 `⌃⌘A`，框选、标注、复制到剪贴板，全程不用离开键盘。菜单栏常驻，没有 Dock 图标，不联网。

## 功能

- 全局快捷键唤起（默认 `⌃⌘A`，可改）
- 按下瞬间冻结所有屏幕画面；光标悬停自动识别窗口，以及窗口**内部**的对话框、面板、卡片，单击即选中
- 拖选区域，实时显示像素尺寸；松手后 8 个把手可拉伸，选区内拖动可移动
- 标注工具：矩形 / 椭圆 / 箭头 / 画笔 / 马赛克 / 文字，6 色 3 粗细，`⌘Z` 撤销
  - 矩形、椭圆按住 Shift 为正方形、正圆；箭头按住 Shift 吸附 45°
- `Enter` / 双击 / 点「完成」→ 复制到剪贴板。剪贴板里同时有图片（PNG + TIFF）和一个 PNG 文件：聊天、文档直接贴图，Finder、Slack、终端、Claude Code 这类只认文件的地方也能粘贴
- `⌘S` / 点「保存」→ 系统保存框，默认桌面，文件名 `截屏2026-09-07 14.30.12.png`
- `Esc` / 右键 → 取消
- Retina 屏幕可选「缩小到 1x」：复制和保存分别设置，贴进公众号、文档不再是两倍大，体积也小得多；尺寸标签用 `@2x` / `@1x` 标出当前输出
- 快捷键可以设成 `F1`–`F12` 单键
- 设置：改快捷键、登录时启动、提示音开关、输出缩放、剪贴板是否附带文件
- 界面跟随系统语言：简体中文、英文
- 自动更新：每天检查一次 GitHub 上的新版本，有新版弹窗一键升级；可关闭，也可从菜单栏手动「检查更新…」

## 安装

1. 到 [Releases](https://github.com/phoxiao/cropmark/releases) 下载最新的 `Cropmark-x.y.z.dmg`，打开后把 Cropmark 拖进「应用程序」。
2. **首次打开**：本版本没有经过 Apple 公证，双击会提示"无法验证开发者"。到 **系统设置 → 隐私与安全性**，滚到底部点 **「仍要打开」**，再确认一次即可。之后不会再问。
   也可以在终端执行：
   ```bash
   xattr -d com.apple.quarantine /Applications/Cropmark.app
   ```
3. **屏幕录制权限**：第一次按快捷键会提示授权，到 **系统设置 → 隐私与安全性 → 屏幕录制** 勾选 Cropmark。系统会要求退出并重新打开 Cropmark，重新打开后再按快捷键即可。

如果其他应用也用了 `⌃⌘A`（微信、QQ、企业微信的截图默认就是这个组合键），按下时两边会同时响应，两个截图界面一起弹出；有的应用会在系统层拦截按键，Cropmark 就完全收不到。两种情况都没法从 Cropmark 这边检测或修复，只能在对方设置里改掉，或在 Cropmark 设置里换一个（`F1`–`F12` 可以单独使用）。

## 隐私

Cropmark 不收集任何数据。截图只存在剪贴板或你选择保存的位置；屏幕录制权限仅用于按下快捷键那一刻抓取屏幕画面。

唯一的网络请求是检查更新：每天向 GitHub 请求一次版本清单（`docs/appcast.xml`），只下载不上传。第一次启动时会询问是否开启，设置里随时可关。

开启「剪贴板同时附带 PNG 文件」（默认开）时，每次复制会在 `~/Library/Caches/Cropmark/Clipboard/` 写一份 PNG，只保留最近 20 张。不想留文件就在设置里关掉。

## 从源码构建

需要 Xcode 26 和 [xcodegen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）。

```bash
make install      # 生成工程 → 编译 → 用本机开发证书签名 → 拷到 /Applications → 启动
```

其他命令：

| 命令 | 作用 |
|------|------|
| `make build` | 只编译 Debug 版 |
| `make run` | 编译并从构建目录启动 |
| `make test` | 单元测试与进程内功能测试 |
| `make icon` | 重新生成应用图标。图形定义在 `Cropmark/App/IconArtwork.swift`，菜单栏图标共用同一份 |
| `make release` | 编译 Release 版，签名（可选公证），打包 dmg / zip 到 `dist/` |
| `make clean` | 清理构建产物和生成的工程 |

构建产物放在 `~/Library/Caches/CropmarkBuild`。

关于签名：`make install` / `make release` 会自动查找本机证书（优先 Developer ID Application，其次 Apple Development）。用稳定的证书签名，重新编译后「屏幕录制」权限才不会失效。如果只有 ad-hoc 签名，每次重编译都要重新授权，遇到"开关开着却一直弹授权"时执行 `tccutil reset ScreenCapture com.kivixiao.cropmark` 后重新授权。

有付费开发者账号时，先用 `xcrun notarytool store-credentials <名字>` 存好凭据，再 `NOTARY_PROFILE=<名字> make release`，脚本会自动公证并装订，用户就不再需要「仍要打开」那一步。

## 发布与自动更新

更新走 [Sparkle](https://sparkle-project.org)：应用读取 `docs/appcast.xml`，里面是最新版本号、下载地址和 EdDSA 签名。发布一个新版本：

1. 改 `project.yml` 的 `CFBundleShortVersionString`、`CFBundleVersion` 和 `CHANGELOG.md`，提交
2. `make release`：构建、签名、打包到 `dist/`，并用钥匙串里的私钥生成 `docs/appcast.xml`
3. `git tag vX.Y.Z && git push origin vX.Y.Z`，然后 `gh release create vX.Y.Z dist/*.dmg dist/*.zip dist/SHA256SUMS.txt`
4. 最后提交 `docs/appcast.xml` 并推送。这一步必须在 Release 附件上传之后，否则旧版本会下到 404

签名密钥只需生成一次：`<SPM 缓存>/artifacts/sparkle/Sparkle/bin/generate_keys`，私钥进登录钥匙串，输出的公钥填到 `project.yml` 的 `SUPublicEDKey`。换机器发布要先 `generate_keys -x 文件` 导出、在新机器 `generate_keys -f 文件` 导入。

## 本地化

界面文案以中文原文为键，译文放在 `Cropmark/Resources/Localizable.xcstrings`，代码里统一通过 `L10n.t("中文")` 取值，没有译文时原样显示中文。加一种语言只需在 String Catalog 里补一列，不用改代码。

README 不走这套，是手工翻译的，见下面的[文档翻译](#文档翻译)。

## 结构

```
Cropmark/App         菜单栏、快捷键、设置窗口
Cropmark/Capture     ScreenCaptureKit 抓屏、窗口识别、权限
Cropmark/Session     一次截图会话：覆盖窗、选区状态机、工具栏
Cropmark/Annotation  标注模型与渲染（预览和导出共用一份代码）
Cropmark/Export      裁剪合成、剪贴板 / 保存
CropmarkTests        单元测试与进程内功能测试
scripts/             图标生成、发布打包
```

## 文档翻译

GitHub 的仓库首页只渲染根目录那一个 `README.md`，不会按访客的浏览器语言挑选译文版本。所以每份 README 顶部的语言链接是手动的——这是通行做法，不是漏做。首页放英文，是因为 GitHub 的访客大多在英文语境。

这份 `README.zh-CN.md` 是撰写时的正本，`README.md`（英文）是手工翻译。改动时请在同一个提交里同步两份，否则很快就会对不上。

## 许可

[MIT](LICENSE)。第三方依赖见 [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)。
