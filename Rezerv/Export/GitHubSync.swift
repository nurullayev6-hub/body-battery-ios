import Foundation
import Security

/// Автоматическая отправка данных в ЗАКРЫТЫЙ репозиторий пользователя на GitHub.
/// Токен хранится в Связке ключей iPhone и передаётся только на api.github.com.
enum GitHubSync {
    static let repoKey = "syncRepo"
    static let autoKey = "syncAuto"
    static let lastKey = "syncLast"
    static let statusKey = "syncStatus"
    private static let tokenAccount = "github-token"
    static let minInterval: TimeInterval = 30 * 60

    static var repo: String {
        get { UserDefaults.standard.string(forKey: repoKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: repoKey) }
    }
    static var auto: Bool {
        get { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }
    static var lastSync: Date? { UserDefaults.standard.object(forKey: lastKey) as? Date }
    static var status: String { UserDefaults.standard.string(forKey: statusKey) ?? "" }
    static var isConfigured: Bool { repo.contains("/") && token != nil }

    // MARK: Токен в Связке ключей

    static var token: String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: tokenAccount,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let d = item as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func setToken(_ t: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: tokenAccount]
        SecItemDelete(base as CFDictionary)
        guard let t = t?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(t.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    // MARK: Отправка

    enum SyncError: LocalizedError {
        case notConfigured, http(Int, String), publicRepo
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Не указан репозиторий или токен"
            case .publicRepo: return "Репозиторий открытый. Для данных о здоровье нужен закрытый (Private) репозиторий"
            case .http(let c, let m): return "GitHub ответил \(c): \(m)"
            }
        }
    }

    private static func request(_ path: String, method: String = "GET", body: Data? = nil) async throws -> (Data, Int) {
        guard let token, repo.contains("/") else { throw SyncError.notConfigured }
        var r = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)\(path)")!)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.setValue("Rezerv-iOS", forHTTPHeaderField: "User-Agent")
        if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        r.timeoutInterval = 25
        let (d, resp) = try await URLSession.shared.data(for: r)
        return (d, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Проверка: репозиторий существует, закрыт, и токен может в него писать
    static func check() async throws {
        let (d, code) = try await request("")
        guard code == 200 else { throw SyncError.http(code, message(d)) }
        let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        if (j?["private"] as? Bool) != true { throw SyncError.publicRepo }
    }

    private static func message(_ d: Data) -> String {
        ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["message"] as? String ?? ""
    }

    static func put(path: String, data: Data, message msg: String) async throws {
        let p = "/contents/" + path
        var sha: String? = nil
        let (d0, c0) = try await request(p)
        if c0 == 200, let j = (try? JSONSerialization.jsonObject(with: d0)) as? [String: Any] { sha = j["sha"] as? String }
        var body: [String: Any] = ["message": msg, "content": data.base64EncodedString()]
        if let sha { body["sha"] = sha }
        let (d, code) = try await request(p, method: "PUT", body: try JSONSerialization.data(withJSONObject: body))
        guard code == 200 || code == 201 else { throw SyncError.http(code, message(d)) }
    }

    /// Отправляет latest.json (7 дней) и файлы за вчера и сегодня. `force` игнорирует интервал.
    @MainActor
    static func sync(_ m: AppModel, force: Bool = false) async {
        guard isConfigured, force || auto else { return }
        if !force, let last = lastSync, Date().timeIntervalSince(last) < minInterval { return }
        guard let inp = AnalysisExport.input(m),
              let all = AnalysisExport.jsonData(inp, days: 1...7),
              let yesterday = AnalysisExport.jsonData(inp, days: 6...6),
              let today = AnalysisExport.jsonData(inp, days: 7...7) else { return }
        do {
            try await check()
            let y = AnalysisExport.dayKey(inp.dayDate(6)), t = AnalysisExport.dayKey(inp.dayDate(7))
            try await put(path: "rezerv/latest.json", data: all, message: "Резерв: данные за 7 дней")
            try await put(path: "rezerv/days/\(y).json", data: yesterday, message: "Резерв: \(y)")
            try await put(path: "rezerv/days/\(t).json", data: today, message: "Резерв: \(t)")
            setStatus("Отправлено", ok: true)
        } catch {
            setStatus("Ошибка: \(error.localizedDescription)", ok: false)
        }
        m.objectWillChange.send()
    }

    private static func setStatus(_ s: String, ok: Bool) {
        if ok { UserDefaults.standard.set(Date(), forKey: lastKey) }
        UserDefaults.standard.set(s, forKey: statusKey)
    }

    /// Разовая выгрузка истории: по одному файлу на день за последние `weeks` недель.
    @MainActor
    static func backfill(_ m: AppModel, weeks: Int = 13, progress: @escaping (String) -> Void) async {
        guard isConfigured else { progress("Сначала укажите репозиторий и токен"); return }
        let hs = HealthService.shared
        let cache = WorkoutCache()
        let today0 = Calendar.current.startOfDay(for: Date())
        var sent = 0
        do {
            try await check()
            for w in 1...weeks {
                progress("Неделя \(w) из \(weeks)…")
                // окно заканчивается за секунду до полуночи: дни 1…7 — полные прошедшие сутки
                let end = Calendar.current.date(byAdding: .day, value: -7 * (w - 1), to: today0)!.addingTimeInterval(-1)
                let raw = try await hs.loadWeek(now: end, cache: cache)
                let inp = AnalysisExport.Input.compute(raw: raw, profile: m.profile, endMinute: raw.minute(end) + 1)
                for k in 1...7 {
                    guard let d = AnalysisExport.jsonData(inp, days: k...k) else { continue }
                    let key = AnalysisExport.dayKey(inp.dayDate(k))
                    try await put(path: "rezerv/days/\(key).json", data: d, message: "Резерв: история \(key)")
                    sent += 1
                }
            }
            progress("Готово: отправлено дней \(sent)")
            setStatus("История отправлена (\(sent) дн.)", ok: true)
        } catch {
            progress("Ошибка: \(error.localizedDescription)")
            setStatus("Ошибка истории: \(error.localizedDescription)", ok: false)
        }
        m.objectWillChange.send()
    }
}
