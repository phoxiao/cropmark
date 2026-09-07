# Cropmark

独立复刻微信 Mac 版截图工具：不用启动微信，按 `⌃⌘A` 就能截图、标注、复制到剪贴板。

## 功能

- 全局快捷键唤起（默认 `⌃⌘A`，可改），菜单栏常驻，无 Dock 图标
- 按下瞬间冻结所有屏幕画面，光标悬停自动识别窗口，单击即选中整窗
- 拖选区域，实时显示像素尺寸；松手后 8 个把手可拉伸，选区内拖动可移动
- 工具栏：矩形 / 椭圆 / 箭头 / 画笔 / 马赛克 / 文字，6 色 3 粗细，撤销
  - 矩形、椭圆按住 Shift 为正方形、正圆；箭头按住 Shift 吸附 45°
- `Enter` / 双击 / 「完成」→ 复制到剪贴板；「保存」→ 系统保存框（默认桌面）；`Esc` / 右键 → 取消
- 设置：改快捷键、登录时启动、提示音开关

## 构建与安装

需要 Xcode 26 和 [xcodegen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）。

```bash
make install      # 生成工程 → 编译 → 拷到 /Applications → 启动
```

其他命令：`make build`（只编译）、`make run`（编译并从构建目录启动）、`make test`（单元测试）、`make icon`（用 `scripts/make-icon.swift` 重新生成应用图标）、`make clean`。
构建产物放在 `~/Library/Caches/CropmarkBuild`。

## 首次运行

1. 第一次按快捷键会提示授予「屏幕录制」权限，去 **系统设置 → 隐私与安全性 → 屏幕录制** 勾选 Cropmark。
2. 微信如果在运行，它自己的 `⌃⌘A` 会和 Cropmark 抢快捷键，在微信设置里把它关掉或改掉即可。

`make install` 会在装机前用本机的 Apple Development 证书重签（Makefile 里的 `SIGN_ID` 自动查找），这样重新编译后「屏幕录制」权限仍然有效。
如果换成 ad-hoc 签名（`CODE_SIGN_IDENTITY: "-"`），每次重编译都会让已授予的权限失效，症状是开关显示打开却一直弹授权提示；此时执行 `tccutil reset ScreenCapture com.kivixiao.cropmark` 后重新授权。

## 结构

```
Cropmark/App         菜单栏、快捷键、设置窗口
Cropmark/Capture     ScreenCaptureKit 抓屏、窗口识别、权限
Cropmark/Session     一次截图会话：覆盖窗、选区状态机、工具栏
Cropmark/Annotation  标注模型与渲染（预览和导出共用一份代码）
Cropmark/Export      裁剪合成、剪贴板/保存
CropmarkTests        纯逻辑单元测试
```
