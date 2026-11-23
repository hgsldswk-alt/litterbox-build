import StoreKit
import SwiftUI
import UIKit
import UserNotifications

final class NotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["boxID"] as? String,
              let url = URL(string: "litterboxtracker://box/" + id) else { return }
        await MainActor.run { UIApplication.shared.open(url) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

@main
struct LitterBoxApp: App {
    @UIApplicationDelegateAdaptor(NotificationDelegate.self) private var notifications
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootPage()
                .environmentObject(model)
                .tint(Palette.accent)
                .preferredColorScheme(.light)
                .task { await model.open() }
                .task { await model.watchPurchases() }
                .task {
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(30)) } catch { break }
                        if phase == .active { await model.activate() }
                    }
                }
                .onChange(of: phase) { _, value in
                    if value == .active { Task { await model.activate(force: true) } }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                    Task { await model.activate(force: true) }
                }
                .onOpenURL { url in
                    guard url.scheme == "litterboxtracker" else { return }
                    model.tab = .boxes
                    if url.host == "box" { model.selectedBox = UUID(uuidString: url.lastPathComponent) }
                }
        }
    }
}

enum Overlay: Identifiable {
    case settings, reminders(UUID), box(UUID?), past(CareEvent?), newTrial, compare, share(ShareContent), widgets, paywall
    var id: String {
        switch self {
        case .settings: return "settings"
        case .reminders(let id): return "reminders." + id.uuidString
        case .box(let id): return "box." + (id?.uuidString ?? "new")
        case .past(let event): return "past." + (event?.id.uuidString ?? "new")
        case .newTrial: return "trial"
        case .compare: return "compare"
        case .share(let content): return "share." + content.id
        case .widgets: return "widgets"
        case .paywall: return "paywall"
        }
    }
}

struct RootPage: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var phase
    @State private var overlay: Overlay?
    @State private var nextOverlay: Overlay?

    var body: some View {
        Group {
            if model.home == nil {
                Page {
                    if model.error == nil { ProgressView().frame(maxWidth: .infinity).padding() }
                    else { Action(key: "retry", id: "open.retry") { model.error = nil; Task { await model.open() } } }
                }
            } else {
                Group {
                    switch model.tab {
                    case .boxes: BoxesPage(open: show)
                    case .trials: TrialsPage(open: show)
                    case .family: FamilyPage(open: show)
                    case .history: HistoryPage(open: show)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
            }
        }
        .background(Palette.paper.ignoresSafeArea())
        .sheet(item: $overlay, onDismiss: {
            if let next = nextOverlay { nextOverlay = nil; overlay = next }
        }) { item in
            NavigationStack { content(item) }
                .presentationDragIndicator(.visible)
                .tint(Palette.accent)
        }
        .alert(L.t("error.title"), isPresented: Binding(get: { model.error != nil },
            set: { if !$0 { model.error = nil } })) {
            Button(L.t("ok")) { if model.home == nil { model.error = nil; Task { await model.open() } } }
        } message: {
            Text(L.t(model.error ?? "error.save"))
        }
        .onChange(of: model.home != nil) { _, loaded in
            if loaded && Launch.has("-paywall") { show(.paywall) }
        }
        .onChange(of: model.reviewOpportunity) { _, _ in
            model.observeReview(eligible: model.tab == .boxes && overlay == nil && phase == .active) { requestReview() }
        }
        .overlay(alignment: .top) {
            if Launch.uiTesting && model.reviewSignal > 0 {
                Text(L.t("review.requested")).font(.caption).accessibilityIdentifier("review.requested").allowsHitTesting(false)
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(AppModel.Tab.allCases, id: \.self) { tab in
                Button {
                    model.tab = tab
                } label: {
                    Text(L.t("tab.\(tab.rawValue)"))
                        .font(.footnote.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 3)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(model.tab == tab ? Palette.sand : .clear, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.tab == tab ? .isSelected : [])
                .accessibilityIdentifier("tab." + tab.rawValue)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.white)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1).allowsHitTesting(false) }
    }

    private func show(_ item: Overlay) {
        if overlay != nil { nextOverlay = item; overlay = nil }
        else { overlay = item }
    }

    @ViewBuilder
    private func content(_ item: Overlay) -> some View {
        switch item {
        case .settings: SettingsPage(open: show)
        case .reminders(let id): RemindersPage(id: id)
        case .box(let id): BoxEditor(id: id)
        case .past(let event): PastLogPage(event: event)
        case .newTrial: NewTrialPage()
        case .compare: ComparePage().environmentObject(model)
        case .share(let content): SharePage(content: content)
        case .widgets: WidgetHelp()
        case .paywall: PaywallPage()
        }
    }
}

struct SheetTitle: ViewModifier {
    let title: String
    @Environment(\.dismiss) private var dismiss
    func body(content: Content) -> some View {
        content.navigationTitle(L.t(title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Action(key: "done", id: "sheet.done", compact: true) { dismiss() }
                }
            }
    }
}

extension View {
    func sheetTitle(_ title: String) -> some View { modifier(SheetTitle(title: title)) }
}
