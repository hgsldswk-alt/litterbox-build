import Foundation

enum SharedLocation {
    static let group = "group.com.hgsldswk.litterboxtracker"
    static var root: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) }
}

struct WidgetSnapshot: Codable {
    struct Box: Codable, Identifiable {
        let id: UUID
        let name: String
        let scoop: Date?
        let wash: Date?
        let scoopDue: Date?
        let washDue: Date?
    }

    let boxes: [Box]
    let lockBoxID: UUID?
    let showBoxName: Bool
    let pro: Bool
    let expires: Date?
    let updatedAt: Date
    static let fileName = "WidgetSnapshot.json"

    static func load() -> Self? {
        guard let url = SharedLocation.root?.appendingPathComponent(fileName),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
