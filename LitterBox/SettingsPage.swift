import StoreKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsPage: View {
    @EnvironmentObject private var model: AppModel
    let open: (Overlay) -> Void
    @State private var fileExport = false
    @State private var busy = false
    @State private var document = TextTransfer()

    var body: some View {
        Form {
            if let home = model.home {
                let boxes = home.boxes.filter { !$0.archived }
                if boxes.count > 1 {
                    Picker(L.t("settings.freeBox"), selection: Binding(get: { home.freeBox }, set: { value in
                        model.edit { group, _, _ in group.freeBoxID = value }
                    })) {
                        ForEach(boxes) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .accessibilityIdentifier("settings.freeBox")
                }
                Section(L.t("settings.data")) {
                    Action(key: "backup.export", id: "backup.export", enabled: !busy) { backup() }
                    Text(L.t("backup.help")).font(.footnote).foregroundStyle(.secondary)
                    ForEach(home.boxes.filter(\.archived)) { box in
                        HStack {
                            Text(box.name)
                            Spacer()
                            Action(key: "box.restore", id: "box.restore." + box.id.uuidString, compact: true) {
                                if model.pro || home.freeBox == nil {
                                    model.edit { current, _, pro in
                                        guard pro || current.freeBox == nil,
                                              let i = current.boxes.firstIndex(where: { $0.id == box.id }) else {
                                            throw EditingError.unavailable
                                        }
                                        current.boxes[i].archived = false
                                        current.boxes[i].archivedAt = nil
                                    }
                                } else { open(.paywall) }
                            }
                        }
                    }
                }
            }
            Action(key: "widgets.title", id: "settings.widgets") { open(.widgets) }
            if !Launch.isFree {
                Action(key: "pro.title", id: "settings.pro") { open(.paywall) }
            }
        }
        .sheetTitle("settings")
        .fileExporter(isPresented: $fileExport, document: document, contentType: .json, defaultFilename: "LitterBox-backup") { result in
            if case .failure = result { model.error = "error.save" }
        }
    }

    private func backup() {
        guard let data = model.data else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let bytes = try await Task.detached(priority: .userInitiated) {
                    try JSONEncoder().encode(data)
                }.value
                document = TextTransfer(data: bytes)
                if Launch.uiTesting { model.shareRequested = true }
                else { fileExport = true }
            } catch { model.error = "error.save" }
        }
    }
}

struct WidgetHelp: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Page {
            Surface {
                Text(L.t("widgets.home")).font(.headline)
                Text(L.t("widgets.home.help")).font(.footnote).foregroundStyle(Palette.muted)
                if model.pro, let home = model.home {
                    ForEach(Array(home.boxes.filter { !$0.archived }.sorted {
                        home.urgency($0) < home.urgency($1)
                    }.prefix(2))) { box in
                        HStack {
                            Text(box.name).font(.subheadline.weight(.semibold))
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                ForEach(CareKind.allCases) { kind in
                                    Text(L.f("widget.preview.line", kind.label,
                                             relativeDue(home.due(box, kind), now: model.now)))
                                        .font(.caption).foregroundStyle(Palette.muted)
                                }
                            }
                        }
                        .padding(8)
                        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            Surface {
                Text(L.t("widgets.lock")).font(.headline)
                Text(L.t("widgets.lock.help")).font(.footnote).foregroundStyle(Palette.muted)
            }
            if model.pro, let home = model.home {
                Surface {
                    Picker(L.t("widgets.box"), selection: Binding(get: { home.lockBoxID }, set: { id in
                        model.edit { home, _, pro in
                            guard pro else { throw EditingError.unavailable }
                            home.lockBoxID = id
                        }
                    })) {
                        Text(L.t("widgets.auto")).tag(nil as UUID?)
                        ForEach(home.boxes.filter { !$0.archived }) { Text($0.name).tag(Optional($0.id)) }
                    }.accessibilityIdentifier("widgets.box")
                    Toggle(L.t("widgets.names"), isOn: Binding(get: { home.showBoxName }, set: { show in
                        model.edit { home, _, pro in
                            guard pro else { throw EditingError.unavailable }
                            home.showBoxName = show
                        }
                    })).accessibilityIdentifier("widgets.names")
                }
            } else {
                Surface(tinted: true) {
                    Text(L.t("widgets.locked")).font(.footnote)
                    NavigationLink { PaywallPage() } label: {
                        Text(L.t("pro.title")).frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }.accessibilityIdentifier("widgets.upgrade")
                }
            }
        }
        .sheetTitle("widgets.title")
    }
}

