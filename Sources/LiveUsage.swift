// Live plan usage, straight from claude.ai, for every profile.
//
// Claude Desktop only saves a usage sample to disk now and then (often hours
// apart), so plan-usage-history.json lags behind the app's own usage panel.
// The panel asks claude.ai each time; this does the same, signed in as each
// profile:
//
//   1. Read the "Claude Safe Storage" password from the Keychain (macOS asks
//      once; choose Always Allow). Every profile is the same Electron app, so
//      one key opens all of them.
//   2. Decrypt that profile's claude.ai `sessionKey` and `lastActiveOrg`
//      cookies (Chromium's v10 format: AES-128-CBC, PBKDF2 "saltysalt").
//   3. GET https://claude.ai/api/organizations/<org>/usage with them.
//
// The key and the cookies stay in memory. They are never written to disk or
// logged, and are only ever sent to claude.ai. The endpoint is not a public,
// documented API, so any failure just falls back to the saved sample.

import Foundation
import Security
import CommonCrypto
import SQLite3

/// Live results and the last error, by profile data dir. Main thread only.
var liveUsage: [String: Usage] = [:]
var liveErrors: [String: String] = [:]

enum LiveUsageError: Error, CustomStringConvertible {
    case keychain(OSStatus)
    case notSignedIn
    case unreadable
    case http(Int)
    case unexpectedAnswer

    var description: String {
        switch self {
        case .keychain(let status):
            return status == errSecUserCanceled || status == errSecAuthFailed
                ? "Keychain access was not allowed" : "Keychain error \(status)"
        case .notSignedIn: return "Not signed in"
        case .unreadable: return "Couldn't read this profile's sign-in"
        case .http(let code) where code == 401 || code == 403: return "claude.ai refused the sign-in (\(code))"
        case .http(let code): return "claude.ai answered \(code)"
        case .unexpectedAnswer: return "Unexpected answer from claude.ai"
        }
    }
}

// MARK: - Keychain key

private let keyLock = NSLock()
private var cachedKey: [UInt8]?
/// Set when the Keychain said no, so a refresh doesn't ask again at once.
/// Cleared by retryKeychainAccess() (the header's refresh button).
private var keychainRefusal: OSStatus?

func retryKeychainAccess() {
    keyLock.lock(); keychainRefusal = nil; keyLock.unlock()
}

/// The AES key Electron derives from the Keychain password. Memory only.
private func safeStorageKey() throws -> [UInt8] {
    keyLock.lock()
    defer { keyLock.unlock() }
    if let cachedKey { return cachedKey }
    if let keychainRefusal { throw LiveUsageError.keychain(keychainRefusal) }

    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Claude Safe Storage",
        kSecAttrAccount as String: "Claude Key",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let password = item as? Data else {
        keychainRefusal = status
        throw LiveUsageError.keychain(status)
    }

    var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
    let salt = Array("saltysalt".utf8)
    let rc = password.withUnsafeBytes { pw in
        CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                             pw.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                             salt, salt.count,
                             CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                             &key, key.count)
    }
    guard rc == kCCSuccess else { throw LiveUsageError.unreadable }
    cachedKey = key
    return key
}

// MARK: - Cookies

/// Chromium "v10" cookie: AES-128-CBC with a 16-space IV. Cookie databases at
/// schema version 24 and later put SHA-256(host) in front of the value.
private func decryptCookie(_ blob: Data, key: [UInt8], hasHostDigest: Bool) throws -> String {
    guard blob.count > 3, blob.prefix(3) == Data("v10".utf8) else { throw LiveUsageError.unreadable }
    let cipher = [UInt8](blob.dropFirst(3))
    let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
    var plain = [UInt8](repeating: 0, count: cipher.count + kCCBlockSizeAES128)
    var length = 0
    let rc = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                     key, key.count, iv, cipher, cipher.count, &plain, plain.count, &length)
    guard rc == kCCSuccess else { throw LiveUsageError.unreadable }
    var value = plain.prefix(length)
    if hasHostDigest {
        guard value.count >= 32 else { throw LiveUsageError.unreadable }
        value = value.dropFirst(32)
    }
    guard let text = String(bytes: value, encoding: .utf8) else { throw LiveUsageError.unreadable }
    return text
}

