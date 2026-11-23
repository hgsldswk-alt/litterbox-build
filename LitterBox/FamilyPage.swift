import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct FamilyPage: View {
    @EnvironmentObject private var model: AppModel
    let open: (Overlay) -> Void
    @State private var name = ""
    @State private var naming = false
    @State private var editingCode = false
    @State private var code = ""
    @State private var copying = false
    @State private var status: String?
    @State private var fileImport = false
    @State private var fileExport = false
    @State private var document = TextTransfer()
    @State private var separate = false

    var body: some View {
        Page {
            if let home = model.home {
                PageHeader(title: "family.title", subtitle: L.f("family.subtitle", home.boxes.filter { !$0.archived }.count,
                    home.member.name.isEmpty ? L.t("member.me") : home.member.name)) {
                    if model.pro {
                        Action(key: "family.name", id: "family.name", compact: true) { name = home.member.name; naming = true }
                    }
                }
                if let last = home.importNote {
                    Surface {
                        Text(L.t("family.last")).font(.headline)
                        Text(L.f("family.lastBy", shortDate(last.at), member(last.from))).font(.footnote).foregroundStyle(Palette.muted)
                        ForEach(last.events) { event in row(event, boxes: home.boxes) }
                    }
                }
                if model.pro {
                    Surface {
                        Text(L.t("family.send")).font(.headline)
                        Text(L.t("family.send.help")).font(.footnote).foregroundStyle(Palette.muted)
                        Action(key: "family.copy", id: "family.copy", enabled: !copying) { export(home, asFile: false) }
                        Action(key: "family.export", id: "family.export", enabled: !copying) { export(home, asFile: true) }
                    }
                    Surface {
                        Text(L.t("family.preview")).font(.headline)
                        Action(key: "family.paste", id: "family.paste", primary: true) { paste(home) }
                        if editingCode {
                            TextField(L.t("family.code"), text: $code, axis: .vertical).font(.footnote.monospaced())
                                .lineLimit(2...6).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .accessibilityIdentifier("family.code")
                            Action(key: "family.preview", id: "family.check", enabled: !code.isEmpty) {
                                Task { await model.preview(code); if model.importPreview != nil { editingCode = false; code = "" } }
                            }
                        }
                        Action(key: "family.file", id: "family.file") { fileImport = true }
                        if let preview = model.importPreview { previewView(preview, home: home) }
                    }
                } else {
                    Surface(tinted: true) {
                        Text(L.t("family.readonly")).font(.footnote)
                        Action(key: "pro.title", id: "family.unlock") { open(.paywall) }
                    }
                }
                if let status { Text(L.t(status)).font(.footnote).accessibilityIdentifier("family.status") }
                if let others = model.data?.otherHomes, !others.isEmpty {
                    Surface {
                        Text(L.t("family.groups")).font(.headline)
                        ForEach(others, id: \.id) { other in
                            Button {
                                model.switchHousehold(other.id)
                            } label: {
                                Text(other.boxes.filter { !$0.archived }.map(\.name).joined(separator: " · "))
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityIdentifier("family.group." + other.id.uuidString)
                        }
                    }
                }
            }
        }
        .alert(L.t("family.name"), isPresented: $naming) {
            TextField(L.t("family.nickname"), text: $name)
            Button(L.t("save")) {
                let updated = bounded(name, length: 50)
                model.edit { home, _, pro in
                    guard pro else { throw EditingError.unavailable }
                    home.member.name = updated
                }
            }
            Button(L.t("cancel"), role: .cancel) {}
        }
        .confirmationDialog(L.t("family.separate.help"), isPresented: $separate, titleVisibility: .visible) {
            Button(L.t("family.separate")) { if let preview = model.importPreview { model.merge(preview, separate: true) } }
        }
        .fileImporter(isPresented: $fileImport, allowedContentTypes: [.plainText]) { result in
            Task {
                do {
                    let url = try result.get()
                    let text = try await Task.detached(priority: .userInitiated) {
                        let data = try TextTransfer.read(url, limit: FamilyCode.fileLimit)
                        guard let text = String(data: data, encoding: .utf8) else { throw TransferError.invalid }
                        return text
                    }.value
                    await model.preview(text)
                } catch { model.error = model.transferError(error) }
            }
        }
        .fileExporter(isPresented: $fileExport, document: document, contentType: .plainText, defaultFilename: "LitterBox-update") { result in
            if case .failure = result { model.error = "error.save" }
        }
    }

    @ViewBuilder
    private func previewView(_ preview: FamilyPreview, home: Household) -> some View {
        Text(L.f("family.from", member(preview.update.sender.name))).font(.subheadline.weight(.semibold))
        Text(L.f("family.counts", preview.newBoxes.count, preview.newEvents.count)).font(.footnote)
        ForEach(preview.newBoxes.prefix(5)) { box in Text(box.name).font(.footnote.weight(.semibold)) }
        ForEach(preview.newEvents.sorted { $0.at > $1.at }.prefix(5)) { event in
            row(event, boxes: home.boxes + preview.newBoxes)
        }
        if preview.needsSeparateGroup {
            Text(L.t("family.separate.help")).font(.footnote)
            Action(key: "family.separate", id: "family.separate") { separate = true }
        } else {
            Action(key: "family.merge", id: "family.merge", primary: true, enabled: model.pendingWrites == 0) { model.merge(preview) }
        }
    }

    private func member(_ name: String) -> String { name.isEmpty ? L.t("member.unknown") : name }

    private func row(_ event: CareEvent, boxes: [LitterBox]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L.f("history.event", boxes.first { $0.id == event.boxID }?.name ?? L.t("box.default"), event.kind.label))
                .font(.footnote.weight(.semibold))
            Text(L.f("history.by", shortDate(event.at), member(event.member.name))).font(.caption).foregroundStyle(Palette.muted)
        }
    }

    private func paste(_ home: Household) {
        status = nil
        Task {
            if Launch.uiTesting {
                if let input = ProcessInfo.processInfo.environment["LBT_UI_CODE"] { await model.preview(input) }
                else if Launch.has("-sample"),
                        let sample = try? FamilyCode.encode(Demo.update(from: home, now: model.now)) {
                    await model.preview(sample)
                } else { editingCode = true }
            } else if let text = UIPasteboard.general.string, !text.isEmpty {
                await model.preview(text)
                if model.importPreview == nil { editingCode = true }
            } else {
                editingCode = true
            }
        }
    }

    private func export(_ home: Household, asFile: Bool) {
        copying = true
        status = nil
        let now = Date()
        Task {
            defer { copying = false }
            do {
                let code = try await Task.detached(priority: .userInitiated) {
                    try FamilyCode.encode(FamilyUpdate(home, at: now))
                }.value
                if asFile || code.utf8.count > FamilyCode.clipboardLimit {
                    document = TextTransfer(data: Data(code.utf8))
                    if Launch.uiTesting { status = "family.fileReady" }
                    else { fileExport = true }
                } else {
                    if !Launch.uiTesting { UIPasteboard.general.string = code }
                    status = "family.copied"
                }
            } catch { model.error = model.transferError(error) }
        }
    }
}

struct TextTransfer: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText, .json]
    var data = Data()

    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw TransferError.invalid }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }

    static func read(_ url: URL, limit: Int) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard let data = try file.read(upToCount: limit + 1), data.count <= limit else { throw TransferError.tooLarge }
        return data
    }
}
