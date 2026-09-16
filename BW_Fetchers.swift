import Cocoa
import SwiftUI
import WebKit

// MARK: - Live Service Fetchers

enum KeychainTokenHelper {
    private static var cachedToken: String?
    private static let lock = NSLock()
    private static var clientId: String {
        let b: [UInt8] = [109, 108, 107, 109, 108, 108, 106, 108, 106, 108, 105, 101, 109, 113, 40, 49, 52, 47, 47, 53, 50, 110, 52, 110, 109, 48, 63, 46, 57, 110, 111, 105, 42, 40, 51, 48, 51, 54, 52, 104, 59, 104, 108, 111, 57, 44, 114, 61, 44, 44, 47, 114, 59, 51, 51, 59, 48, 57, 41, 47, 57, 46, 63, 51, 50, 40, 57, 50, 40, 114, 63, 51, 49]
        return String(bytes: b.map { $0 ^ 0x5C }, encoding: .utf8) ?? ""
    }
    private static var clientSecret: String {
        let b: [UInt8] = [27, 19, 31, 15, 12, 4, 113, 23, 105, 100, 26, 11, 14, 104, 100, 106, 16, 56, 16, 22, 109, 49, 16, 30, 100, 47, 4, 31, 104, 38, 106, 45, 24, 29, 58]
        return String(bytes: b.map { $0 ^ 0x5C }, encoding: .utf8) ?? ""
    }

    struct StoredCredentials {
        var accessToken: String?
        var refreshToken: String?
        var expiry: Date?
        var fullObject: [String: Any]?
    }

    static func getStoredToken() -> String? {
        lock.lock()
        if let cachedToken, !cachedToken.isEmpty {
            let hit = cachedToken
            lock.unlock()
            return hit
        }
        lock.unlock()

        let creds = loadCredentials()
        if let token = creds.accessToken, !token.isEmpty {
            lock.lock()
            cachedToken = token
            lock.unlock()
            return token
        }
        return nil
    }

    static func invalidate() {
        lock.lock()
        cachedToken = nil
        lock.unlock()
    }

    static func refreshAccessToken(completion: @escaping (String?) -> Void) {
        let creds = loadCredentials()
        guard let refreshToken = creds.refreshToken, !refreshToken.isEmpty else {
            completion(nil)
            return
        }

        let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("Antigravity/1.0", forHTTPHeaderField: "User-Agent")

        var comp = URLComponents()
        comp.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken)
        ]
        req.httpBody = comp.percentEncodedQuery?.data(using: .utf8)

        URLSession.shared.dataTask(with: req) { data, resp, err in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newAccessToken = json["access_token"] as? String, !newAccessToken.isEmpty else {
                completion(nil)
                return
            }

            lock.lock()
            cachedToken = newAccessToken
            lock.unlock()

            persistRefreshedToken(newAccessToken: newAccessToken, creds: creds)
            completion(newAccessToken)
        }.resume()
    }

    private static func persistRefreshedToken(newAccessToken: String, creds: StoredCredentials) {
        if var fullObj = creds.fullObject {
            if var tokenDict = fullObj["token"] as? [String: Any] {
                tokenDict["access_token"] = newAccessToken
                let expiryDate = Date().addingTimeInterval(3500)
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                tokenDict["expiry"] = iso.string(from: expiryDate)
                fullObj["token"] = tokenDict
            } else {
                fullObj["access_token"] = newAccessToken
            }
            if let data = try? JSONSerialization.data(withJSONObject: fullObj, options: []),
               let jsonString = String(data: data, encoding: .utf8) {
                saveAccessToken(jsonString)
                return
            }
        }
        saveAccessToken(newAccessToken)
    }

    static func saveAccessToken(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        invalidate()
        let payload: String
        if trimmed.hasPrefix("{") {
            payload = trimmed
        } else {
            let escaped = trimmed
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            payload = "{\"access_token\":\"\(escaped)\"}"
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = [
            "add-generic-password", "-U",
            "-s", "gemini",
            "-a", "antigravity",
            "-w", payload
        ]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()

        lock.lock()
        cachedToken = loadCredentials().accessToken
        lock.unlock()
    }

    static func loadCredentials() -> StoredCredentials {
        if let kc = readFromKeychain() {
            return kc
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token"),
            home.appendingPathComponent(".gemini/oauth_creds.json"),
            home.appendingPathComponent(".config/antigravity/oauth_creds.json"),
            home.appendingPathComponent(".config/antigravity-cli/antigravity-oauth-token")
        ]
        for url in candidates {
            if let data = try? Data(contentsOf: url),
               let creds = parseCredentials(from: data) {
                return creds
            }
        }
        return StoredCredentials(accessToken: nil, refreshToken: nil, expiry: nil, fullObject: nil)
    }

    private static func parseCredentials(from data: Data) -> StoredCredentials? {
        guard var str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty else {
            return nil
        }
        if str.hasPrefix("go-keyring-base64:") {
            let b64 = String(str.dropFirst("go-keyring-base64:".count))
            if let decodedData = Data(base64Encoded: b64),
               let decoded = String(data: decodedData, encoding: .utf8) {
                str = decoded
            }
        }
        guard let jsonData = str.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            if !str.hasPrefix("{") && str.count > 20 {
                return StoredCredentials(accessToken: str, refreshToken: nil, expiry: nil, fullObject: nil)
            }
            return nil
        }
        let tokenObj = (obj["token"] as? [String: Any]) ?? obj
        let access = tokenObj["access_token"] as? String
        let refresh = tokenObj["refresh_token"] as? String
        return StoredCredentials(accessToken: access, refreshToken: refresh, expiry: nil, fullObject: obj)
    }

    private static func readFromKeychain() -> StoredCredentials? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard !data.isEmpty else { return nil }
            return parseCredentials(from: data)
        } catch {
            return nil
        }
    }
}

