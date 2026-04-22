# swift-dict（词典）

一个追求「极致便捷」的 macOS 原生英汉词典小工具：常驻菜单栏、单键唤起、粘贴即查、查完即隐。

- 应用名: 词典 (swift-dict)
- Bundle ID: `com.xiaoliang.swift-dict`
- 仓库: <https://github.com/gaoxiaoliang/swift-dictionary>
- 作者: Xiaoliang Gao &lt;xiaoliang.gao.dev@gmail.com&gt;

---

## 一、设计目标

词典类工具使用场景高频、路径短，任何一次额外点击都是摩擦。本项目围绕「极致便捷」做取舍：

- 不占 Dock、不进 Cmd+Tab，常驻菜单栏。
- 任意 App 内按一次 **Right Command** 即可唤起/隐藏查询窗口。
- 窗口唤起后焦点自动落在搜索框，直接打字或 **Cmd+V** 粘贴即查。
- 查询完成 10 秒后窗口自动淡出（可在配置面板关闭）。
- 命中缓存的词条完全离线，零网络等待。
- 单文件 Swift 源码（`main.swift`, ~1870 行）+ 一个 `Makefile`，无第三方依赖，无 Xcode 工程文件。

---

## 二、功能清单

### 2.1 查询与发音

- 在线查询接口: 有道词典 `https://dict.youdao.com/jsonapi`（字典 `ec`，英汉）
- 解析并展示: 英式音标 (ukphone)、释义列表、英式发音音频 (ukspeech)
- 发音播放: 通过 `AVFoundation.AVAudioPlayer` 播放 mp3
- 拼写建议: 未收录单词时解析 `typos.typo[]` 并在结果区以可点击超链接形式列出（点击后回填搜索框并直接查询）
- 错误分型: 未收录 (有/无候选)、网络错误、响应结构异常，各自走不同文案

### 2.2 本地缓存（SQLite）

- 首次查询成功后将「单词 / 音标 / 音频二进制 / 释义 JSON」写入 `words` 表
- 命中缓存的后续查询不发任何网络请求，音频直接由 BLOB 读出播放
- 数据库文件: `~/Library/Application Support/swift-dict/dictionary.db`
- 配置面板内展示当前词条数和数据库文件大小

### 2.3 快捷交互

| 快捷键 / 动作 | 行为 |
| --- | --- |
| 单击 **Right Command**（全局） | 切换查询窗口的显示/隐藏 |
| 单击 **Right Option**（窗口可见时） | 聚焦搜索框、光标移到末尾 |
| **Enter** | 查询当前输入 |
| **Cmd+V**（搜索框聚焦时） | 读剪贴板 → 清洗（单行、≤64 字符、仅字母/空格/连字符/撇号）→ 自动查询 |
| **Cmd+A / Z / X / C / V** 等 | 标准编辑快捷键（手动装配 mainMenu 以兼容 accessory 模式） |
| **Esc** | 关闭「关于 / 配置」面板 |
| 左键点击菜单栏图标 | 切换窗口 |
| 右键点击菜单栏图标 | 弹出菜单：关于 / 配置 / 退出 |

Right Command / Right Option 通过 `NSEvent.addGlobalMonitorForEvents` 捕获 `flagsChanged` 实现，借助 key code (`54` / `61`) 区分左右修饰键；按下期间若监测到任何其他按键/修饰键变化，视为组合键场景，取消触发，避免误触系统快捷键。

### 2.4 窗口行为

- 窗口默认 500pt 宽，初始高度仅显示搜索框，查询后根据释义内容在 0~500pt 高度范围内自适应
- 唤起时水平居中、顶部贴紧系统菜单栏下方
- 查询完成 10 秒后整窗 fade-out（2 秒动画），`cancelFadeOut()` 在用户再次交互、切换配置、再次查询时自动取消

### 2.5 菜单栏与面板

- 菜单栏图标: SF Symbol `book.fill`
- 关于面板: 开发者信息、commit、构建时间、构建模式（DEBUG/RELEASE）
- 配置面板（单页分区）:
  - 基本配置: 「查询完成后自动淡出窗口」开关（`UserDefaults` 持久化）
  - 数据库: 路径 + 词条数 + 文件大小
  - 日志: 各 `.log` 文件路径与大小

### 2.6 日志

- 存储位置: `~/Library/Logs/swift-dict/swift-dict-<yyyy-MM-dd>.log`
- DEBUG 构建: 日志同时写入 stdout 与文件；RELEASE 构建: 只写文件
- 启动时自动清理「昨日之前」的旧日志文件（按 mtime）
- 写入经由串行 `DispatchQueue` 序列化，避免并发冲突

### 2.7 命令行模式

直接带参调用二进制，查询结果打印到 stdout 后退出：

```
./swift-dict hello
```

输出包含音标、释义列表，以及发音 URL。

---

## 三、运行环境

### 3.1 开发机 / 当前构建环境

| 项目 | 值 |
| --- | --- |
| 操作系统 | macOS 12.7.6 (Monterey, Darwin 21.6.0, build 21H1320) |
| CPU | Intel(R) Core(TM) i7-4770HQ @ 2.20GHz (x86_64) |
| 内存 | 16 GB |
| Swift | Apple Swift 5.7.2 (swiftlang-5.7.2.135.5, clang-1400.0.29.51) |
| swift-driver | 1.62.15 |
| 构建目标 | `x86_64-apple-macosx12.0` |
| Xcode (仅工具链) | 14.2 (14C18) |
| GNU Make | 3.81 |

