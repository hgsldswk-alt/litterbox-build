import Compression
import Foundation

enum TransferError: Error {
    case invalid, tooLarge, wrongHousehold, stalePreview
}

struct FamilyUpdate: Codable {
    var version = 1
    let householdID: UUID
    let sentAt: Date
    let sender: HouseholdMember
    let timeZone: String
    let boxes: [LitterBox]
    let events: [CareEvent]
    let revoked: [UUID]

    init(_ home: Household, at now: Date) {
        householdID = home.id
        sentAt = now
        sender = home.member
        timeZone = home.timeZone
        boxes = home.boxes.map { box in
            var copy = box
            copy.pauses = nil
            copy.pausedUntil = nil
            copy.isStarter = nil
            return copy
        }
        let cutoff = now.addingTimeInterval(-60 * 86_400)
        let latest = Set(boxes.flatMap { box in CareKind.allCases.compactMap { home.latest(box.id, $0)?.id } })
        events = home.events.filter { $0.at >= cutoff || latest.contains($0.id) }
        revoked = home.revoked.sorted { $0.uuidString < $1.uuidString }
    }

    private func validName(_ value: String, limit: Int, empty: Bool = false) -> Bool {
        value.count <= limit && (empty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func validate(at now: Date) throws {
        let earliest = Date(timeIntervalSince1970: 946_684_800)
        let latest = now.addingTimeInterval(600)
        func date(_ value: Date) -> Bool { value >= earliest && value <= latest }
        guard version == 1, date(sentAt), TimeZone(identifier: timeZone) != nil,
              validName(sender.name, limit: 50, empty: true),
              boxes.count <= 200, events.count <= 6000, revoked.count <= 8000 else { throw TransferError.invalid }
        let ids = Set(boxes.map(\.id))
        guard ids.count == boxes.count, Set(events.map(\.id)).count == events.count,
              Set(revoked).count == revoked.count else { throw TransferError.invalid }
        for box in boxes {
            guard validName(box.name, limit: 60), box.cats.count <= 20,
                  box.cats.allSatisfy({ validName($0.name, limit: 35) }),
                  date(box.createdAt), (box.archivedAt.map(date) ?? true),
                  box.pausedUntil == nil, box.pauses == nil, box.isStarter == nil,
                  CareKind.allCases.allSatisfy({ kind in
                      (1...8760).contains(box[kind].hours)
                          && (box[kind].enabledAt.map(date) ?? !box[kind].enabled)
                  }) else { throw TransferError.invalid }
        }
        for event in events {
            guard ids.contains(event.boxID), date(event.at), event.at <= sentAt.addingTimeInterval(600),
                  validName(event.member.name, limit: 50, empty: true),
                  event.intervalHours.map({ (1...8760).contains($0) }) ?? true else { throw TransferError.invalid }
        }
    }
}

struct FamilyPreview {
    let update: FamilyUpdate
    let groupID: UUID
    let newBoxes: [LitterBox]
    let newEvents: [CareEvent]
    let needsSeparateGroup: Bool
}

extension Household {
    func preview(_ update: FamilyUpdate, now: Date) throws -> FamilyPreview {
        try update.validate(at: now)
        let joinsNewGroup = update.householdID != id
        let separate = joinsNewGroup && !isEmpty
        let knownBoxes = joinsNewGroup ? Set<UUID>() : Set(boxes.map(\.id))
        let knownEvents = joinsNewGroup ? Set<UUID>() : Set(events.map(\.id)).union(revoked)
        let stampedRevocations = Set(update.revoked)
        return FamilyPreview(update: update, groupID: id,
            newBoxes: update.boxes.filter { !knownBoxes.contains($0.id) },
            newEvents: update.events.filter { !knownEvents.contains($0.id) && !stampedRevocations.contains($0.id) },
            needsSeparateGroup: separate)
    }

    mutating func merge(_ preview: FamilyPreview, at now: Date) throws {
        guard preview.groupID == id else { throw TransferError.stalePreview }
        let checked = try self.preview(preview.update, now: now)
        guard !checked.needsSeparateGroup else { throw TransferError.wrongHousehold }
        let update = checked.update
        if id != update.householdID {
            id = update.householdID
            timeZone = update.timeZone
            boxes = []
            freeBoxID = nil
            lockBoxID = nil
        }
        boxes.append(contentsOf: checked.newBoxes)
        let recordedIDs = Set(events.map(\.id))
        events.append(contentsOf: update.events.filter { !recordedIDs.contains($0.id) && !revoked.contains($0.id) })
        revoked.formUnion(update.revoked)
        if !members.contains(where: { $0.id == update.sender.id }) && update.sender.id != member.id { members.append(update.sender) }
        importNote = ImportNote(from: update.sender.name, at: now,
            events: Array(checked.newEvents.sorted { $0.at > $1.at }.prefix(5)))
    }
}

enum FamilyCode {
    static let prefix = "LBT1:"
    static let clipboardLimit = 4000
    static let fileLimit = 384 * 1024
    private static let jsonLimit = 256 * 1024

    static func encode(_ update: FamilyUpdate) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try encoder.encode(update)
        guard json.count <= jsonLimit else { throw TransferError.tooLarge }
        let data = try convert(json, limit: jsonLimit + 4096, encode: true)
        let check = checksum(json).map { String(format: "%02x", $0) }.joined()
        return prefix + check + "." + data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String, now: Date) throws -> FamilyUpdate {
        guard text.utf8.count <= fileLimit else { throw TransferError.tooLarge }
        let code = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.hasPrefix(prefix) else { throw TransferError.invalid }
        let parts = code.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].utf8.count == 8 else { throw TransferError.invalid }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let packed = Data(base64Encoded: b64) else { throw TransferError.invalid }
        let json = try convert(packed, limit: jsonLimit + 1, encode: false)
        guard json.count <= jsonLimit,
              checksum(json).map({ String(format: "%02x", $0) }).joined() == parts[0] else { throw TransferError.invalid }
        let update = try JSONDecoder().decode(FamilyUpdate.self, from: json)
        try update.validate(at: now)
        return update
    }

    private static func convert(_ data: Data, limit: Int, encode: Bool) throws -> Data {
        guard !data.isEmpty else { throw TransferError.invalid }
        var output = Data(count: limit)
        let count = output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
            data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                let dst = destination.bindMemory(to: UInt8.self).baseAddress!
                let src = source.bindMemory(to: UInt8.self).baseAddress!
                return encode
                    ? compression_encode_buffer(dst, limit, src, data.count, nil, COMPRESSION_ZLIB)
                    : compression_decode_buffer(dst, limit, src, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard count > 0, count < limit else { throw TransferError.invalid }
        return Data(output.prefix(count))
    }

    private static func checksum(_ data: Data) -> [UInt8] {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        return [UInt8(b >> 8), UInt8(b & 255), UInt8(a >> 8), UInt8(a & 255)]
    }
}