enum LiveServiceFetcher {
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 15
        return URLSession(configuration: cfg)
    }()

    static func fetchEnabled(_ enabled: Set<WidgetCardID>, completion: @escaping ([ServiceKind: FetchOutcome]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var outcomes: [ServiceKind: FetchOutcome] = [:]

        func setOutcome(_ kind: ServiceKind, _ outcome: FetchOutcome) {
            lock.lock()
            outcomes[kind] = outcome
            lock.unlock()
        }

        let wantGoogle = enabled.contains(.agy) || enabled.contains(.claudeGPT)
        if wantGoogle {
            group.enter()
            fetchAGY { outcome in
                if enabled.contains(.agy) { setOutcome(.agy, outcome) }
                if enabled.contains(.claudeGPT) { setOutcome(.claudeGPT, outcome) }
                group.leave()
            }
        }

        if enabled.contains(.grok) {
            group.enter()
            fetchGrok { outcome in
                setOutcome(.grok, outcome)
                group.leave()
            }
        }

        if enabled.contains(.grokBot) {
            group.enter()
            fetchGrokBot { outcome in
                setOutcome(.grokBot, outcome)
                group.leave()
            }
        }

        if enabled.contains(.chatGPT) {
            group.enter()
            fetchChatGPT { outcome in
                setOutcome(.chatGPT, outcome)
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(outcomes)
        }
    }

    private static let agyEndpoints = [
        "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
        "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
    ]

    private static func collectCookies(domains: [String], completion: @escaping ([String: String]) -> Void) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            var dict = BinaryCookiesReader.getCookies(domains: domains)
            for c in cookies where domains.contains(where: { c.domain.contains($0) }) {
                dict[c.name] = c.value
            }
            completion(dict)
        }
    }

    static func fetchAGY(completion: ((FetchOutcome) -> Void)? = nil) {
        func cookiePath() {
            collectCookies(domains: ["antigravity.google", "google.com", "cloudcode"]) { dict in
                if dict.isEmpty {
                    completion?(.needsLogin)
                    return
                }
                let header = dict.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
                fetchAGYWithCookies(cookieHeader: header, index: 0, completion: completion)
            }
        }

        if let token = KeychainTokenHelper.getStoredToken(), !token.isEmpty {
            fetchAGYWithToken(token: token, index: 0) { outcome in
                if outcome == .needsLogin {
                    KeychainTokenHelper.refreshAccessToken { refreshed in
                        if let refreshed, !refreshed.isEmpty {
                            fetchAGYWithToken(token: refreshed, index: 0, allowRetry: false, completion: completion)
                        } else {
                            cookiePath()
                        }
                    }
                } else {
                    completion?(outcome)
                }
            }
            return
        }

        KeychainTokenHelper.refreshAccessToken { refreshed in
            if let refreshed, !refreshed.isEmpty {
                fetchAGYWithToken(token: refreshed, index: 0, allowRetry: false, completion: completion)
            } else {
                cookiePath()
            }
        }
    }

    private static func agyFailOutcome(status: Int, error: Error?) -> FetchOutcome {
        if status == 401 || status == 403 { return .needsLogin }
        if error != nil { return .failed("Network error") }
        if status == 0 { return .failed("Couldn't refresh") }
        return .failed("Couldn't refresh (\(status))")
    }

    private static func fetchAGYWithToken(token: String, index: Int = 0, allowRetry: Bool = true, completion: ((FetchOutcome) -> Void)? = nil) {
        guard index < agyEndpoints.count, let url = URL(string: agyEndpoints[index]) else {
            completion?(.failed("Couldn't refresh"))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("Antigravity/1.0", forHTTPHeaderField: "User-Agent")
        req.httpBody = Data("{}".utf8)

        session.dataTask(with: req) { data, response, error in
            DispatchQueue.main.async {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200, let data = data, let str = String(data: data, encoding: .utf8) {
                    saveAGYRawData(str, rawData: data)
                    completion?(.success)
                    return
                }
                if status == 401 || status == 403 {
                    KeychainTokenHelper.invalidate()
                    if allowRetry {
                        KeychainTokenHelper.refreshAccessToken { refreshed in
                            if let refreshed, !refreshed.isEmpty {
                                fetchAGYWithToken(token: refreshed, index: 0, allowRetry: false, completion: completion)
                            } else {
                                completion?(.needsLogin)
                            }
                        }
                        return
                    }
                }
                if index + 1 < agyEndpoints.count {
                    fetchAGYWithToken(token: token, index: index + 1, allowRetry: allowRetry, completion: completion)
                } else {
                    completion?(agyFailOutcome(status: status, error: error))
                }
            }
        }.resume()
    }

    private static func fetchAGYWithCookies(cookieHeader: String, index: Int = 0, completion: ((FetchOutcome) -> Void)? = nil) {
        guard index < agyEndpoints.count, let url = URL(string: agyEndpoints[index]) else {
            completion?(cookieHeader.isEmpty ? .needsLogin : .failed("Couldn't refresh"))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !cookieHeader.isEmpty {
            req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        req.httpBody = Data("{}".utf8)

        session.dataTask(with: req) { data, response, error in
            DispatchQueue.main.async {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200, let data = data, let str = String(data: data, encoding: .utf8) {
                    saveAGYRawData(str, rawData: data)
                    completion?(.success)
                    return
                }
                if index + 1 < agyEndpoints.count {
                    fetchAGYWithCookies(cookieHeader: cookieHeader, index: index + 1, completion: completion)
                } else {
                    completion?(agyFailOutcome(status: status, error: error))
                }
            }
        }.resume()
    }

    private static func saveAGYRawData(_ rawString: String, rawData: Data) {
        let agyDir = serviceDir("AGYusageWidget")
        try? rawData.write(to: agyDir.appendingPathComponent("last-raw.json"), options: .atomic)

        guard let json = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any],
              let groups = json["groups"] as? [[String: Any]] else { return }

        var geminiWeekly: Double?
        var geminiReset: Double?
        var gemini5h: Double?
        var gemini5hReset: Double?
        var claudeWeekly: Double?
        var claudeReset: Double?
        var claude5h: Double?
        var claude5hReset: Double?

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFallback = ISO8601DateFormatter()

        for g in groups {
            let gName = (g["displayName"] as? String ?? "").lowercased()
            let buckets = g["buckets"] as? [[String: Any]] ?? []
            for b in buckets {
                let window = b["window"] as? String ?? ""
                let rem = (b["remainingFraction"] as? NSNumber)?.doubleValue ?? 1.0
                let used = max(0, min(100, (1.0 - rem) * 100.0))
                let rTime = b["resetTime"] as? String ?? ""
                let dTs = (iso.date(from: rTime) ?? isoFallback.date(from: rTime))?.timeIntervalSince1970

                if gName.contains("gemini") {
                    if window == "weekly" {
                        geminiWeekly = used
                        geminiReset = dTs
                    } else if window == "5h" {
                        gemini5h = used
                        gemini5hReset = dTs
                    }
                } else if gName.contains("claude") || gName.contains("gpt") {
                    if window == "weekly" {
                        claudeWeekly = used
                        claudeReset = dTs
                    } else if window == "5h" {
                        claude5h = used
                        claude5hReset = dTs
                    }
                }
            }
        }

        let nowTs = Date().timeIntervalSince1970
        let prevClaudeFromAGY = readClaudeSliceFromAGY()

        if let geminiWeekly {
            writeServiceCache(
                dir: agyDir,
                planLabel: "AGY",
                totalPercent: geminiWeekly,
                slices: [["name": "Gemini", "percent": geminiWeekly]],
                resetsAt: geminiReset,
                fiveHourPercent: gemini5h,
                fiveHourResetsAt: gemini5hReset,
                nowTs: nowTs,
                minStep: 0.003,
                maxStep: 30.0,
                prevTotalOverride: nil
            )
        }

        if let claudeWeekly {
            let claudeDir = serviceDir("ClaudeGPTUsageWidget")
            migrateLegacyClaudeDeltasIfNeeded(claudeDir: claudeDir)
            let prevClaude = readPrevTotal(in: claudeDir) ?? prevClaudeFromAGY
            writeServiceCache(
                dir: claudeDir,
                planLabel: "Claude & GPT",
                totalPercent: claudeWeekly,
                slices: [["name": "Claude & GPT", "percent": claudeWeekly]],
                resetsAt: claudeReset,
                fiveHourPercent: claude5h,
                fiveHourResetsAt: claude5hReset,
                nowTs: nowTs,
                minStep: 0.003,
                maxStep: 30.0,
                prevTotalOverride: prevClaude
            )
        }
    }

    private static func serviceDir(_ name: String) -> URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func readPrevTotal(in dir: URL) -> Double? {
        let url = dir.appendingPathComponent("last-usage.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (obj["totalPercent"] as? NSNumber)?.doubleValue
    }

    private static func readClaudeSliceFromAGY() -> Double? {
        let url = serviceDir("AGYusageWidget").appendingPathComponent("last-usage.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let slices = obj["slices"] as? [[String: Any]],
              let cl = slices.first(where: { (($0["name"] as? String) ?? "").contains("Claude") }) else { return nil }
        return (cl["percent"] as? NSNumber)?.doubleValue
    }

    private static func migrateLegacyClaudeDeltasIfNeeded(claudeDir: URL) {
        let dest = claudeDir.appendingPathComponent("session-deltas.json")
        if FileManager.default.fileExists(atPath: dest.path) { return }
        let legacy = serviceDir("AGYusageWidget").appendingPathComponent("claude-deltas.json")
        guard let data = try? Data(contentsOf: legacy),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Double]] else { return }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let converted: [[String: Any]] = list.compactMap { d in
            guard let delta = d["delta"], let ts = d["timestamp"], delta > 0.005, abs(delta) < 30 else { return nil }
            return [
                "timestamp": ts,
                "date": df.string(from: Date(timeIntervalSince1970: ts)),
                "weeklyDelta": delta,
                "weeklyTotal": 0
            ]
        }
        guard !converted.isEmpty,
              let out = try? JSONSerialization.data(withJSONObject: converted, options: [.prettyPrinted]) else { return }
        try? out.write(to: dest, options: .atomic)
    }

    private static func appendPositiveDelta(
        to deltasURL: URL,
        prevTotal: Double?,
        newTotal: Double,
        fiveHour: Double?,
        nowTs: Double,
        minStep: Double,
        maxStep: Double,
        cap: Int
    ) {
        guard let prev = prevTotal, newTotal > prev + minStep else { return }
        let diff = newTotal - prev
        // Large increases are real usage (widget was closed, or a heavy run).
        // Decreases are handled as resets in updateDailyUsage, not here.
        _ = maxStep

        var list: [[String: Any]] = []
        if let sData = try? Data(contentsOf: deltasURL),
           let existing = try? JSONSerialization.jsonObject(with: sData) as? [[String: Any]] {
            list = existing
        }
        if list.contains(where: { abs((($0["timestamp"] as? NSNumber)?.doubleValue ?? 0) - nowTs) < 1.0 }) {
            return
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var rec: [String: Any] = [
            "date": df.string(from: Date(timeIntervalSince1970: nowTs)),
            "timestamp": nowTs,
            "weeklyDelta": diff,
            "weeklyTotal": newTotal
        ]
        if let f5 = fiveHour { rec["fiveHourPercent"] = f5 }
        list.append(rec)
        let cutoff = nowTs - (366.0 * 24.0 * 3600.0)
        list = list.filter { (($0["timestamp"] as? NSNumber)?.doubleValue ?? 0) >= cutoff }
        let hardCap = max(cap, 4000)
        if list.count > hardCap { list = Array(list.suffix(hardCap)) }
        if let sOut = try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted]) {
            try? sOut.write(to: deltasURL, options: .atomic)
        }
    }

    private static func updateDailyUsage(dir: URL, totalPercent: Double, nowTs: Double, resetsAt: Double?) {
        let dailyURL = dir.appendingPathComponent("daily-usage.json")
        var map: [String: [String: Double]] = [:]
        if let data = try? Data(contentsOf: dailyURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            for (k, v) in obj {
                map[k] = [
                    "open": (v["open"] as? NSNumber)?.doubleValue ?? 0,
                    "close": (v["close"] as? NSNumber)?.doubleValue ?? 0,
                    "accumulated": (v["accumulated"] as? NSNumber)?.doubleValue ?? 0
                ]
            }
        }

        let cal = Calendar.current
        let now = Date(timeIntervalSince1970: nowTs)
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let todayKey = fmt.string(from: now)
        let yesterdayKey = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now)).map { fmt.string(from: $0) }

        var entry = map[todayKey] ?? [:]
        let yesterdayClose = yesterdayKey.flatMap { map[$0]?["close"] }

        if entry["open"] == nil {
            entry["open"] = yesterdayClose ?? totalPercent
        }

        if let prevClose = entry["close"] ?? yesterdayClose, totalPercent + 5 < prevClose {
            let resetDate = resetsAt.map { Date(timeIntervalSince1970: $0) }
            let scheduled = UsageParser.isResetWeekday(todayKey, reset: resetDate)
            if scheduled {
                entry["accumulated"] = 0
            } else {
                let drop = prevClose - totalPercent
                entry["accumulated"] = (entry["accumulated"] ?? 0) + drop
            }
            entry["open"] = totalPercent
        }

        entry["close"] = totalPercent
        if entry["accumulated"] == nil { entry["accumulated"] = 0 }
        map[todayKey] = entry

        var out: [String: [String: Double]] = [:]
        for (k, v) in map { out[k] = v }
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted]) {
            try? data.write(to: dailyURL, options: .atomic)
        }
    }

    private static func writeServiceCache(
        dir: URL,
        planLabel: String,
        totalPercent: Double,
        slices: [[String: Any]],
        resetsAt: Double?,
        fiveHourPercent: Double?,
        fiveHourResetsAt: Double?,
        nowTs: Double,
        minStep: Double,
        maxStep: Double,
        prevTotalOverride: Double?
    ) {
        let lastUsageURL = dir.appendingPathComponent("last-usage.json")
        let deltasURL = dir.appendingPathComponent("session-deltas.json")
        let prevTotal = prevTotalOverride ?? readPrevTotal(in: dir)
        appendPositiveDelta(
            to: deltasURL,
            prevTotal: prevTotal,
            newTotal: totalPercent,
            fiveHour: fiveHourPercent,
            nowTs: nowTs,
            minStep: minStep,
            maxStep: maxStep,
            cap: 4000
        )
        updateDailyUsage(dir: dir, totalPercent: totalPercent, nowTs: nowTs, resetsAt: resetsAt)

        var recentDeltas: [[String: Any]] = []
        if let sData = try? Data(contentsOf: deltasURL),
           let list = try? JSONSerialization.jsonObject(with: sData) as? [[String: Any]] {
            recentDeltas = Array(list.reversed().prefix(4)).compactMap { item in
                guard let d = (item["weeklyDelta"] as? NSNumber)?.doubleValue,
                      let ts = (item["timestamp"] as? NSNumber)?.doubleValue else { return nil }
                return ["delta": d, "timestamp": ts]
            }
        }

        var dict: [String: Any] = [
            "planLabel": planLabel,
            "fetchedAt": nowTs,
            "totalPercent": totalPercent,
            "slices": slices,
            "recentDeltas": recentDeltas
        ]
        if let r = resetsAt {
            dict["resetsAt"] = r
            dict["resetsLabel"] = UsageParser.formatReset(Date(timeIntervalSince1970: r))
        }
        if let f5 = fiveHourPercent { dict["fiveHourPercent"] = f5 }
        if let f5r = fiveHourResetsAt {
            dict["fiveHourResetsAt"] = f5r
            dict["fiveHourResetsLabel"] = UsageParser.formatResetOn(Date(timeIntervalSince1970: f5r))
        }
        if let uData = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
            try? uData.write(to: lastUsageURL, options: .atomic)
        }
    }

    static func fetchGrok(completion: ((FetchOutcome) -> Void)? = nil) {
        collectCookies(domains: ["grok.com", "x.ai"]) { dict in
            performGrokRequest(cookies: dict, completion: completion)
        }
    }

    private static func performGrokRequest(cookies: [String: String], completion: ((FetchOutcome) -> Void)? = nil) {
        guard !cookies.isEmpty, let url = URL(string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig") else {
            completion?(.needsLogin)
            return
        }
        let header = cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "connect-protocol-version")
        req.setValue("1", forHTTPHeaderField: "x-grpc-web")
        req.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue(header, forHTTPHeaderField: "Cookie")
        req.httpBody = Data([0, 0, 0, 0, 0])

        session.dataTask(with: req) { data, response, error in
            DispatchQueue.main.async {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200, let data = data, let parsed = CreditsBinary.parse(data) {
                    saveGrokData(parsed, rawData: data)
                    completion?(.success)
                    return
                }
                completion?(agyFailOutcome(status: status, error: error))
            }
        }.resume()
    }

    private static func saveGrokData(_ parsed: [String: Any], rawData: Data) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let grokDir = appSupport.appendingPathComponent("GrokUsageWidget", isDirectory: true)
        try? FileManager.default.createDirectory(at: grokDir, withIntermediateDirectories: true)
        let rawURL = grokDir.appendingPathComponent("last-raw.json")
        let dump: [String: Any] = ["status": 200, "bytes": rawData.count, "parsed": parsed]
        if let dData = try? JSONSerialization.data(withJSONObject: dump, options: [.prettyPrinted]) {
            try? dData.write(to: rawURL, options: .atomic)
        }

        let total = parsed["usagePercent"] as? Double ?? 0.0
        let products = parsed["productUsage"] as? [[String: Any]] ?? []
        var slices: [[String: Any]] = []
        for p in products {
            let pName = p["name"] as? String ?? "Product"
            let pUsed = p["usagePercent"] as? Double ?? 0.0
            slices.append(["name": pName, "percent": pUsed])
        }

        let period = parsed["currentPeriod"] as? [String: Any]
        let resetStr = period?["end"] as? String
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFallback = ISO8601DateFormatter()
        let resetDate = resetStr.flatMap { iso.date(from: $0) ?? isoFallback.date(from: $0) }
        let nowTs = Date().timeIntervalSince1970
        writeServiceCache(
            dir: grokDir,
            planLabel: "Grok",
            totalPercent: total,
            slices: slices,
            resetsAt: resetDate?.timeIntervalSince1970,
            fiveHourPercent: nil,
            fiveHourResetsAt: nil,
            nowTs: nowTs,
            minStep: 0.005,
            maxStep: 50.0,
            prevTotalOverride: nil
        )
    }

    static func fetchGrokBot(completion: ((FetchOutcome) -> Void)? = nil) {
        collectCookies(domains: ["cursor.com", "cursor.sh"]) { dict in
            performGrokBotRequest(cookies: dict, completion: completion)
        }
    }

    private static func performGrokBotRequest(cookies: [String: String], completion: ((FetchOutcome) -> Void)? = nil) {
        guard !cookies.isEmpty, let url = URL(string: "https://cursor.com/api/dashboard/get-sand-usage-status") else {
            completion?(.needsLogin)
            return
        }
        let header = cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        req.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        req.setValue("https://cursor.com", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue(header, forHTTPHeaderField: "Cookie")
        req.httpBody = Data("{}".utf8)

        session.dataTask(with: req) { data, response, error in
            DispatchQueue.main.async {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200, let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    saveGrokBotData(json, rawData: data)
                    completion?(.success)
                    return
                }
                completion?(agyFailOutcome(status: status, error: error))
            }
        }.resume()
    }

    private static func saveGrokBotData(_ json: [String: Any], rawData: Data) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let botDir = appSupport.appendingPathComponent("GrokBotUsageWidget", isDirectory: true)
        try? FileManager.default.createDirectory(at: botDir, withIntermediateDirectories: true)
        let rawURL = botDir.appendingPathComponent("last-raw.json")
        try? rawData.write(to: rawURL, options: .atomic)

        let total = json["usagePercent"] as? Double ?? 0.0
        let plan = (json["grokPlanLabel"] as? String) ?? (json["includedUsageSuperGrokPlan"] as? String) ?? "Grok Bot"
        let resetStr = json["nextResetTimestampUtc"] as? String
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFallback = ISO8601DateFormatter()
        let resetDate = resetStr.flatMap { iso.date(from: $0) ?? isoFallback.date(from: $0) }
        let nowTs = Date().timeIntervalSince1970
        writeServiceCache(
            dir: botDir,
            planLabel: plan,
            totalPercent: total,
            slices: [["name": "Grok Bot", "percent": total]],
            resetsAt: resetDate?.timeIntervalSince1970,
            fiveHourPercent: nil,
            fiveHourResetsAt: nil,
            nowTs: nowTs,
            minStep: 0.003,
            maxStep: 50.0,
            prevTotalOverride: nil
        )
    }

    private static func chatgptDeviceId() -> String {
        let key = "bigu.chatgpt.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    static func fetchChatGPT(completion: ((FetchOutcome) -> Void)? = nil) {
        collectCookies(domains: ["chatgpt.com", "openai.com"]) { dict in
            guard !dict.isEmpty else {
                completion?(.needsLogin)
                return
            }
            fetchChatGPTSession(cookies: dict, completion: completion)
        }
    }

    private static func fetchChatGPTSession(cookies: [String: String], completion: ((FetchOutcome) -> Void)? = nil) {
        guard let url = URL(string: "https://chatgpt.com/api/auth/session") else {
            completion?(.failed("Couldn't refresh"))
            return
        }
        let header = cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        req.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue(header, forHTTPHeaderField: "Cookie")
        req.setValue(chatgptDeviceId(), forHTTPHeaderField: "oai-device-id")

        session.dataTask(with: req) { data, response, error in
            DispatchQueue.main.async {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401 || status == 403 {
                    completion?(.needsLogin)
                    return
                }
                guard status == 200, let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let token = json["accessToken"] as? String, !token.isEmpty else {
                    completion?(agyFailOutcome(status: status, error: error))
                    return
                }
                fetchChatGPTUsage(token: token, cookies: cookies, completion: completion)
            }
        }.resume()
    }

    private static func fetchChatGPTUsage(token: String, cookies: [String: String], completion: ((FetchOutcome) -> Void)? = nil) {
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            completion?(.failed("Couldn't refresh"))
            return
        }
        let header = cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        req.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue(header, forHTTPHeaderField: "Cookie")
        req.setValue(chatgptDeviceId(), forHTTPHeaderField: "oai-device-id")

        session.dataTask(with: req) { data, response, error in
            DispatchQueue.main.async {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401 || status == 403 {
                    completion?(.needsLogin)
                    return
                }
                guard status == 200, let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion?(agyFailOutcome(status: status, error: error))
                    return
                }
                saveChatGPTData(json, rawData: data)
                completion?(.success)
            }
        }.resume()
    }

    private static func chatGPTWindowUsed(_ window: [String: Any]?) -> Double? {
        guard let window else { return nil }
        return (window["used_percent"] as? NSNumber)?.doubleValue
    }

    private static func chatGPTResetDate(_ window: [String: Any]?) -> Date? {
        guard let window else { return nil }
        if let epoch = (window["reset_at"] as? NSNumber)?.doubleValue, epoch > 1_000_000_000 {
            return Date(timeIntervalSince1970: epoch)
        }
        if let after = (window["reset_after_seconds"] as? NSNumber)?.doubleValue, after > 0 {
            return Date().addingTimeInterval(after)
        }
        return nil
    }

    private static func saveChatGPTData(_ json: [String: Any], rawData: Data) {
        let dir = serviceDir("ChatGPTUsageWidget")
        let rawURL = dir.appendingPathComponent("last-raw.json")
        try? rawData.write(to: rawURL, options: .atomic)

        let usage = (json["usage"] as? [String: Any]) ?? json
        let rate = usage["rate_limit"] as? [String: Any]
        let primary = rate?["primary_window"] as? [String: Any]
        let secondary = rate?["secondary_window"] as? [String: Any]
        let five = chatGPTWindowUsed(primary)
        let weekly = chatGPTWindowUsed(secondary) ?? five ?? 0
        let plan = (usage["plan_type"] as? String)?.capitalized ?? "ChatGPT"
        let nowTs = Date().timeIntervalSince1970
        writeServiceCache(
            dir: dir,
            planLabel: plan,
            totalPercent: weekly,
            slices: [["name": "ChatGPT", "percent": weekly]],
            resetsAt: chatGPTResetDate(secondary)?.timeIntervalSince1970,
            fiveHourPercent: five,
            fiveHourResetsAt: chatGPTResetDate(primary)?.timeIntervalSince1970,
            nowTs: nowTs,
            minStep: 0.003,
            maxStep: 100.0,
            prevTotalOverride: nil
        )
    }
}

