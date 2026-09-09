import Foundation

/// 界面文案本地化。中文原文就是键，译文在 Resources/Localizable.xcstrings 里；
/// 没有对应译文时原样返回中文，所以漏翻不会变成空字符串。
enum L10n {
    /// 正常从主 bundle 取；测试可换成某个语言的 lproj bundle 检查译文。
    /// 只在主线程改（测试里），读取处无锁，靠 nonisolated(unsafe) 声明这个约定。
    nonisolated(unsafe) static var bundle: Bundle = .main

    static func t(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// 带占位符的文案，键里用 %@ 标出位置
    static func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), locale: Locale.current, arguments: args)
    }
}
