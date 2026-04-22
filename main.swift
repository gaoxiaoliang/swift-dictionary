// swift-dict: A native macOS dictionary app
import Foundation
import AppKit
import AVFoundation
import Carbon
import SQLite3

// SQLite destructor constants: SQLITE_TRANSIENT tells sqlite to copy the data immediately,
// avoiding dangling pointer issues when binding temporary Swift-managed strings/blobs.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - App Paths

/// 应用用户态存储目录 (遵循 macOS 惯例).
/// - 数据库: ~/Library/Application Support/swift-dict/dictionary.db
/// - 日志:   ~/Library/Logs/swift-dict/
enum AppPaths {
    static let appSupportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("swift-dict", isDirectory: true)
    }()

    static let logsDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/swift-dict", isDirectory: true)
    }()

    static let databaseURL: URL = appSupportDir.appendingPathComponent("dictionary.db")

    static func ensureDirectoriesExist() {
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    }
}

// MARK: - App Info (static metadata)

/// 静态开发者/应用信息, 供 "关于" 面板和窗口标题使用.
enum AppInfo {
    static let displayName = "词典"
    static let developerName = "Xiaoliang Gao"
    static let developerEmail = "xiaoliang.gao.dev@gmail.com"
    static let githubURL = "https://github.com/gaoxiaoliang/swift-dictionary"
}

// Note: BuildInfo (commit / buildTime / version) is generated at compile time
// by the Makefile from BuildInfo.swift.in. See BuildInfo.swift.

// MARK: - App Configuration

/// 应用配置, 使用 UserDefaults 持久化. 增删配置项时在 register(defaults:) 中补充默认值.
class AppConfig {
    static let shared = AppConfig()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let fadeOutEnabled = "fadeOutEnabled"
    }

    init() {
        defaults.register(defaults: [
            Keys.fadeOutEnabled: true
        ])
    }

    var fadeOutEnabled: Bool {
        get { defaults.bool(forKey: Keys.fadeOutEnabled) }
        set {
            defaults.set(newValue, forKey: Keys.fadeOutEnabled)
            Logger.shared.log("Config: fadeOutEnabled -> \(newValue)")
        }
    }
}

// MARK: - Database

class Database {
    static let shared = Database()
    
    private var db: OpaquePointer?
    