// MARK: - Binary Cookies & Credits Parsing Helpers

enum BinaryCookiesReader {
    static func getCookies(domains: [String]) -> [String: String] {
        var result: [String: String] = [:]
        let paths = [
            "~/Library/HTTPStorages/com.londonvista.biguwidget.binarycookies",
            "~/Library/HTTPStorages/com.jakubsokolowski.grok-usage-widget.binarycookies",
            "~/Library/HTTPStorages/com.jakubsokolowski.grokbot-usage-widget.binarycookies",
            "~/Library/HTTPStorages/com.jakubsokolowski.BigUwidget.binarycookies",
            "~/Library/HTTPStorages/com.jakubsokolowski.agy-usage-widget.binarycookies"
        ]
        for p in paths {
            let expanded = NSString(string: p).expandingTildeInPath
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)) else { continue }
            let parsed = parseBinaryCookies(data: data)
            for (url, name, val) in parsed {
                if domains.contains(where: { url.contains($0) }) {
                    result[name] = val
                }
            }
        }
        return result
    }

    private static func parseBinaryCookies(data: Data) -> [(url: String, name: String, val: String)] {
        var cookies: [(String, String, String)] = []
        guard data.count > 12 else { return [] }
        let buf = [UInt8](data)
        guard buf[0] == 0x63, buf[1] == 0x6F, buf[2] == 0x6F, buf[3] == 0x6B else { return [] }
        let numPages = Int(UInt32(buf[4]) << 24 | UInt32(buf[5]) << 16 | UInt32(buf[6]) << 8 | UInt32(buf[7]))
        guard data.count >= 8 + numPages * 4 else { return [] }
        var pageSizes: [Int] = []
        for i in 0..<numPages {
            let off = 8 + i * 4
            let sz = Int(UInt32(buf[off]) << 24 | UInt32(buf[off+1]) << 16 | UInt32(buf[off+2]) << 8 | UInt32(buf[off+3]))
            pageSizes.append(sz)
        }
        var pos = 8 + numPages * 4
        for sz in pageSizes {
            guard pos + sz <= buf.count, sz >= 8 else { break }
            let pageData = Array(buf[pos..<(pos+sz)])
            pos += sz
            let numCookies = Int(UInt32(pageData[4]) | UInt32(pageData[5]) << 8 | UInt32(pageData[6]) << 16 | UInt32(pageData[7]) << 24)
            guard pageData.count >= 8 + numCookies * 4 else { continue }
            var cookieOffsets: [Int] = []
            for i in 0..<numCookies {
                let off = 8 + i * 4
                let cOff = Int(UInt32(pageData[off]) | UInt32(pageData[off+1]) << 8 | UInt32(pageData[off+2]) << 16 | UInt32(pageData[off+3]) << 24)
                cookieOffsets.append(cOff)
            }
            for cOff in cookieOffsets {
                guard cOff + 32 <= pageData.count else { continue }
                let urlOff = Int(UInt32(pageData[cOff+16]) | UInt32(pageData[cOff+17]) << 8 | UInt32(pageData[cOff+18]) << 16 | UInt32(pageData[cOff+19]) << 24)
                let nameOff = Int(UInt32(pageData[cOff+20]) | UInt32(pageData[cOff+21]) << 8 | UInt32(pageData[cOff+22]) << 16 | UInt32(pageData[cOff+23]) << 24)
                let valOff = Int(UInt32(pageData[cOff+28]) | UInt32(pageData[cOff+29]) << 8 | UInt32(pageData[cOff+30]) << 16 | UInt32(pageData[cOff+31]) << 24)
                let url = readCString(pageData, from: cOff + urlOff)
                let name = readCString(pageData, from: cOff + nameOff)
                let val = readCString(pageData, from: cOff + valOff)
                if !name.isEmpty {
                    cookies.append((url, name, val))
                }
            }
        }
        return cookies
    }

    private static func readCString(_ buf: [UInt8], from start: Int) -> String {
        guard start < buf.count else { return "" }
        var end = start
        while end < buf.count && buf[end] != 0 { end += 1 }
        return String(bytes: buf[start..<end], encoding: .utf8) ?? ""
    }
}

