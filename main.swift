// swift-dict: A native macOS dictionary app
import Foundation
import AppKit
import AVFoundation
import Carbon
import SQLite3

// MARK: - Database

class Database {
    static let shared = Database()
    
    private var db: OpaquePointer?
    private let dbPath = "/Users/clearbug/Desktop/swift-dictionary/dictionary.db"
    
    init() {
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
        
        sqlite3_bind_text(stmt, 1, (word.lowercased() as NSString).utf8String, -1, nil)
        
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
        
        sqlite3_bind_text(stmt, 1, (word.lowercased() as NSString).utf8String, -1, nil)
        
        if let phonetic = phonetic {
            sqlite3_bind_text(stmt, 2, (phonetic as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        
        if let audioData = audioData {
            let ptr = audioData.withUnsafeBytes { $0.baseAddress }
            sqlite3_bind_blob(stmt, 3, ptr, Int32(audioData.count), nil)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        
        if let defData = try? JSONSerialization.data(withJSONObject: definitions, options: []),
           let defString = String(data: defData, encoding: .utf8) {
            sqlite3_bind_text(stmt, 4, (defString as NSString).utf8String, -1, nil)
        }
        
        if sqlite3_step(stmt) == SQLITE_DONE {
            Logger.shared.log("DB: 已保存 - \(word)")
        }
    }
}

// MARK: - Logger

class Logger {
    static let shared = Logger()
    
    let logFile: URL?
    
    init() {
        // macOS 标准日志位置: ~/Library/Logs/swift-dict/
        let logsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/swift-dict")
        
        // 创建日志目录
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateStr = dateFormatter.string(from: Date())
        
        logFile = logsDir.appendingPathComponent("swift-dict-\(dateStr).log")
        
        log("=== 应用启动 ===")
    }
    
    func log(_ message: String) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = dateFormatter.string(from: Date())
        
        let logLine = "[\(timestamp)] \(message)"
        
        // 输出到标准输出
        print(logLine)
        
        // 写入文件
        if let logFile = logFile {
            let line = logLine + "\n"
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logFile.path) {
                    if let fileHandle = try? FileHandle(forWritingTo: logFile) {
                        fileHandle.seekToEndOfFile()
                        fileHandle.write(data)
                        fileHandle.closeFile()
                    }
                } else {
                    try? data.write(to: logFile)
                }
            }
        }
    }
    
    func error(_ message: String, error: Error? = nil) {
        let errorMsg = error != nil ? " - \(error!.localizedDescription)" : ""
        log("❌ \(message)\(errorMsg)")
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
        
        let urlString = "https://dict.youdao.com/jsonapi?q=\(word)&client=deskdict&dict=ec&le=eng"
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
                    let audioURL = URL(string: "https://dict.youdao.com/speech?word=\(word)&type=1")!
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
    var lastInputLength: Int = 0
    
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
    }
    
    @objc func searchWordAction() {
        let word = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !word.isEmpty else { return }
        
        Logger.shared.log("View: 查询单词 '\(word)'")
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
            currentAudioURL = URL(string: "https://dict.youdao.com/speech?word=\(word)&type=1")
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
        lastInputLength = word.count
        searchWordAction()
        return true
    }
    
    /// 清空显示内容, 将窗口恢复到初始 (仅搜索框) 高度
    func resetToInitialState() {
        hasSearched = false
        wordLabel.isHidden = true
        phoneticLabel.isHidden = true
        playButton.isHidden = true
        definitionsTextView.string = ""
        scrollViewHeightConstraint.constant = 0
        resizeWindowKeepingTop(to: DictionaryViewController.initialHeight)
    }
    
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            searchWordAction()
            return true
        }
        return false
    }
    
    func controlTextDidChange(_ notification: Notification) {
        let currentLength = searchField.stringValue.count
        if hasSearched && currentLength > lastInputLength {
            let newChar = searchField.stringValue.suffix(1)
            resetToInitialState()
            searchField.stringValue = String(newChar)
            lastInputLength = 1
        } else {
            lastInputLength = currentLength
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!
    var hotKey: EventHotKeyRef?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.shared.log("App: applicationDidFinishLaunching")
        
        setupStatusItem()
        Logger.shared.log("App: 状态栏图标已设置")
        
        setupWindow()
        Logger.shared.log("App: 窗口已设置 - frame: \(window.frame)")
        
        registerGlobalHotKey()
        Logger.shared.log("App: 全局快捷键已注册 (Cmd+Shift+D)")
        
        // 定位窗口到屏幕顶部 (菜单栏正下方)
        positionWindowAtTop()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        Logger.shared.log("App: 窗口已显示 - isVisible: \(window.isVisible), frame: \(window.frame)")
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
    }
    
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "book.fill", accessibilityDescription: "Dictionary")
            button.target = self
            button.action = #selector(statusItemClicked)
            Logger.shared.log("App: 状态栏按钮点击事件已绑定")
        }
    }
    
    @objc func statusItemClicked() {
        Logger.shared.log("App: 点击状态栏图标")
        toggleWindow()
    }
    
    func setupWindow() {
        let initialHeight = DictionaryViewController.initialHeight
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: DictionaryViewController.contentWidth, height: initialHeight),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "词典"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentViewController = DictionaryViewController()
        // 不使用 setFrameAutosaveName, 否则会恢复上次位置/大小, 破坏 "顶部固定 + 自适应高度" 行为
    }
    
    func registerGlobalHotKey() {
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x44495354)
        hotKeyID.id = 1
        
        let modifiers: UInt32 = UInt32(cmdKey | shiftKey)
        let keyCode: UInt32 = 2
        
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerRef = Unmanaged.passUnretained(self).toOpaque()
        
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, userData) -> OSStatus in
            guard let userData = userData else { return OSStatus(noErr) }
            let app = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            app.toggleWindow()
            return noErr
        }, 1, &eventType, handlerRef, nil)
        
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKey)
        
        if status == noErr {
            Logger.shared.log("App: 全局快捷键注册成功")
        } else {
            Logger.shared.error("App: 全局快捷键注册失败", error: nil)
        }
    }
    
    func unregisterGlobalHotKey() {
        if let hotKey = hotKey {
            UnregisterEventHotKey(hotKey)
        }
    }
    
    @objc func toggleWindow() {
        if window.isVisible {
            Logger.shared.log("App: 隐藏窗口")
            window.orderOut(nil)
        } else {
            Logger.shared.log("App: 显示窗口 - frame: \(window.frame)")
            positionWindowAtTop()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            
            if let vc = window.contentViewController as? DictionaryViewController {
                DispatchQueue.main.async {
                    vc.searchField.becomeFirstResponder()
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

let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
let appMenu = NSMenu()
appMenu.addItem(withTitle: "关于 swift-dict", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
appMenu.addItem(NSMenuItem.separator())
appMenu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu
mainMenu.addItem(appMenuItem)

let editMenuItem = NSMenuItem()
let editMenu = NSMenu(title: "编辑")
editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
editMenu.addItem(NSMenuItem.separator())
editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editMenuItem.submenu = editMenu
mainMenu.addItem(editMenuItem)

let windowMenuItem = NSMenuItem()
let windowMenu = NSMenu(title: "窗口")
windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
windowMenuItem.submenu = windowMenu
mainMenu.addItem(windowMenuItem)

app.mainMenu = mainMenu

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
                    print("\n发音: https://dict.youdao.com/speech?word=\(word)&type=1")
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