struct PaywallPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var products: [Product] = []
    @State private var busy = false
    @State private var status: String?
    @State private var loadingProducts = false

    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: 8) {
                Text(L.t("pro.headline")).font(.largeTitle.bold()).accessibilityIdentifier("paywall.title")
                Text(L.t("pro.body")).foregroundStyle(Palette.muted)
            }
            Surface(tinted: true) {
                Text(L.t("pro.includes")).font(.headline)
                ForEach(["pro.boxes", "pro.trials", "pro.family", "pro.widgets"], id: \.self) { key in
                    Label(L.t(key), systemImage: "checkmark").font(.subheadline)
                }
            }
            if let value = model.entitlement {
                Text(value.purchasedPro ? L.t("pro.owned") : value.daysLeft(at: model.accessNow) > 0
                    ? L.f("pro.remaining", value.daysLeft(at: model.accessNow)) : L.t("pro.expired"))
                    .font(.footnote.weight(.semibold))
            }
            if model.entitlement?.purchasedPro != true {
                if let product = products.first(where: { $0.id == Purchases.proID }) {
                    storeAction(L.f("pro.buy.price", product.displayPrice), id: "paywall.buy") {
                        perform { if let transaction = try await Purchases.buy(product) { await model.apply(transaction) } }
                    }
                } else if Launch.uiTesting {
                    storeAction(L.f("pro.buy.price", "US$2.99"), id: "paywall.buy", enabled: false) {}
                } else if loadingProducts {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Action(key: "pro.retry", id: "paywall.retry") { Task { await load() } }
                }
                if let trial = products.first(where: { $0.id == Purchases.trialID }),
                   let value = model.entitlement, value.trialClaimedAt == nil, value.daysLeft(at: model.accessNow) > 0 {
                    Action(key: "pro.claim", id: "paywall.claim", enabled: !busy) {
                        perform { if let transaction = try await Purchases.buy(trial) { await model.apply(transaction) } }
                    }
                } else if Launch.uiTesting {
                    Action(key: "pro.claim", id: "paywall.claim", enabled: false) {}
                }
            }
            Action(key: "pro.restore", id: "paywall.restore", enabled: !busy && !Launch.uiTesting) {
                perform {
                    try await AppStore.sync()
                    await model.syncPurchases(restoring: true)
                    status = model.entitlement?.purchasedPro == true ? "pro.restored" : "pro.noPurchase"
                }
            }
            Text(L.t("pro.terms")).font(.footnote).foregroundStyle(Palette.muted)
            if let status { Text(L.t(status)).font(.footnote).accessibilityIdentifier("paywall.status") }
        }
        .sheetTitle("pro.title")
        .task { await load() }
    }

    private func load() async {
        guard !Launch.uiTesting, !loadingProducts else { return }
        loadingProducts = true
        defer { loadingProducts = false }
        do {
            products = try await Purchases.products()
            status = products.isEmpty ? "pro.unavailable" : nil
        } catch { status = "pro.unavailable" }
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        status = nil
        Task {
            defer { busy = false }
            do { try await operation() }
            catch {
                status = (error as? PurchaseError) == .pending ? "pro.pending" : "pro.unavailable"
            }
        }
    }

    private func storeAction(_ label: String, id: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.title3.bold()).foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 47)
                .background(Palette.accent, in: RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy || !enabled)
        .accessibilityIdentifier(id)
    }
}