enum CreditsBinary {
    static let names = [
        0: "3rd Party", 1: "API", 2: "Grok Build", 3: "Plugins",
        4: "Chat", 5: "Imagine", 6: "Voice", 7: "App Builder"
    ]

    static func parse(_ data: Data) -> [String: Any]? {
        let buf = [UInt8](data)
        if buf.count < 10 { return nil }
        let floats = headlineFloats(buf)
        var productUsage: [[String: Any]] = []
        var periodStart: String?
        var periodEnd: String?
        var i = 0
        while i < buf.count - 7 {
            if buf[i] == 0x3A && buf[i + 1] == 0x07 && buf[i + 2] == 0x08 {
                let product = Int(buf[i + 3])
                if buf[i + 4] == 0x15 {
                    let pct = (Double(float32(buf, i + 5)) * 10).rounded() / 10
                    if pct >= 0 && pct <= 100 {
                        productUsage.append([
                            "product": product,
                            "name": names[product] ?? "Product \(product)",
                            "usagePercent": pct
                        ])
                    }
                }
            }
            i += 1
        }
        i = 0
        while i < buf.count - 4 {
            if buf[i] == 0x42 && buf[i + 1] > 0 && buf[i + 1] < 40 {
                let blockLen = Int(buf[i + 1])
                let blockStart = i + 2
                let blockEnd = blockStart + blockLen
                if blockEnd <= buf.count {
                    var pos = blockStart
                    while pos < blockEnd - 1 {
                        let tag = buf[pos]
                        pos += 1
                        let field = Int(tag >> 3)
                        let wire = tag & 0x07
                        if wire == 2 {
                            let len = Int(buf[pos])
                            pos += 1
                            if field == 2 && periodStart == nil {
                                periodStart = protoTimestamp(buf, pos, len)
                            } else if field == 3 && periodEnd == nil {
                                periodEnd = protoTimestamp(buf, pos, len)
                            }
                            pos += len
                        } else if wire == 0 {
                            pos = varint(buf, pos).next
                        } else {
                            break
                        }
                    }
                    if periodStart != nil || periodEnd != nil { break }
                }
            }
            i += 1
        }
        let productSum = productUsage.reduce(0.0) { $0 + (($1["usagePercent"] as? Double) ?? 0) }
        let unique = Array(Set(floats.map { Int($0) }))
        var usagePercent: Double?
        if unique.count == 1 {
            usagePercent = Double(unique[0])
        } else if productSum > 0 && !unique.isEmpty {
            var best = Double(unique[0])
            var bestDist = Double.infinity
            for f in unique {
                for c in [Double(f), 100 - Double(f)] {
                    let dist = abs(c - productSum)
                    if dist < bestDist {
                        bestDist = dist
                        best = c
                    }
                }
            }
            usagePercent = best
        } else if let first = unique.first {
            usagePercent = Double(first)
        }
        if let used = usagePercent, productSum > 0,
           abs((100 - used) - productSum) <= 3, abs(used - productSum) > 3 {
            usagePercent = productSum
        }
        if usagePercent == nil && productSum > 0 {
            usagePercent = min(100, productSum)
        }
        if usagePercent == nil && productUsage.isEmpty && periodStart == nil && periodEnd == nil {
            return nil
        }
        var period: [String: Any] = ["type": "weekly"]
        if let periodStart { period["start"] = periodStart }
        if let periodEnd { period["end"] = periodEnd }
        return [
            "usagePercent": usagePercent ?? 0,
            "currentPeriod": period,
            "productUsage": productUsage
        ]
    }

