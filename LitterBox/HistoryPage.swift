import SwiftUI

struct HistoryPage: View {
    @EnvironmentObject private var model: AppModel
    let open: (Overlay) -> Void
    @State private var filterBox: UUID?
    @State private var filterKind: CareKind?
    @State private var event: CareEvent?

    var body: some View {
        Page {
            if let home = model.home {
                PageHeader(title: "history.title") {
                    Action(key: "history.add", id: "history.add", compact: true, enabled: home.freeBox != nil) {
                        open(.past(nil))
                    }
                }
                Surface {
                    Picker(L.t("history.boxes"), selection: $filterBox) {
                        Text(L.t("history.allBoxes")).tag(nil as UUID?)
                        ForEach(home.boxes) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .accessibilityIdentifier("history.boxes")
                    Picker(L.t("history.kinds"), selection: $filterKind) {
                        Text(L.t("history.allKinds")).tag(nil as CareKind?)
                        ForEach(CareKind.allCases) { Text($0.label).tag(Optional($0)) }
                    }
                    .accessibilityIdentifier("history.kinds")
                }
                if let milestone = home.milestoneAt {
                    HStack {
                        Action(key: "milestone.open", id: "history.milestone", compact: true) { event = nil; open(.share(.milestone(milestone))) }
                        Spacer()
                        Text(shortDate(milestone)).font(.caption).foregroundStyle(Palette.muted)
                    }
                }
                let filtered = home.effectiveEvents.filter {
                    (filterBox == nil || $0.boxID == filterBox) && (filterKind == nil || $0.kind == filterKind)
                }.sorted { $0.at > $1.at }
                if filtered.isEmpty { Surface { Text(L.t("history.empty")).font(.subheadline) } }
                LazyVStack(spacing: 8) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                        let box = home.boxes.first { $0.id == item.boxID }
                        Surface {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(L.f("history.event", box?.name ?? L.t("box.default"), item.kind.label)).font(.subheadline.bold())
                                    Text(L.f("history.by", shortDate(item.at), item.member.name.isEmpty ? L.t("member.me") : item.member.name))
                                        .font(.caption).foregroundStyle(Palette.muted)
                                }
                                Spacer()
                                if let box, home.writable(box, pro: model.pro) {
                                    Action(key: "edit", id: "history.edit.\(index)", compact: true) { event = item }
                                }
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog(L.t("history.modify"), isPresented: Binding(get: { event != nil }, set: { if !$0 { event = nil } }),
                            titleVisibility: .visible, presenting: event) { item in
            Button(L.t("history.correct")) { open(.past(item)) }
            Button(L.t("undo"), role: .destructive) { model.undo(item) }
        }
    }
}

struct PastLogPage: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let event: CareEvent?
    @State private var boxID: UUID?
    @State private var kind: CareKind = .scoop
    @State private var date = Date()
    @State private var ceiling = Date()

    var body: some View {
        Form {
            if let home = model.home {
                let available = home.boxes.filter { home.writable($0, pro: model.pro) }
                Picker(L.t("box.name"), selection: $boxID) {
                    ForEach(available) { Text($0.name).tag(Optional($0.id)) }
                }
                .accessibilityIdentifier("past.box")
                Picker(L.t("history.kinds"), selection: $kind) {
                    ForEach(CareKind.allCases) { Text($0.label).tag($0) }
                }
                .accessibilityIdentifier("past.kind")
                DatePicker(L.t("past.date"), selection: $date, in: Date(timeIntervalSince1970: 946_684_800)...ceiling)
                    .accessibilityIdentifier("past.date")
                if let selected = available.first(where: { $0.id == boxID }) {
                    let others = home.effectiveEvents.filter { $0.id != event?.id && $0.boxID == selected.id && $0.kind == kind }
                    let isLatest = others.allSatisfy { $0.at < date }
                    Text(L.t(isLatest ? "past.changes" : "past.noChange")).font(.footnote).foregroundStyle(.secondary)
                }
                Action(key: "save", id: "past.save", primary: true, enabled: boxID != nil && model.pendingWrites == 0) {
                    if let boxID {
                        model.log(boxID, kind, date: date, eventID: event?.id, completed: { dismiss() })
                    }
                }
            }
        }
        .onAppear {
            boxID = event?.boxID ?? model.home?.freeBox
            kind = event?.kind ?? .scoop
            date = event?.at ?? model.now
            ceiling = max(Date(), date)
        }
        .sheetTitle(event == nil ? "history.add" : "history.correct")
    }
}
