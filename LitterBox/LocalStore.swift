import Foundation
import Security
import SwiftData

@Model
final class StoredHousehold {
    var data: Data
    init(data: Data) { self.data = data }
}

actor LocalStore {
    private var container: ModelContainer?
    private var context: ModelContext?
    private var row: StoredHousehold?
    private var widgetURL: URL?
    private var memory: LocalData?
    private let test = Launch.uiTesting

    private var testURL: URL? {
        guard let value = ProcessInfo.processInfo.environment["LBT_TEST_SESSION"],
              let id = UUID(uuidString: value) else { return nil }
        return FileManager.default.temporaryDirectory.appendingPathComponent("LitterBox-test-" + id.uuidString + ".json")
    }

    func open(at now: Date) throws -> LocalData {
        if let memory { return memory }
        if test {
            if let url = testURL, FileManager.default.fileExists(atPath: url.path) {
                if Launch.has("-reset") { try FileManager.default.removeItem(at: url) }
                else {
                    let data = try JSONDecoder().decode(LocalData.self, from: Data(contentsOf: url))
                    memory = data
                    return data
                }
            }
            let data = Launch.has("-sample") || Launch.has("-expired") ? Demo.data(at: now) : LocalData(home: .initial(at: now))
            try save(data)
            return data
        }
        guard let root = SharedLocation.root else { throw CocoaError(.fileNoSuchFile) }
        let schema = Schema([StoredHousehold.self])
        let config = ModelConfiguration(schema: schema, url: root.appendingPathComponent("LitterBox.store"),
                                        cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        self.container = container
        self.context = context
        widgetURL = root.appendingPathComponent(WidgetSnapshot.fileName)

        let data: LocalData
        if let stored = try context.fetch(FetchDescriptor<StoredHousehold>()).first {
            data = try JSONDecoder().decode(LocalData.self, from: stored.data)
            row = stored
        } else {
            data = LocalData(home: .initial(at: now))
            try save(data)
        }
        return data
    }

    func save(_ data: LocalData) throws {
        if test {
            if let url = testURL { try JSONEncoder().encode(data).write(to: url, options: .atomic) }
            memory = data
            return
        }
        guard let context else { throw CocoaError(.fileNoSuchFile) }
        let bytes = try JSONEncoder().encode(data)
        let stored = row ?? StoredHousehold(data: bytes)
        if row == nil { context.insert(stored) }
        stored.data = bytes
        do {
            try context.save()
            row = stored
        } catch {
            context.rollback()
            throw error
        }
    }

    func widget(home: Household, pro: Bool, expires: Date?, at timestamp: Date) throws {
        guard let widgetURL else { return }
        let snapshot = WidgetSnapshot(
            boxes: home.boxes.filter { home.writable($0, pro: pro) }.sorted { home.urgency($0) < home.urgency($1) }.map { box in
                .init(id: box.id, name: box.name, scoop: home.latest(box.id, .scoop)?.at,
                      wash: home.latest(box.id, .wash)?.at, scoopDue: home.due(box, .scoop), washDue: home.due(box, .wash))
            },
            lockBoxID: home.lockBoxID, showBoxName: home.showBoxName, pro: pro, expires: expires, updatedAt: timestamp)
        try JSONEncoder().encode(snapshot).write(to: widgetURL, options: [.atomic])
    }
}

actor SecureEntitlement {
    private let base: [String: String] = [
        kSecClass as String: kSecClassGenericPassword as String,
        kSecAttrService as String: "com.hgsldswk.litterboxtracker",
        kSecAttrAccount as String: "entitlement.v1"
    ]
    private var cached: Entitlement?

    func open(at now: Date) throws -> Entitlement {
        if let cached { return cached }
        if Launch.uiTesting {
            let start = Launch.has("-expired") ? now.addingTimeInterval(-31 * 86_400) : now
            let result = Entitlement(firstOpen: start, proStartedAt: start, purchasedPro: Launch.has("-owned"))
            cached = result
            return result
        }
        var query: [String: Any] = base
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        var result: Entitlement
        switch status {
        case errSecSuccess:
            guard let bytes = item as? Data else { throw CocoaError(.coderReadCorrupt) }
            result = try JSONDecoder().decode(Entitlement.self, from: bytes)
        case errSecItemNotFound:
            result = Entitlement(firstOpen: now)
        default:
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        result.observe(now)
        try save(result)
        return result
    }

    func save(_ value: Entitlement) throws {
        if Launch.uiTesting { cached = value; return }
        let data = try JSONEncoder().encode(value)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var query: [String: Any] = base
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        cached = value
    }

    func reconcile(at now: Date, purchased: Bool? = nil, trial: Date? = nil) throws -> Entitlement {
        var value = try open(at: now)
        value.observe(now)
        if let purchased { value.purchasedPro = purchased }
        if let trial { value.applyTrialReceipt(trial) }
        try save(value)
        return value
    }
}