    private static func float32(_ buf: [UInt8], _ i: Int) -> Float {
        let le = UInt32(buf[i])
            | UInt32(buf[i + 1]) << 8
            | UInt32(buf[i + 2]) << 16
            | UInt32(buf[i + 3]) << 24
        return Float(bitPattern: le)
    }

    private static func headlineFloats(_ buf: [UInt8]) -> [Double] {
        var out: [Double] = []
        var i = 0
        while i < buf.count - 5 {
            if buf[i] == 0x0D {
                let val = Double(float32(buf, i + 1)).rounded()
                if val >= 0 && val <= 100 { out.append(val) }
            }
            i += 1
        }
        return out
    }

    private static func varint(_ buf: [UInt8], _ offset: Int) -> (value: Int, next: Int) {
        var result = 0
        var shift = 0
        var pos = offset
        while pos < buf.count {
            let byte = Int(buf[pos])
            pos += 1
            result |= (byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
        }
        return (result, pos)
    }

    private static func protoTimestamp(_ buf: [UInt8], _ offset: Int, _ length: Int) -> String? {
        let end = offset + length
        var pos = offset
        var seconds = 0
        var nanos = 0
        while pos < end {
            let tag = buf[pos]
            pos += 1
            let field = Int(tag >> 3)
            let wire = tag & 0x07
            if wire == 0 {
                let decoded = varint(buf, pos)
                pos = decoded.next
                if field == 1 { seconds = decoded.value }
                else if field == 2 { nanos = decoded.value }
            } else {
                break
            }
        }
        if seconds == 0 { return nil }
        let date = Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.string(from: date)
    }
}

