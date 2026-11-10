import CryptoKit
import Foundation
import Security

/// 版本号，比如 0.4.1。允许前面带 "v"（标签名）；其他写法（含测试版后缀）都不算版本。
struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    let parts: [Int]

    init?(_ text: String) {
        let t = text.hasPrefix("v") ? text.dropFirst() : Substring(text)
        var parts: [Int] = []
        for p in t.split(separator: ".", omittingEmptySubsequences: false) {
            guard !p.isEmpty, p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber), let n = Int(p) else { return nil }
            parts.append(n)
        }
        guard !parts.isEmpty else { return nil }
        self.parts = parts
    }

    /// 0.5 和 0.5.0 是同一个版本
    static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    var description: String { parts.map(String.init).joined(separator: ".") }
}

/// GitHub 上最新的正式版本，和更新要用的两个文件
struct Release: Sendable, Equatable {
    var version: AppVersion
    /// 这个版本在 GitHub 上的页面，看更新内容
    var page: URL
    /// `Islander-<版本>.zip`：公证过的 App
    var archive: URL
    var archiveName: String
    /// `SHA256SUMS`
    var checksums: URL
}

enum UpdateError: LocalizedError, Equatable {
    case http(Int)
    case noRelease
    case missingAsset(String)
    case checksum
    case unpack(String)
    case signature(String)
    case wrongApp(String)
    case cannotReplace(String)

    var errorDescription: String? {
        switch self {
        case .http(403), .http(429): "GitHub 暂时拒绝了请求（访问太频繁），稍后再试。"
        case .http(let code): "GitHub 返回了 HTTP \(code)。"
        case .noRelease: "GitHub 上没有可用的正式版本。"
        case .missingAsset(let name): "这个版本缺少 \(name)，没法自动更新。"
        case .checksum: "下载的文件和 SHA256SUMS 对不上，已丢弃。"
        case .unpack(let m): "解压失败：\(m)"
        case .signature(let m): "新版本的签名校验没通过，没有安装：\(m)"
        case .wrongApp(let m): "下载到的不是预期的岛民版本：\(m)"
        case .cannotReplace(let m): m
        }
    }
}

/// 从 GitHub Releases 找新版本、下载、校验、替换自己。界面和时机在 Updater。
enum Updates {
    static let repository = "kadaliao/islander"
    static let bundleID = "com.kadaliao.islander"
    static let archivePrefix = "Islander-"
    private static let developerID = """
        identifier "com.kadaliao.islander" and anchor apple generic \
        and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] \
        and certificate leaf[subject.OU] = "HMDAVG9B8J"
        """
    /// 新版本必须满足：是岛民、用本项目的 Developer ID 签名、经过 Apple 公证
    static let requirement = developerID + " and notarized"

    static let releasesPage = URL(string: "https://github.com/\(repository)/releases/latest")!
    private static let latestAPI = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    // MARK: - 查找

    /// 最新发布的版本（GitHub 的 latest 不含草稿和预发布版）
    static func latest(userAgent: String, session: URLSession = .shared) async throws -> Release {
        var req = URLRequest(url: latestAPI, timeoutInterval: 30)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        try check(response)
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> Release {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        struct Body: Decodable {
            let tag_name: String
            let html_url: URL
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]
        }
        let b = try JSONDecoder().decode(Body.self, from: data)
        guard b.draft != true, b.prerelease != true, let version = AppVersion(b.tag_name) else { throw UpdateError.noRelease }
        let plain = b.tag_name.hasPrefix("v") ? String(b.tag_name.dropFirst()) : b.tag_name
        let name = "\(archivePrefix)\(plain).zip"
        guard let zip = b.assets.first(where: { $0.name == name }) else { throw UpdateError.missingAsset(name) }
        guard let sums = b.assets.first(where: { $0.name == "SHA256SUMS" }) else { throw UpdateError.missingAsset("SHA256SUMS") }
        // 页面会在浏览器里打开，文件会被下载：只认 HTTPS 的 GitHub
        let onGitHub = { (u: URL) in u.scheme == "https" && u.host == "github.com" }
        guard onGitHub(b.html_url), onGitHub(zip.browser_download_url), onGitHub(sums.browser_download_url) else {
            throw UpdateError.noRelease
        }
        return Release(version: version, page: b.html_url, archive: zip.browser_download_url,
                       archiveName: name, checksums: sums.browser_download_url)
    }