    init() {
        let dbPath = AppPaths.databaseURL.path
        Logger.shared.log("DB: 初始化数据库 - \(dbPath)")
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            Logger.shared.error("DB: 无法打开数据库", error: nil)
        } else {
            Logger.shared.log("DB: 数据库已打开")
            createTableIfNeeded()
        }
    }
    
    deinit {
        if db != nil {
            sqlite3_close(db)
        }
    }
    
    private func createTableIfNeeded() {
        let createSQL = """
            CREATE TABLE IF NOT EXISTS words (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                word TEXT UNIQUE NOT NULL,
                phonetics_uk TEXT,
                audio_url_uk TEXT,
                audio_data_uk BLOB,
                definitions TEXT,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, createSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        
        if sqlite3_prepare_v2(db, "CREATE INDEX IF NOT EXISTS idx_word ON words(word)", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        
        Logger.shared.log("DB: 表已准备就绪")
    }
    
    func getWord(_ word: String) -> YoudaoResult? {
        let querySQL = "SELECT phonetics_uk, audio_data_uk, definitions FROM words WHERE word = ?"
        var stmt: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, querySQL, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, (word.lowercased() as NSString).utf8String, -1, SQLITE_TRANSIENT)
        
        if sqlite3_step(stmt) == SQLITE_ROW {
            let phoneticPtr = sqlite3_column_text(stmt, 0)
            let audioDataPtr = sqlite3_column_blob(stmt, 1)
            let definitionsPtr = sqlite3_column_text(stmt, 2)
            
            var result = YoudaoResult()
            result.ukphone = phoneticPtr != nil ? String(cString: phoneticPtr!) : nil
            
            if audioDataPtr != nil {
                result.cachedAudioData = Data(bytes: audioDataPtr!, count: Int(sqlite3_column_bytes(stmt, 1)))
            }
            
            if let defPtr = definitionsPtr, let defStr = String(cString: defPtr).data(using: .utf8),
               let defArray = try? JSONSerialization.jsonObject(with: defStr) as? [String] {
                result.definitions = defArray
            }
            
            Logger.shared.log("DB: 命中缓存 - \(word)")
            return result
        }
        
        return nil
    }
    
    func saveWord(_ word: String, phonetic: String?, audioData: Data?, definitions: [String]) {
        let insertSQL = """
            INSERT OR REPLACE INTO words (word, phonetics_uk, audio_data_uk, definitions, created_at, updated_at)
            VALUES (?, ?, ?, ?, datetime('now'), datetime('now'))
        """
        var stmt: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            Logger.shared.error("DB: 保存失败", error: nil)
            return
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, (word.lowercased() as NSString).utf8String, -1, SQLITE_TRANSIENT)
        
        if let phonetic = phonetic {
            sqlite3_bind_text(stmt, 2, (phonetic as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        
        if let audioData = audioData {
            audioData.withUnsafeBytes { rawBuffer in
                if let baseAddr = rawBuffer.baseAddress {
                    sqlite3_bind_blob(stmt, 3, baseAddr, Int32(audioData.count), SQLITE_TRANSIENT)
                }
            }
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        
        if let defData = try? JSONSerialization.data(withJSONObject: definitions, options: []),
           let defString = String(data: defData, encoding: .utf8) {
            sqlite3_bind_text(stmt, 4, (defString as NSString).utf8String, -1, SQLITE_TRANSIENT)
        }
        
        if sqlite3_step(stmt) == SQLITE_DONE {
            Logger.shared.log("DB: 已保存 - \(word)")
        }
    }
}

// MARK: - Logger

/// 开发模式 (DEBUG 构建): 日志同时写入 stdout 和文件;
/// 生产模式 (RELEASE 构建): 日志仅写入 ~/Library/Logs/swift-dict/ 下的文件.
/// 每次启动时清理超过 "昨日" 的旧日志文件 (保留今日 + 昨日两份).
final class Logger {
    static let shared = Logger()

    private let logFile: URL?
    private let queue = DispatchQueue(label: "com.xiaoliang.swift-dict.logger")
    private let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    #if DEBUG
    static let isDebugBuild = true
    #else
    static let isDebugBuild = false
    #endif

    private init() {
        AppPaths.ensureDirectoriesExist()

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateStr = dateFormatter.string(from: Date())
        logFile = AppPaths.logsDir.appendingPathComponent("swift-dict-\(dateStr).log")

        pruneOldLogs()

        log("=== 应用启动 === (mode: \(Logger.isDebugBuild ? "DEBUG" : "RELEASE"))")
    }

    /// 保留今日 + 昨日的日志文件, 删除更旧的 (基于 mtime 判断).
    private func pruneOldLogs() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: AppPaths.logsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        // 今天 0 点往前推 24 小时 = 昨天 0 点, 即昨天 0 点之前的文件删除
        let cutoff = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-24 * 60 * 60)

        for file in files where file.pathExtension == "log" {
            if let attrs = try? fm.attributesOfItem(atPath: file.path),
               let mtime = attrs[.modificationDate] as? Date,
               mtime < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }

    func log(_ message: String) {
        let timestamp = timestampFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message)"

        queue.async { [weak self] in
            guard let self = self else { return }

            // 开发模式: 同时输出到 stdout
            if Logger.isDebugBuild {
                print(line)
            }

            // 两种模式都写文件
            if let logFile = self.logFile,
               let data = (line + "\n").data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logFile.path) {
                    if let handle = try? FileHandle(forWritingTo: logFile) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        try? handle.close()
                    }
                } else {
                    try? data.write(to: logFile)
                }
            }
        }
    }

    func error(_ message: String, error: Error? = nil) {
        let suffix = error != nil ? " - \(error!.localizedDescription)" : ""
        log("❌ \(message)\(suffix)")
    }
}

// MARK: - API Response

struct YoudaoResult {
    var ukphone: String?
    var ukspeech: String?     // URL string from API (network)
    var cachedAudioData: Data?  // Cached audio data from DB
    var definitions: [String] = []
}

/// 拼写建议 (词条未收录时由有道返回的 typos.typo)
struct TypoSuggestion {
    let word: String
    let trans: String
}

/// API 查询错误类型, 用于驱动 UI 展示不同文案
enum DictionaryQueryError: Error {
    /// 未收录该词条, 但 API 给出了候选拼写建议
    case notFoundWithSuggestions(input: String, suggestions: [TypoSuggestion])
    /// 未收录该词条, 且没有任何候选
    case notFound(input: String)
    /// 网络层错误 (无连接 / 超时 / DNS 等)
    case network(underlying: Error)
    /// 响应数据结构异常 (服务器返回非预期 JSON)
    case invalidResponse
}

// MARK: - Youdao API

class YoudaoAPI {
    static let shared = YoudaoAPI()
    
    private let headers = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Referer": "https://www.youdao.com/"
    ]
    
    func query(word: String, completion: @escaping (Result<YoudaoResult, Error>) -> Void) {
        Logger.shared.log("API: 开始查询单词 '\(word)'")
        
        if let cached = Database.shared.getWord(word) {
            Logger.shared.log("API: 使用缓存 - \(word)")
            completion(.success(cached))
            return
        }
        
        let encodedWord = word.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? word
        let urlString = "https://dict.youdao.com/jsonapi?q=\(encodedWord)&client=deskdict&dict=ec&le=eng"
        guard let url = URL(string: urlString) else {
            Logger.shared.error("API: 无效URL", error: nil)
            completion(.failure(NSError(domain: "Invalid URL", code: -1)))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                Logger.shared.error("API: 网络错误", error: error)
                completion(.failure(DictionaryQueryError.network(underlying: error)))
                return
            }
            
            guard let data = data else {
                Logger.shared.error("API: 无数据", error: nil)
                completion(.failure(DictionaryQueryError.invalidResponse))
                return
            }
            
            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    Logger.shared.error("API: JSON 根节点不是 object", error: nil)
                    completion(.failure(DictionaryQueryError.invalidResponse))
                    return
                }
                
                // 未收录: ec.word 缺失时, 优先返回拼写建议 (typos.typo)
                guard let ec = json["ec"] as? [String: Any],
                      let wordArray = ec["word"] as? [[String: Any]],
                      let wordData = wordArray.first else {
                    let suggestions = Self.parseTypoSuggestions(from: json)
                    if suggestions.isEmpty {
                        Logger.shared.log("API: 未找到 '\(word)' 且无拼写建议")
                        completion(.failure(DictionaryQueryError.notFound(input: word)))
                    } else {
                        Logger.shared.log("API: 未找到 '\(word)', 返回 \(suggestions.count) 个拼写建议")
                        completion(.failure(DictionaryQueryError.notFoundWithSuggestions(input: word, suggestions: suggestions)))
                    }
                    return
                }
                
                Logger.shared.log("API: raw response - \(wordData)")
                
                var result = YoudaoResult()
                result.ukphone = wordData["ukphone"] as? String
                result.ukspeech = wordData["ukspeech"] as? String
                
                var definitions: [String] = []
                
                // Try different parsing approaches
                if let trs = wordData["trs"] as? [[String: Any]] {
                    for trGroup in trs {
                        if let tr = trGroup["tr"] as? [[String: Any]] {
                            for item in tr {
                                if let l = item["l"] as? [String: Any] {
                                    if let i = l["i"] as? [String] {
                                        definitions.append(contentsOf: i)
                                    } else if let i = l["i"] as? String {
                                        definitions.append(i)
                                    }
                                } else if let i = item["i"] as? String {
                                    definitions.append(i)
                                }
                            }
                        } else if let tr = trGroup["tr"] as? [String: Any] {
                            if let l = tr["l"] as? [String: Any] {
                                if let i = l["i"] as? [String] {
                                    definitions.append(contentsOf: i)
                                } else if let i = l["i"] as? String {
                                    definitions.append(i)
                                }
                            }
                        }
                    }
                }
                
                result.definitions = definitions
                
                Logger.shared.log("API: 查询成功 - \(result.definitions.count) 个释义, 内容: \(definitions)")
                
                if result.ukspeech != nil {
                    let audioURL = URL(string: "https://dict.youdao.com/speech?word=\(word.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? word)&type=1")!
                    URLSession.shared.dataTask(with: audioURL) { audioData, _, _ in
                        if let audioData = audioData {
                            Database.shared.saveWord(word, phonetic: result.ukphone, audioData: audioData, definitions: result.definitions)
                        }
                    }.resume()
                }
                
                completion(.success(result))
            } catch {
                Logger.shared.error("API: JSON解析错误", error: error)
                completion(.failure(DictionaryQueryError.invalidResponse))
            }
        }.resume()
    }
    
    /// 从有道 API 响应中解析 typos.typo[] 字段
    private static func parseTypoSuggestions(from json: [String: Any]) -> [TypoSuggestion] {
        guard let typos = json["typos"] as? [String: Any],
              let list = typos["typo"] as? [[String: Any]] else {
            return []
        }
        return list.compactMap { item in
            guard let w = item["word"] as? String else { return nil }
            let trans = (item["trans"] as? String) ?? ""
            return TypoSuggestion(word: w, trans: trans)
        }
    }
}

// MARK: - Dictionary View Controller

class DictionaryViewController: NSViewController, NSTextFieldDelegate, NSTextViewDelegate {
    var searchField: NSTextField!
    var wordLabel: NSTextField!
    var phoneticLabel: NSTextField!
    var playButton: NSButton!
    var definitionsTextView: NSTextView!
    var scrollView: NSScrollView!
    var scrollViewHeightConstraint: NSLayoutConstraint!
    var loadingIndicator: NSProgressIndicator!
    
    var currentAudioURL: URL?
    var audioPlayer: AVAudioPlayer?
    var hasSearched: Bool = false
    /// 当前展示结果所对应的单词, 用于在 controlTextDidChange 中识别
    /// "用户是否在已有结果末尾追加字符", 从而把追加字符视为新一次输入并覆盖原词.
    var displayedWord: String = ""
    
    private var pasteMonitor: Any?
    
    // 淡出相关
    private var fadeOutTimer: Timer?
    /// 查询完成到彻底隐藏的总时长 (秒)
    static let fadeOutTotalDuration: TimeInterval = 10.0
    
    /// 粘贴内容长度上限 (超过视为不合理, 不自动查询)
    static let maxPasteLength: Int = 64
    
    // Cmd+V 的 key code
    private static let keyCodeV: UInt16 = 9
    
    // 布局常量
    static let contentWidth: CGFloat = 500
    static let horizontalPadding: CGFloat = 20
    static let textViewWidth: CGFloat = contentWidth - horizontalPadding * 2  // 460
    static let minDefinitionsHeight: CGFloat = 0
    static let maxDefinitionsHeight: CGFloat = 500
    
    // 当释义区为空时的基础高度 (search + wordLabel 区域 + 各种边距)
    // 布局: top(20) + searchField(28) + gap(20) + wordLabel(≈38) + gap(20) + scrollView + bottom(20)
    static let baseHeightWithoutDefinitions: CGFloat = 20 + 28 + 20 + 38 + 20 + 20
    // 初始(未查询)窗口高度: 只显示搜索框
    static let initialHeight: CGFloat = 20 + 28 + 20
    
    override func loadView() {
        Logger.shared.log("View: loadView")
        view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        setupUI()
    }
    
    func setupUI() {
        Logger.shared.log("View: setupUI")
        
        searchField = NSTextField()
        searchField.placeholderString = "请输入单词..."
        searchField.font = NSFont.systemFont(ofSize: 18)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        searchField.isSelectable = true
        searchField.allowsEditingTextAttributes = false
        searchField.focusRingType = .exterior
        view.addSubview(searchField)
        
        let searchButton = NSButton(title: "查询", target: self, action: #selector(searchWordAction))
        searchButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchButton)
        
        wordLabel = NSTextField(labelWithString: "")
        wordLabel.font = NSFont.boldSystemFont(ofSize: 32)
        wordLabel.textColor = .labelColor
        wordLabel.translatesAutoresizingMaskIntoConstraints = false
        wordLabel.isHidden = true
        view.addSubview(wordLabel)
        
        phoneticLabel = NSTextField(labelWithString: "")
        phoneticLabel.font = NSFont.systemFont(ofSize: 18)
        phoneticLabel.textColor = .secondaryLabelColor
        phoneticLabel.translatesAutoresizingMaskIntoConstraints = false
        phoneticLabel.isHidden = true
        view.addSubview(phoneticLabel)
        
        playButton = NSButton(image: NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "播放")!, target: self, action: #selector(playAudioAction))
        playButton.bezelStyle = .circular
        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.isHidden = true
        view.addSubview(playButton)
        
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        
        let textViewWidth = DictionaryViewController.textViewWidth
        definitionsTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: textViewWidth, height: 0))
        definitionsTextView.isEditable = false
        definitionsTextView.isSelectable = true
        definitionsTextView.font = NSFont.systemFont(ofSize: 14)
        definitionsTextView.textColor = .labelColor
        definitionsTextView.backgroundColor = .clear
        definitionsTextView.isVerticallyResizable = true
        definitionsTextView.isHorizontallyResizable = false
        definitionsTextView.textContainerInset = NSSize(width: 0, height: 0)
        definitionsTextView.textContainer?.containerSize = NSSize(width: textViewWidth, height: CGFloat.greatestFiniteMagnitude)
        definitionsTextView.textContainer?.widthTracksTextView = true
        definitionsTextView.textContainer?.lineFragmentPadding = 0
        definitionsTextView.delegate = self
        // 允许点击链接 (用于拼写建议)
        definitionsTextView.isAutomaticLinkDetectionEnabled = false
        definitionsTextView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .cursor: NSCursor.pointingHand,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        scrollView.documentView = definitionsTextView
        view.addSubview(scrollView)
        
        loadingIndicator = NSProgressIndicator()
        loadingIndicator.style = .spinning
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.isHidden = true
        view.addSubview(loadingIndicator)
        
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: searchButton.leadingAnchor, constant: -10),
            searchField.heightAnchor.constraint(equalToConstant: 28),
            
            searchButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            searchButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            searchButton.widthAnchor.constraint(equalToConstant: 80),
            
            wordLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 20),
            wordLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            
            phoneticLabel.centerYAnchor.constraint(equalTo: wordLabel.centerYAnchor),
            phoneticLabel.leadingAnchor.constraint(equalTo: wordLabel.trailingAnchor, constant: 15),
            
            playButton.centerYAnchor.constraint(equalTo: wordLabel.centerYAnchor),
            playButton.leadingAnchor.constraint(equalTo: phoneticLabel.trailingAnchor, constant: 15),
            playButton.widthAnchor.constraint(equalToConstant: 30),
            playButton.heightAnchor.constraint(equalToConstant: 30),
            
            scrollView.topAnchor.constraint(equalTo: wordLabel.bottomAnchor, constant: 20),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        
        scrollViewHeightConstraint = scrollView.heightAnchor.constraint(equalToConstant: 0)
        scrollViewHeightConstraint.isActive = true
        
        installPasteMonitor()
    }
    
    deinit {
        if let monitor = pasteMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
    
    /// 安装 Cmd+V 局部事件监听器: 搜索框获得焦点时, 读剪贴板 -> 清洗 -> 自动查询.
    private func installPasteMonitor() {
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let isCmdV = event.modifierFlags.contains(.command)
                && event.keyCode == DictionaryViewController.keyCodeV
                && !event.modifierFlags.contains(.shift)
                && !event.modifierFlags.contains(.option)
                && !event.modifierFlags.contains(.control)
            guard isCmdV else { return event }
            
            // 只在搜索框 (或其 field editor) 是第一响应者时接管 Cmd+V
            guard let window = self.view.window,
                  let responder = window.firstResponder else { return event }
            
            let searchFieldOwnsFocus: Bool = {
                if responder === self.searchField { return true }
                if let editor = self.searchField.currentEditor(), responder === editor { return true }
                return false
            }()
            guard searchFieldOwnsFocus else { return event }
            
            if self.handlePasteAndSearch() {
                return nil  // 吞掉事件, 防止系统默认粘贴再跑一遍
            }
            return event
        }
    }
    
    /// 从剪贴板读取内容, 清洗后填充搜索框并自动查询. 返回是否成功处理.
    @discardableResult
    private func handlePasteAndSearch() -> Bool {
        guard let raw = NSPasteboard.general.string(forType: .string) else {
            Logger.shared.log("View: Cmd+V 剪贴板为空或非文本")
            return false
        }
        
        guard let cleaned = Self.sanitizePastedWord(raw) else {
            Logger.shared.log("View: Cmd+V 剪贴板内容不符合英文单词/短语规范, 忽略 (原文长度=\(raw.count))")
            return false
        }
        
        Logger.shared.log("View: Cmd+V 粘贴并查询 '\(cleaned)'")
        // 先隐藏旧结果 (同时清 hasSearched / displayedWord),
        // 避免随后的 stringValue 赋值触发 controlTextDidChange 的覆盖分支.
        hideResultArea()
        searchField.stringValue = cleaned
        if let editor = searchField.currentEditor() {
            editor.selectedRange = NSRange(location: cleaned.count, length: 0)
        }
        searchWordAction()
        return true
    }
    
    /// 清洗剪贴板内容: 去首尾空白 -> 取首行 -> 长度限制 -> 仅允许英文字母/空格/连字符/撇号.
    /// 任一步失败返回 nil (交由系统默认粘贴行为处理, 不自动触发查询).
    static func sanitizePastedWord(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        
        // 取首行 (剪贴板里若带多行, 只用第一行)
        let firstLine = trimmed
            .split(whereSeparator: { $0.isNewline })
            .first
            .map(String.init) ?? trimmed
        let line = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, line.count <= maxPasteLength else { return nil }
        
        // 只接受英文字母/空格/连字符/撇号 (覆盖 "don't", "self-made", "New York" 等常见短语/词形)
        let allowed = CharacterSet.letters
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: "-'’"))
        if line.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return nil
        }
        // 至少含一个字母
        guard line.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else {
            return nil
        }
        return line
    }
    
    @objc func searchWordAction() {
        let word = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !word.isEmpty else { return }
        
        Logger.shared.log("View: 查询单词 '\(word)'")
        // 查询开始, 取消任何进行中的淡出 (窗口保持完全可见, 等查询返回再重新计时)
        cancelFadeOut()
        // 记录本次查询实际提交到输入框里的原始字符串, 供 controlTextDidChange 识别
        // "用户是否在已有结果后继续键入" 以便触发覆盖逻辑.
        displayedWord = searchField.stringValue
        showLoading(true)
        
        YoudaoAPI.shared.query(word: word) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.showLoading(false)
                switch result {
                case .success(let data):
                    self.displayResult(data, word: word)
                case .failure(let error):
                    self.handleQueryError(error, forWord: word)
                }
            }
        }
    }
    
    /// 分场景将 API 错误映射为对应的 UI 展示
    func handleQueryError(_ error: Error, forWord word: String) {
        if let apiError = error as? DictionaryQueryError {
            switch apiError {
            case .notFoundWithSuggestions(let input, let suggestions):
                showNotFound(input: input, suggestions: suggestions)
            case .notFound(let input):
                showNotFound(input: input, suggestions: [])
            case .network:
                showPlaceholderMessage("网络连接失败，请稍后重试")
            case .invalidResponse:
                showPlaceholderMessage("查询失败，请稍后重试")
            }
        } else {
            // 兜底: 非预期 Error 类型
            Logger.shared.error("View: 未知错误类型 - \(error)", error: error)
            showPlaceholderMessage("查询失败，请稍后重试")
        }
    }
    
    func displayResult(_ data: YoudaoResult, word: String) {
        Logger.shared.log("View: 显示结果 - word: \(word), phonetic: \(data.ukphone ?? "nil"), definitions: \(data.definitions.count)")
        
        hasSearched = true
        wordLabel.stringValue = word
        if let ukphone = data.ukphone {
            phoneticLabel.stringValue = "/\(ukphone)/"
        } else {
            phoneticLabel.stringValue = ""
        }
        wordLabel.isHidden = false
        phoneticLabel.isHidden = phoneticLabel.stringValue.isEmpty
        
        playButton.isHidden = false
        
        Logger.shared.log("View: 释义内容: \(data.definitions)")
        let joined = data.definitions.joined(separator: "\n")
        let defAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor
        ]
        definitionsTextView.textStorage?.setAttributedString(NSAttributedString(string: joined, attributes: defAttrs))
        
        // 根据释义内容自适应调整窗口高度
        adjustWindowHeightForContent()
        // 查询成功, 启动 10 秒淡出倒计时
        startFadeOutCountdown()
        
        if let cachedData = data.cachedAudioData {
            Logger.shared.log("View: 使用缓存音频 \(cachedData.count) bytes")
            do {
                audioPlayer = try AVAudioPlayer(data: cachedData)
                audioPlayer?.play()
                Logger.shared.log("View: 播放缓存音频")
            } catch {
                Logger.shared.error("View: 播放缓存音频失败", error: error)
            }
        } else if data.ukspeech != nil {
            currentAudioURL = URL(string: "https://dict.youdao.com/speech?word=\(word.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? word)&type=1")
            Logger.shared.log("View: 准备播放发音")
            playAudioAction()
        }
    }
    
    /// 根据当前释义内容计算所需高度，并动态调整 scrollView 高度及窗口高度
    func adjustWindowHeightForContent() {
        guard view.window != nil,
              let layoutManager = definitionsTextView.layoutManager,
              let textContainer = definitionsTextView.textContainer else { return }
        
        // 强制文本排版以获取真实高度
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let contentHeight = ceil(usedRect.height)
        
        let clampedHeight = min(max(contentHeight, DictionaryViewController.minDefinitionsHeight),
                                DictionaryViewController.maxDefinitionsHeight)
        
        scrollViewHeightConstraint.constant = clampedHeight
        
        // 计算窗口目标高度: baseHeightWithoutDefinitions 已包含 scrollView 上下各 20 的间距，
        // 这里减去上下间距常量中已计入的尾部 20, 再按实际内容追加.
        let bottomPadding: CGFloat = clampedHeight > 0 ? 20 : 0
        let contentAreaHeight = DictionaryViewController.baseHeightWithoutDefinitions - 20 + clampedHeight + bottomPadding
        
        resizeWindowKeepingTop(to: contentAreaHeight)
        
        Logger.shared.log("View: 自适应高度 - 文本高度: \(contentHeight), scrollView: \(clampedHeight), 窗口内容区: \(contentAreaHeight)")
    }
    
    // MARK: 查询完成后 10 秒淡出
    
    /// (重新) 启动淡出: alpha 1.0 -> 0.0 over `fadeOutTotalDuration`, 末尾 orderOut
    func startFadeOutCountdown() {
        guard AppConfig.shared.fadeOutEnabled else {
            Logger.shared.log("View: 淡出已禁用, 跳过")
            return
        }
        cancelFadeOut()
        guard let window = view.window, window.isVisible else { return }
        
        // 确保起点是完全不透明
        window.alphaValue = 1.0
        
        Logger.shared.log("View: 启动 \(DictionaryViewController.fadeOutTotalDuration)s 淡出倒计时")
        
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = DictionaryViewController.fadeOutTotalDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .linear)
            ctx.allowsImplicitAnimation = true
            window.animator().alphaValue = 0.0
        }, completionHandler: nil)
        
        // 用独立 Timer 决定何时真正 orderOut (动画 completionHandler 在被取消时
        // 也会触发, 不适合用它判断 "完整走完")
        fadeOutTimer = Timer.scheduledTimer(withTimeInterval: DictionaryViewController.fadeOutTotalDuration,
                                            repeats: false) { [weak self] _ in
            self?.finishFadeOut()
        }
    }
    
    /// 取消正在进行的淡出, 将窗口恢复至完全不透明
    func cancelFadeOut() {
        if fadeOutTimer != nil {
            Logger.shared.log("View: 取消淡出倒计时")
        }
        fadeOutTimer?.invalidate()
        fadeOutTimer = nil
        
        guard let window = view.window else { return }
        // 立即停止进行中的 alpha 动画, 把 alpha 直接设为 1
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0
            window.animator().alphaValue = 1.0
        }, completionHandler: nil)
        window.alphaValue = 1.0
    }
    
    /// 淡出计时结束: 彻底隐藏窗口, alpha 恢复 1.0 以便下次 orderFront 即可看到
    private func finishFadeOut() {
        fadeOutTimer = nil
        guard let window = view.window else { return }
        Logger.shared.log("View: 淡出结束, 隐藏窗口")
        window.orderOut(nil)
        window.alphaValue = 1.0
    }
    
    /// 调整窗口高度，同时保持窗口顶部位置不变
    func resizeWindowKeepingTop(to contentHeight: CGFloat) {
        guard let window = view.window else { return }
        
        let currentFrame = window.frame
        let currentContentSize = window.contentRect(forFrameRect: currentFrame).size
        let heightDelta = contentHeight - currentContentSize.height
        
        var newFrame = currentFrame
        newFrame.size.height = currentFrame.size.height + heightDelta
        // 保持顶部 y 坐标不变 (macOS 坐标系原点在左下)
        newFrame.origin.y = currentFrame.maxY - newFrame.size.height
        
        window.setFrame(newFrame, display: true, animate: false)
    }
    
    @objc func playAudioAction() {
        guard let url = currentAudioURL else { return }
        
        Logger.shared.log("View: 开始下载音频")
        
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let data = data, error == nil else {
                Logger.shared.error("View: 音频下载失败", error: error)
                return
            }
            Logger.shared.log("View: 音频下载成功 \(data.count) bytes")
            
            DispatchQueue.main.async {
                do {
                    self?.audioPlayer = try AVAudioPlayer(data: data)
                    self?.audioPlayer?.play()
                    Logger.shared.log("View: 开始播放音频")
                } catch {
                    Logger.shared.error("View: 播放失败", error: error)
                }
            }
        }.resume()
    }
    
    func showLoading(_ show: Bool) {
        if show {
            loadingIndicator.startAnimation(nil)
            loadingIndicator.isHidden = false
        } else {
            loadingIndicator.stopAnimation(nil)
            loadingIndicator.isHidden = true
        }
    }
    
    /// 在释义区显示一条居中、灰色的占位/状态提示 (无拼写建议时使用)
    func showPlaceholderMessage(_ message: String) {
        Logger.shared.log("View: 显示提示 - \(message)")
        wordLabel.isHidden = true
        phoneticLabel.isHidden = true
        playButton.isHidden = true
        hasSearched = true
        
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]
        let attr = NSAttributedString(string: message, attributes: attributes)
        definitionsTextView.textStorage?.setAttributedString(attr)
        adjustWindowHeightForContent()
        startFadeOutCountdown()
    }
    
    /// "未找到" 状态: 居中灰色提示 + 可点击的拼写建议列表
    func showNotFound(input: String, suggestions: [TypoSuggestion]) {
        Logger.shared.log("View: 未找到 '\(input)', 建议数=\(suggestions.count)")
        wordLabel.isHidden = true
        phoneticLabel.isHidden = true
        playButton.isHidden = true
        hasSearched = true
        
        let result = NSMutableAttributedString()
        
        let centerParagraph = NSMutableParagraphStyle()
        centerParagraph.alignment = .center
        centerParagraph.paragraphSpacing = 6
        
        let title = suggestions.isEmpty
            ? "未找到「\(input)」的释义，请检查拼写"
            : "未找到「\(input)」的释义，您是否想查："
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: centerParagraph
        ]
        result.append(NSAttributedString(string: title, attributes: titleAttrs))
        
        if !suggestions.isEmpty {
            // 候选列表: 每行一个可点击链接, 下方附该词的简要翻译
            let itemParagraph = NSMutableParagraphStyle()
            itemParagraph.alignment = .center
            itemParagraph.paragraphSpacing = 4
            itemParagraph.paragraphSpacingBefore = 6
            
            let transParagraph = NSMutableParagraphStyle()
            transParagraph.alignment = .center
            transParagraph.paragraphSpacing = 8
            
            for sug in suggestions {
                result.append(NSAttributedString(string: "\n", attributes: titleAttrs))
                
                // 建议词: 链接样式
                let linkURL = URL(string: "spell-suggest://\(sug.word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sug.word)")!
                let linkAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
                    .foregroundColor: NSColor.linkColor,
                    .link: linkURL,
                    .paragraphStyle: itemParagraph
                ]
                result.append(NSAttributedString(string: sug.word, attributes: linkAttrs))
                
                // 翻译 (若有)
                if !sug.trans.isEmpty {
                    result.append(NSAttributedString(string: "\n", attributes: titleAttrs))
                    let transAttrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 12),
                        .foregroundColor: NSColor.tertiaryLabelColor,
                        .paragraphStyle: transParagraph
                    ]
                    result.append(NSAttributedString(string: sug.trans, attributes: transAttrs))
                }
            }
        }
        
        definitionsTextView.textStorage?.setAttributedString(result)
        adjustWindowHeightForContent()
        startFadeOutCountdown()
    }
    
    // MARK: NSTextViewDelegate
    
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, url.scheme == "spell-suggest" else {
            return false
        }
        let word = (url.host ?? "").removingPercentEncoding ?? (url.host ?? "")
        guard !word.isEmpty else { return false }
        
        Logger.shared.log("View: 点击拼写建议 '\(word)'")
        searchField.stringValue = word
        searchWordAction()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.searchField.becomeFirstResponder()
            if let editor = self.searchField.currentEditor() {
                let end = editor.string.count
                editor.selectedRange = NSRange(location: end, length: 0)
            }
        }
        return true
    }
    
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            searchWordAction()
            return true
        }
        return false
    }
    
    func controlTextDidChange(_ notification: Notification) {
        guard hasSearched else { return }
        
        let current = searchField.stringValue
        
        // 识别 "用户在已有结果末尾继续键入" 的场景:
        // 当前字段内容 == 已查询的单词 + 追加部分. 此时视为新一次输入, 把原词覆盖为追加部分.
        // 其他变更 (删除/选中替换/中间编辑等) 只隐藏结果区, 不改动输入框内容.
        if !displayedWord.isEmpty,
           current.count > displayedWord.count,
           current.hasPrefix(displayedWord) {
            let appended = String(current.dropFirst(displayedWord.count))
            Logger.shared.log("View: 已有结果后键入新字符, 覆盖原词 '\(displayedWord)' -> '\(appended)'")
            searchField.stringValue = appended
            if let editor = searchField.currentEditor() {
                let end = appended.count
                editor.selectedRange = NSRange(location: end, length: 0)
            }
        }
        
        hideResultArea()
    }
    
    /// 隐藏结果展示区 (不触碰 searchField 内容), 并把窗口收回到仅搜索框的高度.
    /// 同时取消正在进行的淡出 —— 用户正在编辑意味着希望窗口继续可见.
    func hideResultArea() {
        cancelFadeOut()
        hasSearched = false
        displayedWord = ""
        wordLabel.isHidden = true
        phoneticLabel.isHidden = true
        playButton.isHidden = true
        definitionsTextView.string = ""
        scrollViewHeightConstraint.constant = 0
        resizeWindowKeepingTop(to: DictionaryViewController.initialHeight)
    }
}

// MARK: - Main Menu

/// 构造最小可用的 mainMenu. accessory app (LSUIElement) 的 mainMenu 不会在
/// 系统菜单栏中渲染, 但 AppKit 的快捷键分发链路依然依赖它: 按下 Cmd+A/Z/X/C/V
/// 时, AppKit 会遍历 mainMenu 查找匹配的 keyEquivalent, 命中后再沿响应链
/// (field editor -> NSTextView -> NSWindow) 调用对应 action selector.
///
/// 关键: 菜单项 target=nil, 让 action 走响应链; 这样不论焦点在 searchField
/// (NSTextField 的 field editor) 还是 definitionsTextView (NSTextView),
/// 标准编辑命令都能被正确响应.
enum MainMenuBuilder {
    static func build() -> NSMenu {
        let mainMenu = NSMenu()
        
        // 顶级 "应用" 菜单 (即便只在快捷键分发中使用也保留, 便于未来扩展 Cmd+Q)
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        let quitItem = NSMenuItem(
            title: "退出 \(AppInfo.displayName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        
        // "编辑" 菜单: 标准编辑命令. action 走响应链 (target=nil).
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        
        let undo = NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        undo.keyEquivalentModifierMask = [.command]
        editMenu.addItem(undo)
        
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        
        editMenu.addItem(NSMenuItem.separator())
        
        let cut = NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        cut.keyEquivalentModifierMask = [.command]
        editMenu.addItem(cut)
        
        let copy = NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        copy.keyEquivalentModifierMask = [.command]
        editMenu.addItem(copy)
        
        let paste = NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        paste.keyEquivalentModifierMask = [.command]
        editMenu.addItem(paste)
        
        let selectAll = NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        selectAll.keyEquivalentModifierMask = [.command]
        editMenu.addItem(selectAll)
        
        editMenuItem.submenu = editMenu
        
        return mainMenu
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!
    
    // 单击 Right Command 检测
    /// Right Cmd 按下后标记为待触发; 若释放前按了任何其他键, 则取消 (说明是组合快捷键)
    private var rightCmdTriggerPending = false
    /// 跟踪 Right Cmd 按下/释放状态, 用 toggle() 切换以避免左右 Cmd 同时按下时判断错误
    private var rightCmdIsDown = false
    // 单击 Right Option 检测 (窗口可见时聚焦搜索框)
    private var rightOptTriggerPending = false
    private var rightOptIsDown = false
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var localKeyDownMonitor: Any?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.shared.log("App: applicationDidFinishLaunching")
        
        // 安装 mainMenu: 即便是 accessory 模式 (菜单栏不渲染), AppKit 仍依赖
        // mainMenu 的 keyEquivalent 来分发 Cmd+A/Z/X/C/V 等标准编辑快捷键.
        // 没有这套菜单时, selectAll: / undo: / redo: 在文本控件里不会生效.
        NSApp.mainMenu = MainMenuBuilder.build()
        Logger.shared.log("App: mainMenu 已安装 (Edit 菜单快捷键分发就绪)")
        
        setupStatusItem()
        Logger.shared.log("App: 状态栏图标已设置")
        
        setupWindow()
        Logger.shared.log("App: 窗口已设置 - frame: \(window.frame)")
        
        checkAccessibilityPermission()
        installRightCommandMonitor()
        
        // 定位窗口到屏幕顶部 (菜单栏正下方)
        positionWindowAtTop()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        Logger.shared.log("App: 窗口已显示 - isVisible: \(window.isVisible), frame: \(window.frame)")
    }
    
    /// 首次启动检查辅助功能权限; 未授权则弹系统原生引导窗并在日志提示
    func checkAccessibilityPermission() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: CFDictionary = [promptKey: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if trusted {
            Logger.shared.log("App: 辅助功能权限已授予")
        } else {
            Logger.shared.log("⚠️ App: 辅助功能权限未授予, Right Command 快捷键无法工作.")
            Logger.shared.log("⚠️ App: 请在 系统偏好设置 → 安全性与隐私 → 隐私 → 辅助功能 中勾选 swift-dict, 然后重启应用.")
        }
    }
    
    /// 安装全局 + 本地事件监听, 实现 "单击 Right Command 唤起/隐藏".
    /// 同时监听 flagsChanged (修饰键变化) 和 keyDown (普通按键), 以区分:
    /// - 单独按下并释放 Right Cmd → 切换窗口
    /// - Right Cmd + 其他键 (组合快捷键) → 不触发, 避免误触
    func installRightCommandMonitor() {
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.processFlagsChanged(event)
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.processFlagsChanged(event)
            return event
        }

        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.processKeyDown()
        }
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.processKeyDown()
            return event
        }
        Logger.shared.log("App: Right Command / Right Option 监听已安装 (单击模式, 组合键不触发)")
    }
    
    /// HID key code: 左 Command = 55, 右 Command = 54
    private static let rightCommandKeyCode: UInt16 = 54
    /// HID key code: 左 Option = 58, 右 Option = 61
    private static let rightOptionKeyCode: UInt16 = 61
    
    private func processFlagsChanged(_ event: NSEvent) {
        // 若 Right Cmd/Option 待触发期间有其他修饰键变化, 说明用户在按组合键, 取消所有待触发
        if (rightCmdTriggerPending || rightOptTriggerPending)
            && event.keyCode != AppDelegate.rightCommandKeyCode
            && event.keyCode != AppDelegate.rightOptionKeyCode {
            rightCmdTriggerPending = false
            rightOptTriggerPending = false
            return
        }

        // Right Command 处理
        if event.keyCode == AppDelegate.rightCommandKeyCode {
            rightCmdIsDown.toggle()
            if rightCmdIsDown {
                rightCmdTriggerPending = true
            } else {
                if rightCmdTriggerPending {
                    rightCmdTriggerPending = false
                    Logger.shared.log("App: 检测到单击 Right Command")
                    DispatchQueue.main.async { [weak self] in
                        self?.toggleWindow()
                    }
                }
            }
            return
        }

        // Right Option 处理 (仅窗口可见时聚焦搜索框)
        if event.keyCode == AppDelegate.rightOptionKeyCode {
            rightOptIsDown.toggle()
            if rightOptIsDown {
                rightOptTriggerPending = true
            } else {
                if rightOptTriggerPending {
                    rightOptTriggerPending = false
                    Logger.shared.log("App: 检测到单击 Right Option")
                    DispatchQueue.main.async { [weak self] in
                        self?.focusSearchField()
                    }
                }
            }
        }
    }

    /// 将焦点移到搜索框 (窗口可见时激活并聚焦, 不可见时忽略)
    private func focusSearchField() {
        guard window.isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if let vc = window.contentViewController as? DictionaryViewController {
            vc.searchField.becomeFirstResponder()
            if !vc.searchField.stringValue.isEmpty,
               let editor = vc.searchField.currentEditor() {
                let end = editor.string.count
                editor.selectedRange = NSRange(location: end, length: 0)
            }
        }
    }

    /// 任何普通按键按下时, 若 Right Cmd/Option 处于待触发状态, 说明用户在使用组合快捷键, 取消触发
    private func processKeyDown() {
        rightCmdTriggerPending = false
        rightOptTriggerPending = false
    }
    
    /// 将窗口水平居中并紧贴系统菜单栏下方
    func positionWindowAtTop() {
        guard let screen = NSScreen.main else { return }
        // visibleFrame 排除了菜单栏和 Dock, 其 maxY 即为菜单栏下边缘的 y 坐标
        let visibleFrame = screen.visibleFrame
        let windowWidth = window.frame.width
        let x = visibleFrame.origin.x + (visibleFrame.width - windowWidth) / 2
        let topLeft = NSPoint(x: x, y: visibleFrame.maxY)
        window.setFrameTopLeftPoint(topLeft)
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        Logger.shared.log("App: 应用退出")
        if let m = globalFlagsMonitor { NSEvent.removeMonitor(m) }
        if let m = localFlagsMonitor { NSEvent.removeMonitor(m) }
        if let m = globalKeyDownMonitor { NSEvent.removeMonitor(m) }
        if let m = localKeyDownMonitor { NSEvent.removeMonitor(m) }
    }
    
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "book.fill", accessibilityDescription: "Dictionary")
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // 同时接收左键和右键的抬起事件, 由 action 中根据事件类型分流
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            Logger.shared.log("App: 状态栏按钮点击事件已绑定 (左键/右键)")
        }
    }
    
    @objc func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            Logger.shared.log("App: 右键点击状态栏图标 - 弹出菜单")
            showStatusItemMenu()
        } else {
            Logger.shared.log("App: 左键点击状态栏图标 - 切换窗口")
            toggleWindow()
        }
    }
    
    /// 右键菜单: 关于 / 配置 / 退出. 动态挂载到 statusItem.menu, 弹出后立即摘除
    /// 以免左键点击也出现菜单.
    private func showStatusItemMenu() {
        let menu = NSMenu()

        let aboutItem = NSMenuItem(
            title: "关于 \(AppInfo.displayName)",
            action: #selector(showAboutPanel),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        let configItem = NSMenuItem(
            title: "配置...",
            action: #selector(showConfigPanel),
            keyEquivalent: ","
        )
        configItem.target = self
        menu.addItem(configItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "退出 \(AppInfo.displayName)",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc func quitApp() {
        Logger.shared.log("App: 用户通过菜单退出应用")
        NSApp.terminate(nil)
    }

    /// "关于" 面板: 展示开发者信息 + 构建元数据.
    /// accessory app 不会自动聚焦, 弹框前先 activate 避免 Alert 被遮挡.
    @objc func showAboutPanel() {
        Logger.shared.log("App: 显示关于面板")

        let alert = NSAlert()
        alert.messageText = AppInfo.displayName
        alert.informativeText = """
        开发者: \(AppInfo.developerName)
        邮箱: \(AppInfo.developerEmail)
        GitHub: \(AppInfo.githubURL)

        Commit: \(BuildInfo.commit)
        构建时间: \(BuildInfo.buildTime)
        构建模式: \(Logger.isDebugBuild ? "DEBUG" : "RELEASE")
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好的")

        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// "配置" 面板: 让用户选择是否启用查询完成后的自动淡出.
    @objc func showConfigPanel() {
        if let vc = window.contentViewController as? DictionaryViewController {
            vc.cancelFadeOut()
        }

        let alert = NSAlert()
        alert.messageText = "配置"
        alert.alertStyle = .informational

        let checkbox = NSButton(checkboxWithTitle: "查询完成后自动淡出窗口", target: nil, action: nil)
        checkbox.state = AppConfig.shared.fadeOutEnabled ? .on : .off

        let container = NSStackView()
        container.orientation = .vertical
        container.addArrangedSubview(checkbox)
        container.setFrameSize(NSSize(width: 240, height: 24))

        alert.accessoryView = container

        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            let newEnabled = (checkbox.state == .on)
            let oldEnabled = AppConfig.shared.fadeOutEnabled
            AppConfig.shared.fadeOutEnabled = newEnabled

            if !newEnabled {
                if let vc = window.contentViewController as? DictionaryViewController {
                    vc.cancelFadeOut()
                }
            } else if newEnabled && !oldEnabled {
                if let vc = window.contentViewController as? DictionaryViewController {
                    if vc.hasSearched {
                        vc.startFadeOutCountdown()
                    }
                }
            }
        }
    }
    
    func setupWindow() {
        let initialHeight = DictionaryViewController.initialHeight
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: DictionaryViewController.contentWidth, height: initialHeight),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppInfo.displayName
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentViewController = DictionaryViewController()
        // 不使用 setFrameAutosaveName, 否则会恢复上次位置/大小, 破坏 "顶部固定 + 自适应高度" 行为
    }
    
    @objc func toggleWindow() {
        if window.isVisible {
            Logger.shared.log("App: 隐藏窗口")
            // 窗口可能正在淡出 (alpha 已经变小但仍 isVisible), 此时也视为可见, 立即彻底隐藏
            if let vc = window.contentViewController as? DictionaryViewController {
                vc.cancelFadeOut()
            }
            window.orderOut(nil)
            window.alphaValue = 1.0  // 为下次唤起准备
        } else {
            Logger.shared.log("App: 显示窗口 - frame: \(window.frame)")
            window.alphaValue = 1.0  // 清除上次淡出残留
            positionWindowAtTop()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            
            if let vc = window.contentViewController as? DictionaryViewController {
                DispatchQueue.main.async {
                    vc.searchField.becomeFirstResponder()
                    if !vc.searchField.stringValue.isEmpty,
                       let editor = vc.searchField.currentEditor() {
                        let end = editor.string.count
                        editor.selectedRange = NSRange(location: end, length: 0)
                    }
                }
            }
            
            Logger.shared.log("App: 窗口已显示 - frame: \(window.frame)")
        }
    }
}

