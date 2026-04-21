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
    private let dbPath = "/Users/clearbug/Desktop/my-swift-dictionary/dictionary.db"
    
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
                completion(.failure(error))
                return
            }
            
            guard let data = data else {
                Logger.shared.error("API: 无数据", error: nil)
                completion(.failure(NSError(domain: "No data", code: -1)))
                return
            }
            
            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let ec = json["ec"] as? [String: Any],
                      let wordArray = ec["word"] as? [[String: Any]],
                      let wordData = wordArray.first else {
                    Logger.shared.error("API: 解析失败", error: nil)
                    completion(.failure(NSError(domain: "Parse error", code: -1)))
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
                completion(.failure(error))
            }
        }.resume()
    }
}

// MARK: - Dictionary View Controller

class DictionaryViewController: NSViewController, NSTextFieldDelegate {
    var searchField: NSTextField!
    var wordLabel: NSTextField!
    var phoneticLabel: NSTextField!
    var playButton: NSButton!
    var definitionsTextView: NSTextView!
    var loadingIndicator: NSProgressIndicator!
    
    var currentAudioURL: URL?
    var audioPlayer: AVAudioPlayer?
    var hasSearched: Bool = false
    var lastInputLength: Int = 0
    
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
        
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        
        definitionsTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 300))
        definitionsTextView.isEditable = false
        definitionsTextView.isSelectable = true
        definitionsTextView.font = NSFont.systemFont(ofSize: 14)
        definitionsTextView.textColor = .labelColor
        definitionsTextView.backgroundColor = .clear
        definitionsTextView.isVerticallyResizable = true
        definitionsTextView.isHorizontallyResizable = false
        definitionsTextView.textContainer?.containerSize = NSSize(width: 460, height: CGFloat.greatestFiniteMagnitude)
        definitionsTextView.textContainer?.widthTracksTextView = true
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
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
    
    @objc func searchWordAction() {
        let word = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !word.isEmpty else { return }
        
        Logger.shared.log("View: 查询单词 '\(word)'")
        showLoading(true)
        
        YoudaoAPI.shared.query(word: word) { [weak self] result in
            DispatchQueue.main.async {
                self?.showLoading(false)
                switch result {
                case .success(let data):
                    self?.displayResult(data, word: word)
                case .failure(let error):
                    self?.showError(error.localizedDescription)
                }
            }
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
        definitionsTextView.string = data.definitions.joined(separator: "\n")
        
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
    
    func showError(_ message: String) {
        Logger.shared.error("View: 显示错误 - \(message)", error: nil)
        wordLabel.isHidden = true
        phoneticLabel.isHidden = true
        playButton.isHidden = true
        definitionsTextView.string = message
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
            hasSearched = false
            wordLabel.isHidden = true
            phoneticLabel.isHidden = true
            playButton.isHidden = true
            definitionsTextView.string = ""
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
        
        // 强制显示
        window.setFrameAutosaveName("MainWindow")
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        Logger.shared.log("App: 窗口已显示 - isVisible: \(window.isVisible), frame: \(window.frame)")
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
        let screenHeight = NSScreen.main?.frame.height ?? 400
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "词典"
        window.setFrameTopLeftPoint(NSPoint(x: (NSScreen.main?.frame.width ?? 500) / 2 - 250, y: screenHeight - 10))
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentViewController = DictionaryViewController()
        window.setFrameAutosaveName("MainWindow")
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
            window.setFrameAutosaveName("MainWindow")
            let screenHeight = NSScreen.main?.frame.height ?? 400
            window.setFrameTopLeftPoint(NSPoint(x: (NSScreen.main?.frame.width ?? 500) / 2 - 250, y: screenHeight - 10))
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
                print("查询失败: \(error)")
                app.terminate(nil)
            }
        }
    }
    
    app.run()
} else {
    app.run()
}
