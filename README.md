# Cropmark

macOS 轻量截图工具。按一下 `⌃⌘A`，框选、标注、复制到剪贴板，全程不用离开键盘。菜单栏常驻，没有 Dock 图标，不联网。

## 功能

- 全局快捷键唤起（默认 `⌃⌘A`，可改）
- 按下瞬间冻结所有屏幕画面；光标悬停自动识别窗口，单击即选中整窗
- 拖选区域，实时显示像素尺寸；松手后 8 个把手可拉伸，选区内拖动可移动
- 标注工具：矩形 / 椭圆 / 箭头 / 画笔 / 马赛克 / 文字，6 色 3 粗细，`⌘Z` 撤销
  - 矩形、椭圆按住 Shift 为正方形、正圆；箭头按住 Shift 吸附 45°
- `Enter` / 双击 / 点「完成」→ 复制到剪贴板（PNG + TIFF，任何应用都能粘贴）
- `⌘S` / 点「保存」→ 系统保存框，默认桌面，文件名 `截屏2026-09-07 14.30.12.png`
- `Esc` / 右键 → 取消
- 设置：改快捷键、登录时启动、提示音开关

## 安装

1. 到 [Releases](https://github.com/phoxiao/cropmark/releases) 下载最新的 `Cropmark-x.y.z.dmg`，打开后把 Cropmark 拖进「应用程序」。
2. **首次打开**：本版本没有经过 Apple 公证，双击会提示"无法验证开发者"。到 **系统设置 → 隐私与安全性**，滚到底部点 **「仍要打开」**，再确认一次即可。之后不会再问。
   也可以在终端执行：
   ```bash
   xattr -d com.apple.quarantine /Applications/Cropmark.app
   ```
3. **屏幕录制权限**：第一次按快捷键会提示授权，到 **系统设置 → 隐私与安全性 → 屏幕录制** 勾选 Cropmark。系统会要求退出并重新打开 Cropmark，重新打开后再按快捷键即可。

如果其他应用占用了 `⌃⌘A`（不少聊天软件的截图默认也是这个组合键），二者会互相抢键，在对方设置里改掉，或在 Cropmark 设置里换一个。

## 隐私

Cropmark 不联网、不收集任何数据。截图只存在剪贴板或你选择保存的位置；屏幕录制权限仅用于按下快捷键那一刻抓取屏幕画面。

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
| `make icon` | 用 `scripts/make-icon.swift` 重新生成应用图标 |
| `make release` | 编译 Release 版，签名（可选公证），打包 dmg / zip 到 `dist/` |
| `make clean` | 清理构建产物和生成的工程 |

构建产物放在 `~/Library/Caches/CropmarkBuild`。

关于签名：`make install` / `make release` 会自动查找本机证书（优先 Developer ID Application，其次 Apple Development）。用稳定的证书签名，重新编译后「屏幕录制」权限才不会失效。如果只有 ad-hoc 签名，每次重编译都要重新授权，遇到"开关开着却一直弹授权"时执行 `tccutil reset ScreenCapture com.kivixiao.cropmark` 后重新授权。

有付费开发者账号时，先用 `xcrun notarytool store-credentials <名字>` 存好凭据，再 `NOTARY_PROFILE=<名字> make release`，脚本会自动公证并装订，用户就不再需要「仍要打开」那一步。

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

## 许可

[MIT](LICENSE)。第三方依赖见 [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)。