// MARK: - Main Entry

let app = NSApplication.shared

// 设置为 accessory 模式 (菜单栏应用, 不显示在 Dock)
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate

// Note: accessory app 不会在系统菜单栏渲染 app.mainMenu, 但 AppKit 的快捷键
// 分发链路仍依赖 mainMenu 的 keyEquivalent. 具体构建见 MainMenuBuilder,
// 在 AppDelegate.applicationDidFinishLaunching 中安装.
// 状态栏右键菜单 (关于/退出) 由 AppDelegate.showStatusItemMenu() 动态生成.

// 命令行参数支持
let args = CommandLine.arguments
if args.count > 1 {
    let word = args[1].lowercased()
    Logger.shared.log("Main: 命令行参数查询 '\(word)'")
    
    // 异步查询
    YoudaoAPI.shared.query(word: word) { result in
        DispatchQueue.main.async {
            switch result {
            case .success(let data):
                print("=== \(data.ukphone ?? word) ===")
                if let phonetic = data.ukphone {
                    print("音标: /\(phonetic)/")
                }
                print("\n释义:")
                for def in data.definitions {
                    print("  \(def)")
                }
                if data.ukspeech != nil {
                    print("\n发音: https://dict.youdao.com/speech?word=\(word.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? word)&type=1")
                }
                app.terminate(nil)
            case .failure(let error):
                if let apiError = error as? DictionaryQueryError {
                    switch apiError {
                    case .notFoundWithSuggestions(let input, let suggestions):
                        print("未找到「\(input)」的释义，您是否想查：")
                        for sug in suggestions {
                            print("  - \(sug.word)  \(sug.trans)")
                        }
                    case .notFound(let input):
                        print("未找到「\(input)」的释义，请检查拼写")
                    case .network(let underlying):
                        print("网络连接失败: \(underlying.localizedDescription)")
                    case .invalidResponse:
                        print("查询失败: 响应数据异常")
                    }
                } else {
                    print("查询失败: \(error.localizedDescription)")
                }
                app.terminate(nil)
            }
        }
    }
    
    app.run()
} else {
    app.run()
}