/// The claude.ai sign-in (sessionKey) and the organisation the app last used.
private func claudeCookies(in dataDir: String, key: [UInt8]) throws -> (session: String, org: String) {
    guard let path = (dataDir + "/Cookies").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
    else { throw LiveUsageError.unreadable }
    var db: OpaquePointer?
    // Read-only and without locking, so a running Claude is never blocked.
    guard sqlite3_open_v2("file:\(path)?mode=ro&nolock=1", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK
    else { sqlite3_close(db); throw LiveUsageError.notSignedIn }
    defer { sqlite3_close(db) }

    var stmt: OpaquePointer?
    var version = 0
    if sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = 'version'", -1, &stmt, nil) == SQLITE_OK,
       sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) {
        version = Int(String(cString: text)) ?? 0
    }
    sqlite3_finalize(stmt)

    let sql = """
        SELECT name, encrypted_value FROM cookies
        WHERE host_key = '.claude.ai' AND name IN ('sessionKey', 'lastActiveOrg')
        """
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw LiveUsageError.notSignedIn }
    defer { sqlite3_finalize(stmt) }
    var values: [String: String] = [:]
    while sqlite3_step(stmt) == SQLITE_ROW {
        guard let name = sqlite3_column_text(stmt, 0), let bytes = sqlite3_column_blob(stmt, 1) else { continue }
        let blob = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 1)))
        values[String(cString: name)] = try decryptCookie(blob, key: key, hasHostDigest: version >= 24)
    }
    guard let session = values["sessionKey"], let org = values["lastActiveOrg"] else {
        throw LiveUsageError.notSignedIn
    }
    return (session, org)
}

// MARK: - claude.ai

/// No cookie jar and no disk cache: nothing from these requests is stored.
private let liveSession = URLSession(configuration: .ephemeral)

/// "2026-11-06T15:10:00.123456+00:00" (the fraction length varies).
private func parseDate(_ text: String?) -> Date? {
    guard let text else { return nil }
    let trimmed = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    return ISO8601DateFormatter().date(from: trimmed)
}

func fetchLiveUsage(dataDir: String) async throws -> Usage {
    let cookies = try claudeCookies(in: dataDir, key: try safeStorageKey())
    // The org id goes into the URL, so accept nothing but a UUID.
    guard cookies.org.range(of: #"^[0-9a-fA-F-]{36}$"#, options: .regularExpression) != nil,
          !cookies.session.contains(where: { $0 == ";" || $0.isNewline }),
          let url = URL(string: "https://claude.ai/api/organizations/\(cookies.org)/usage")
    else { throw LiveUsageError.unreadable }

    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
    request.httpShouldHandleCookies = false
    request.setValue("sessionKey=\(cookies.session); lastActiveOrg=\(cookies.org)", forHTTPHeaderField: "Cookie")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let (data, response) = try await liveSession.data(for: request)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else { throw LiveUsageError.http(code) }
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { throw LiveUsageError.unexpectedAnswer }

    /// {"utilization": 12, "resets_at": "..."}; null when nothing is used in that window.
    func window(_ name: String) -> (percent: Int, resets: Date?)? {
        guard let value = json[name] else { return nil }
        guard let w = value as? [String: Any] else { return (0, nil) }
        let used = (w["utilization"] as? NSNumber)?.doubleValue ?? 0
        return (Int(used.rounded()), parseDate(w["resets_at"] as? String))
    }
    let fiveHour = window("five_hour")
    let week = window("seven_day")
    guard fiveHour != nil || week != nil else { throw LiveUsageError.unexpectedAnswer }
    return Usage(fiveHour: fiveHour?.percent ?? 0, week: week?.percent ?? 0, updated: Date(),
                 fiveHourResets: fiveHour?.resets, weekResets: week?.resets, isLive: true)
}

/// Fetch every profile at once, store the results on the main thread, then call `done`.
func refreshLiveUsage(dataDirs: [String], done: @escaping () -> Void) {
    Task.detached {
        await withTaskGroup(of: (String, Result<Usage, Error>).self) { group in
            for dir in dataDirs {
                group.addTask {
                    do { return (dir, .success(try await fetchLiveUsage(dataDir: dir))) }
                    catch { return (dir, .failure(error)) }
                }
            }
            for await (dir, result) in group {
                await MainActor.run {
                    switch result {
                    case .success(let usage):
                        liveUsage[dir] = usage
                        liveErrors[dir] = nil
                    case .failure(let error):
                        liveErrors[dir] = (error as? LiveUsageError)?.description ?? error.localizedDescription
                    }
                }
            }
        }
        await MainActor.run { done() }
    }
}