    // MARK: - 下载

    /// 把这个版本的压缩包下载到 `dir`，并和 SHA256SUMS 核对。那里已有完好的就直接用
    static func download(_ r: Release, to dir: URL, userAgent: String, session: URLSession = .shared) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var req = URLRequest(url: r.checksums, timeoutInterval: 60)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (sums, response) = try await session.data(for: req)
        try check(response)
        guard let expected = checksum(in: String(decoding: sums, as: UTF8.self), for: r.archiveName) else {
            throw UpdateError.missingAsset("SHA256SUMS: \(r.archiveName)")
        }
        let dest = dir.appendingPathComponent(r.archiveName)
        if fm.fileExists(atPath: dest.path), (try? sha256(dest)) == expected { return dest }

        req.url = r.archive
        let (tmp, archiveResponse) = try await session.download(for: req)
        defer { try? fm.removeItem(at: tmp) }
        try check(archiveResponse)
        guard try sha256(tmp) == expected else { throw UpdateError.checksum }
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: tmp, to: dest)
        return dest
    }

    /// SHA256SUMS 里 `name` 的哈希（每行是 "<哈希>  <文件名>"）
    static func checksum(in sums: String, for name: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            if f.count == 2, f[1] == name || f[1] == "*" + name, f[0].count == 64 { return f[0].lowercased() }
        }
        return nil
    }

    static func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func check(_ response: URLResponse) throws {
        if let h = response as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw UpdateError.http(h.statusCode) }
    }

    // MARK: - 校验

    /// 解压到和 `installed` 同一个卷上（安装就只是一次改名），并检查里面的 App。
    /// 用完由调用方删掉返回的 App 所在的文件夹
    static func unpack(_ archive: URL, version: AppVersion, near installed: URL) throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: installed, create: true)
        do {
            try ditto(["-x", "-k", archive.path, dir.path])
            let apps = try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".app") }
            guard apps.count == 1 else { throw UpdateError.wrongApp("压缩包里有 \(apps.count) 个 App") }
            let app = dir.appendingPathComponent(apps[0])
            let kind = try app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard kind.isDirectory == true, kind.isSymbolicLink != true else { throw UpdateError.wrongApp(apps[0]) }
            try verify(app, version: version)
            return app
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
    }

    private static func ditto(_ arguments: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = arguments
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { throw UpdateError.unpack(error.localizedDescription) }
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw UpdateError.unpack(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// App 必须正好是岛民 `version` 版、用本项目的 Developer ID 签名、经过公证、没被改过
    /// （每个文件、每种架构、里面嵌的代码都算）
    static func verify(_ app: URL, version: AppVersion) throws {
        try checkSignature(app, requirement: requirement)
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
            throw UpdateError.wrongApp("Info.plist")
        }
        guard info["CFBundleIdentifier"] as? String == bundleID else {
            throw UpdateError.wrongApp(info["CFBundleIdentifier"] as? String ?? "?")
        }
        let found = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
        guard let found, found == version else {
            throw UpdateError.wrongApp("版本是 \(found?.description ?? "?")，应为 \(version)")
        }
    }

    private static func checkSignature(_ app: URL, requirement text: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.signature("读不出签名")
        }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess, let req else {
            throw UpdateError.signature("requirement")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, req, &error)
        guard status == errSecSuccess else {
            _ = error?.takeRetainedValue()
            let why = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
            throw UpdateError.signature(why)
        }
    }

    /// 当前进程是不是正式版：用本项目的 Developer ID 签名。Xcode 构建的不是，不会替换自己
    static var isReleaseBuild: Bool {
        var me: SecCode?
        var req: SecRequirement?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecRequirementCreateWithString(developerID as CFString, [], &req) == errSecSuccess, let req else { return false }
        return SecCodeCheckValidity(me, [], req) == errSecSuccess
    }

    // MARK: - 安装

    /// `installed` 这个位置的 App 为什么没法替换自己；能替换时是 nil
    static func blocker(for installed: URL) -> String? {
        let path = installed.path
        let readOnly = (try? installed.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
        if path.contains("/AppTranslocation/") || readOnly {
            return "岛民正从磁盘映像或隔离位置运行。先把它拖进「应用程序」文件夹，之后它就能自己更新。"
        }
        let parent = installed.deletingLastPathComponent().path
        if access(parent, W_OK) != 0 || access(path, W_OK) != 0 {
            return "没有权限替换 \(path)。请从 GitHub 下载新版本手动安装。"
        }
        return nil
    }

    /// 把 `new` 放到 `installed` 的位置：两个文件夹一次改名对调，任何时刻那里都有一个完整的 App。
    /// 对调到 `new` 位置上的旧版本随后删掉
    static func swap(_ new: URL, into installed: URL) throws {
        guard renamex_np(new.path, installed.path, UInt32(RENAME_SWAP)) == 0 else {
            let why = String(cString: strerror(errno))
            throw UpdateError.cannotReplace("替换 \(installed.path) 失败：\(why)")
        }
        try? FileManager.default.removeItem(at: new)
    }

    /// 解压、校验，装到 `installed` 上
    static func install(_ archive: URL, version: AppVersion, over installed: URL) throws {
        if let why = blocker(for: installed) { throw UpdateError.cannotReplace(why) }
        // 下载之后可能有人手动放了更新的版本上去
        if let onDisk = installedVersion(installed), version <= onDisk {
            throw UpdateError.cannotReplace("\(installed.path) 已经是 \(onDisk) 版。")
        }
        let app = try unpack(archive, version: version, near: installed)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        try swap(app, into: installed)
    }

    private static func installedVersion(_ app: URL) -> AppVersion? {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        return (info?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
    }

    /// 等本进程退出后打开 `app`。等待的 shell 跑在自己的会话里，App 的 launchd 任务结束时它不会被一起带走
    static func relaunch(_ app: URL) throws {
        let script = #"pid=$1; app=$2; i=0; while kill -0 "$pid" 2>/dev/null && [ $i -lt 600 ]; do sleep 0.1; i=$((i+1)); done; exec /usr/bin/open "$app""#
        _ = try spawnDetached(["/bin/sh", "-c", script, "sh", String(getpid()), app.path])
    }

    /// 在新会话里启动 `argv`，标准输入输出接 /dev/null，不继承其他文件描述符
    private static func spawnDetached(_ argv: [String]) throws -> pid_t {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var files: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&files)
        defer { posix_spawn_file_actions_destroy(&files) }
        posix_spawn_file_actions_addopen(&files, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&files, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&files, 2, "/dev/null", O_WRONLY, 0)
        let cargs = argv.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &files, &attr, cargs, environ)
        guard rc == 0 else {
            throw UpdateError.cannotReplace("没能重新打开：\(String(cString: strerror(rc)))")
        }
        return pid
    }

    // MARK: - 清理

    /// 删掉不比 `current` 新的已下载压缩包
    static func pruneDownloads(in dir: URL, keepingNewerThan current: AppVersion) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names {
            let v = name.hasPrefix(archivePrefix) && name.hasSuffix(".zip")
                ? AppVersion(String(name.dropFirst(archivePrefix.count).dropLast(".zip".count))) : nil
            if v.map({ $0 <= current }) ?? true { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
        }
    }
}
