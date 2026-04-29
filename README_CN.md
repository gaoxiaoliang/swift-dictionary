# SwiftDict（词典）

一款极简 macOS 英汉词典应用，纯 vibe coding 之作——常驻菜单栏、单键唤起、查完即走。

[English →](README.md)

## 缘起

我想要的是一款零摩擦的词典：不留 Dock、不用找窗口、不点多余按钮。敲一下按键，查一个词，完事。SwiftDict 就是这样的工具，为自己而写，顺手开源。

## 快捷键一览

| 按键 | 场景 | 功能 |
|---|---|---|
| **右 Command** | 任意位置 | 唤起/隐藏词典窗口 |
| **右 Option** | 窗口可见时 | 聚焦搜索框 |
| **Enter** | 搜索框聚焦时 | 查询当前输入 |
| **Cmd+V** | 搜索框聚焦时 | 读取剪贴板 → 清洗 → 自动查询 |
| **`[`** | 窗口聚焦时 | 后退到上一个查询 |
| **`]`** | 窗口聚焦时 | 前进到下一个查询 |
| **`↓`** | 搜索框聚焦时 | 展开下一个结果区域 |
| **`↑`** | 搜索框聚焦时 | 收缩上一个结果区域 |
| **Esc** | 窗口聚焦时 | 隐藏词典窗口 |

一张表看完，上手零成本。

## 核心功能

- **全局快捷键** — 在任意 App 内按右 Command 即可唤起或隐藏窗口。
- **粘贴即查** — 搜索框聚焦时按 `Cmd+V`，自动清洗剪贴板内容并查询。支持 `"don't"`、`"self-made"` 等多词短语。
- **离线缓存** — 查过的词条存入本地 SQLite，命中时零网络等待。
- **发音播放** — 每次查询自动播放英式发音，点喇叭图标可重播。
- **查询历史** — `[` / `]` 像浏览器一样前进后退，最多记录 100 条。
- **其他词性与近义词** — 释义下方可展开显示词形变化和近义词（配置中开启或按 `↓`/`↑` 临时切换）。
- **拼写建议** — 拼错单词时给出可点击的纠正建议。
- **自动淡出** — 查询后 10 秒窗口自动消失，可关闭。
- **菜单栏常驻** — 不占 Dock、不进 Cmd+Tab。右键书图标弹出菜单。

## 配置

右键菜单栏图标 → 配置（或 `Cmd+,`）：

| 配置项 | 默认 | 说明 |
|---|---|---|
| 自动淡出窗口 | 开 | 查询完成后 10 秒自动隐藏 |
| 显示其他词性 | 关 | 显示动词/名词/副词等词形变化 |
| 显示近义词 | 关 | 按词性分组显示近义词 |

数据库区显示缓存词条数和文件大小，日志区列出日志文件路径和大小。

## 安装

### 下载

从 [Releases](https://github.com/gaoxiaoliang/swift-dictionary/releases) 下载最新 DMG，打开后将 `SwiftDict.app` 拖入 `/Applications`。

### 辅助功能权限

首次启动时按提示授予辅助功能权限（系统设置 → 隐私与安全性 → 辅助功能），右 Command 全局快捷键依赖此项。

### 从源码构建

```sh
git clone https://github.com/gaoxiaoliang/swift-dictionary.git
cd swift-dictionary
make install    # 构建 .app 并替换 /Applications/SwiftDict.app
```

需要 macOS 12+、Swift 5.7+，无第三方依赖。

## 数据足迹

| 路径 | 内容 |
|---|---|
| `~/Library/Application Support/SwiftDict/dictionary.db` | SQLite 缓存（词条、音频 BLOB） |
| `~/Library/Logs/SwiftDict/SwiftDict-YYYY-MM-DD.log` | 日志（按天轮转，自动清理） |
| `~/Library/Preferences/com.xiaoliang.SwiftDict.plist` | UserDefaults 配置 |

## License

MIT