### 3.2 运行要求（最低）

- macOS 12.0 或更高（`LSMinimumSystemVersion=12.0`，见 `Resources/Info.plist.in`）
- 全局快捷键（Right Command / Right Option）需要「辅助功能」权限
  - 系统设置 → 隐私与安全性 → 辅助功能 → 添加并勾选 `swift-dict`
  - 首次启动会弹出系统原生权限引导

---

## 四、依赖

项目刻意保持「零第三方依赖」，仅使用 Apple 官方 SDK 提供的系统库：

| 库 / 框架 | 用途 |
| --- | --- |
| `Foundation` | URL / URLSession / JSONSerialization / FileManager / UserDefaults / DispatchQueue 等基础能力 |
| `AppKit` | 窗口、菜单栏、面板、视图控件、事件监听 (`NSEvent`) |
| `AVFoundation` | `AVAudioPlayer` 播放 mp3 发音 |
| `Carbon` | `AXIsProcessTrustedWithOptions` 辅助功能权限检查（`kAXTrustedCheckOptionPrompt`） |
| `SQLite3` | C API 直连 SQLite，用于本地词条/音频缓存 |

额外：链接时显式引入 `-lsqlite3`（见 Makefile `LIBS`）。

---

## 五、项目结构

```
swift-dictionary/
├── main.swift                  # 全部源码 (~1870 行, 单文件)
├── BuildInfo.swift             # 构建期由 Makefile 生成 (已纳入 .gitignore)
├── BuildInfo.swift.in          # BuildInfo 模板 (commit / version / buildTime 占位)
├── Makefile                    # 构建、打包、DMG 入口
├── Resources/
│   └── Info.plist.in           # .app bundle Info.plist 模板
├── scripts/
│   └── make-dmg.sh             # 将 .app 打包成 DMG (hdiutil + /Applications 软链)
├── build/                      # 构建产物 (.app bundle, 已 gitignore)
├── dist/                       # DMG 发布产物 (已 gitignore)
└── swift-dict                  # 生成的二进制 (已 gitignore)
```

源码主要组件（均在 `main.swift`）：

- `AppPaths` — 应用存储路径（App Support / Logs / DB）
- `AppInfo` / `BuildInfo` — 静态元信息
- `AppConfig` — `UserDefaults` 持久化配置
- `Database` — SQLite 封装，`words` 表的读写
- `Logger` — 单例日志，文件 + stdout（按构建模式）
- `YoudaoAPI` — 有道 API 调用、缓存查表、拼写建议解析
- `DictionaryViewController` — 窗口主界面、搜索、粘贴监听、释义渲染、音频播放、淡出
- `MainMenuBuilder` — 手动装配 Edit 菜单以启用标准编辑快捷键
- `EscClosablePanel` — 支持 Esc 关闭的 `NSPanel` 子类
- `AppDelegate` — 状态栏、窗口管理、Right Command/Option 全局监听、辅助功能检查、关于/配置面板

---

## 六、构建与运行

所有操作通过 `make` 即可：

```sh
make               # 等价 make debug
make debug         # 生成二进制 ./swift-dict (带 -D DEBUG, -g, -Onone)
make release       # 生成二进制 ./swift-dict (-O)
make run           # debug 构建后直接运行
make app           # 构建 build/swift-dict.app (含 ad-hoc 代码签名)
make dmg           # 打包 dist/swift-dict-<version>.dmg
make clean         # 清理所有构建产物
```

每次构建都会重新生成 `BuildInfo.swift`，其中：

- `commit` = `git rev-parse --short HEAD`
- `version` = `git describe --tags --always --dirty`
- `buildTime` = 本地时间戳

`make app` 会进行本地 ad-hoc 签名（`codesign --sign -`），不需要 Apple Developer 账号；首次启动若被 Gatekeeper 拦截，右键 → 打开 即可。

---

## 七、数据与权限足迹

应用只写入以下用户目录，不触碰系统路径：

| 路径 | 内容 |
| --- | --- |
| `~/Library/Application Support/swift-dict/dictionary.db` | SQLite 缓存（词条、音频 BLOB） |
| `~/Library/Logs/swift-dict/swift-dict-YYYY-MM-DD.log` | 日志（自动按天轮转，只保留今日 + 昨日） |
| `~/Library/Preferences/com.xiaoliang.swift-dict.plist` | `UserDefaults`（配置项如 `fadeOutEnabled`） |

所需权限：

- **辅助功能 (Accessibility)**: 捕获全局 `flagsChanged` 事件以实现 Right Command / Right Option 唤起
- **网络访问**: 未命中缓存时请求 `https://dict.youdao.com`（`NSAppTransportSecurity.NSAllowsArbitraryLoads=true`）

---

## 八、已知限制

- 仅支持英译中（有道 `dict=ec&le=eng`），未接入其他语种词典
- 仅抓取英式音标/发音（`ukphone` / `ukspeech`），未处理美式
- 依赖的有道接口为非官方稳定契约，上游变更可能导致解析失败
- 全局快捷键 hard-coded 为 Right Command / Right Option，暂不支持自定义
