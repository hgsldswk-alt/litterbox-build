import SwiftUI
import UIKit

struct BoxesPage: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var pinnedOrder: [UUID] = []
    let open: (Overlay) -> Void

    var body: some View {
        if let home = model.home {
            let ordered = sorted(home)
            ScrollViewReader { reader in
                Page {
                    let overdue = ordered.reduce(0) { count, box in
                        count + CareKind.allCases.filter { home.due(box, $0).map { $0 <= model.now } ?? false }.count
                    }
                    PageHeader(title: "home.title", subtitle: L.f("home.routineStatus", ordered.count, overdue)) {
                        HStack(spacing: 0) {
                            Action(key: "box.add", id: "box.add", compact: true) {
                                open(model.pro || ordered.isEmpty ? .box(nil) : .paywall)
                            }
                            Button { open(.settings) } label: {
                                Image(systemName: "gearshape").font(.body.weight(.medium))
                                    .frame(width: 44, height: 44).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L.t("settings"))
                            .accessibilityIdentifier("home.settings")
                        }
                    }
                    if model.notificationDenied {
                        Surface(tinted: true) { Text(L.t("notifications.denied")).font(.footnote) }
                    }
                    if ordered.isEmpty {
                        Surface { Text(L.t("home.empty")).font(.subheadline) }
                    }
                    ForEach(Array(ordered.enumerated()), id: \.element.id) { index, box in
                        card(box, in: home, index: index, ordered: ordered)
                            .id(box.id)
                    }
                    if let milestone = home.milestoneAt, home.milestonePresented != true {
                        Surface(tinted: true) {
                            HStack {
                                Action(key: "milestone.open", id: "home.milestone", compact: true) {
                                    hideMilestone()
                                    open(.share(.milestone(milestone)))
                                }
                                Spacer()
                                Action(key: "dismiss", id: "milestone.hide", compact: true) { hideMilestone() }
                            }
                        }
                    }
                    if model.pro, let trial = home.trials.filter({
                        (0..<$0.duration).contains($0.offset(at: model.now, calendar: home.calendar))
                    }).max(by: { $0.start < $1.start }) {
                        let day = trial.offset(at: model.now, calendar: home.calendar)
                        Surface {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(L.t("trial.rateToday")).font(.headline)
                                    Text(L.f("trial.quickDetails", trial.name, L.f("trial.day", day + 1, trial.duration)))
                                        .font(.footnote).foregroundStyle(Palette.muted)
                                }
                                Spacer()
                                Action(key: "tab.trials", id: "home.trials", compact: true) { model.tab = .trials }
                            }
                            RatingControls(trial: trial, day: day, compact: true)
                        }
                    }
                }
                .onChange(of: model.selectedBox, initial: true) { _, id in
                    if let id { withAnimation { reader.scrollTo(id, anchor: .top) }; model.selectedBox = nil }
                }
            }
        }
    }

    private func sorted(_ home: Household) -> [LitterBox] {
        let boxes = home.boxes.filter { !$0.archived }
        if model.feedback != nil, !pinnedOrder.isEmpty {
            return boxes.sorted {
                (pinnedOrder.firstIndex(of: $0.id) ?? Int.max) < (pinnedOrder.firstIndex(of: $1.id) ?? Int.max)
            }
        }
        return boxes.sorted {
            let lhs = home.urgency($0), rhs = home.urgency($1)
            return lhs == rhs ? $0.createdAt < $1.createdAt : lhs < rhs
        }
    }

    private func hideMilestone() {
        model.edit { home, _, _ in home.milestonePresented = true }
    }

    private func card(_ box: LitterBox, in home: Household, index: Int, ordered: [LitterBox]) -> some View {
        let writable = home.writable(box, pro: model.pro)
        let late = CareKind.allCases.contains { kind in home.due(box, kind).map { $0 <= model.now } ?? false }
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 7)) : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
        return Surface {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    if writable {
                        Button { open(.box(box.id)) } label: {
                            Text(box.name).font(.title3.bold()).multilineTextAlignment(.leading)
                                .frame(minWidth: 44, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(L.t("box.edit"))
                        .accessibilityIdentifier("box.edit.\(index)")
                    } else {
                        Text(box.name).font(.title3.bold()).accessibilityAddTraits(.isHeader)
                    }
                    if !box.cats.isEmpty { Text(box.cats.map(\.name).joined(separator: " · ")).font(.footnote).foregroundStyle(Palette.muted) }
                }
                Spacer()
                if writable {
                    Action(key: "reminders.title", id: "box.reminders.\(index)", compact: true) { open(.reminders(box.id)) }
                } else if late {
                    Text(L.t("home.overdue"))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Palette.sand, in: Capsule())
                }
            }
            layout {
                ForEach(CareKind.allCases) { kind in timer(box, kind: kind, home: home) }
            }
            if let event = model.feedback, event.boxID == box.id {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L.f(event.kind == .scoop ? "feedback.scoop" : "feedback.wash",
                                 event.member.name.isEmpty ? L.t("member.me") : event.member.name))
                            .font(.footnote.weight(.semibold)).accessibilityIdentifier("log.feedback")
                        if let due = home.due(box, event.kind) {
                            Text(L.f("due.absolute", shortDate(due))).font(.caption).foregroundStyle(Palette.muted)
                        }
                    }
                    Spacer()
                    Action(key: "undo", id: "log.undo", compact: true) { model.undo(event) }
                }
                .padding(.horizontal, 7)
                .background(Palette.sand, in: RoundedRectangle(cornerRadius: 9))
            }
            if writable {
                layout {
                    ForEach(CareKind.allCases) { kind in
                        Action(key: "log." + kind.rawValue, id: "log.\(kind.rawValue).\(index)", primary: kind == .scoop) {
                            pinnedOrder = ordered.map(\.id)
                            model.log(box.id, kind)
                        }
                    }
                }
            } else {
                HStack {
                    Text(L.t("box.readonly")).font(.footnote).foregroundStyle(Palette.muted)
                    Spacer()
                    Action(key: "pro.title", id: "box.unlock.\(index)", compact: true) { open(.paywall) }
                }
            }
        }
        .overlay(alignment: .leading) {
            if late {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(Palette.accent, lineWidth: 1.5)
                    .mask(alignment: .leading) { Rectangle().frame(width: 20) }
                    .allowsHitTesting(false)
            }
        }
    }

    private func timer(_ box: LitterBox, kind: CareKind, home: Household) -> some View {
        let event = home.latest(box.id, kind)
        let due = home.due(box, kind)
        return VStack(alignment: .leading, spacing: 4) {
            Text(L.t("last." + kind.rawValue)).font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
            Text(event.map { model.now.timeIntervalSince($0.at) < 60 ? L.t("time.justNow")
                : L.f("time.ago", elapsed(model.now.timeIntervalSince($0.at))) } ?? L.t("care.empty"))
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(relativeDue(due, now: model.now)).font(.caption).foregroundStyle(Palette.muted)
            if let event {
                Text(event.member.name.isEmpty ? L.t("member.me") : event.member.name)
                    .font(.caption2).foregroundStyle(Palette.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

struct BoxEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let id: UUID?
    @State private var name = ""
    @State private var cats = ""
    @State private var archive = false

    private var existing: LitterBox? { model.home?.boxes.first { $0.id == id } }

    var body: some View {
        Form {
            TextField(L.t("box.name"), text: $name).accessibilityIdentifier("box.name")
            if model.pro {
                TextField(L.t("box.cats"), text: $cats).accessibilityIdentifier("box.cats")
            }
            Action(key: "save", id: "box.save", primary: true, enabled: !bounded(name, length: 60).isEmpty) {
                let name = bounded(name, length: 60)
                let cats = String(cats.prefix(1000)).replacingOccurrences(of: "、", with: ",")
                    .replacingOccurrences(of: "，", with: ",")
                    .split(separator: ",").prefix(20).map { bounded(String($0), length: 35) }.filter { !$0.isEmpty }
                persist { home, now, pro in
                    if let id, let index = home.boxes.firstIndex(where: { $0.id == id }) {
                        guard home.writable(home.boxes[index], pro: pro) else { throw EditingError.unavailable }
                        home.boxes[index].name = name
                        home.boxes[index].isStarter = false
                        if pro { home.boxes[index].cats = cats.map { CatLabel(name: $0) } }
                    } else {
                        guard pro || home.freeBox == nil else { throw EditingError.unavailable }
                        let box = LitterBox(name: name, cats: pro ? cats.map { .init(name: $0) } : [], createdAt: now)
                        home.boxes.append(box)
                        if home.freeBox == nil { home.freeBoxID = box.id }
                    }
                }
            }
            if let existing {
                Action(key: "box.archive", id: "box.archive") { archive = true }
                    .confirmationDialog(L.t("box.archive.confirm"), isPresented: $archive, titleVisibility: .visible) {
                        Button(L.t("box.archive"), role: .destructive) {
                            persist { home, now, _ in
                                if let index = home.boxes.firstIndex(where: { $0.id == existing.id }) {
                                    home.boxes[index].archived = true
                                    home.boxes[index].archivedAt = now
                                }
                            }
                        }
                    }
            }
        }
        .onAppear {
            if let existing { name = existing.name; cats = existing.cats.map(\.name).joined(separator: ", ") }
        }
        .sheetTitle(id == nil ? "box.add" : "box.edit")
    }

    private func persist(_ change: @escaping (inout Household, Date, Bool) throws -> Void) {
        model.edit(change, completed: { dismiss() })
    }
}

struct RemindersPage: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL
    let id: UUID
    @State private var custom = CareKind.scoop
    @State private var customOpen = false
    @State private var hours = ""
    @State private var pause = false
    @State private var pauseDate = Date()
    @State private var choosingDate = false

    var body: some View {
        Page {
            if let home = model.home, let box = home.boxes.first(where: { $0.id == id }) {
                Text(box.name).font(.title2.bold())
                ForEach(CareKind.allCases) { kind in
                    Surface {
                        Toggle(kind.label, isOn: Binding(get: { box[kind].enabled }, set: { enabled in
                            change { item, now in
                                item[kind].enabled = enabled
                                if enabled { item[kind].enabledAt = now }
                            } completed: { if enabled { model.askNotifications() } }
                        }))
                        .accessibilityIdentifier("reminders.toggle." + kind.rawValue)
                        let due = home.due(box, kind)
                        Text(relativeDue(due, now: model.now)).font(.footnote).foregroundStyle(Palette.muted)
                        if let due { Text(L.f("due.absolute", shortDate(due))).font(.caption).foregroundStyle(Palette.muted) }
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 2) { options(kind, box: box) }
                            VStack(alignment: .leading, spacing: 0) { options(kind, box: box) }
                        }
                    }
                }
                Surface {
                    Toggle(L.t("quiet.title"), isOn: quiet(\.enabled)).accessibilityIdentifier("quiet.toggle")
                    if home.quiet.enabled {
                        DatePicker(L.t("quiet.start"), selection: clock(\.startMinute), displayedComponents: .hourAndMinute)
                            .accessibilityIdentifier("quiet.start")
                        DatePicker(L.t("quiet.end"), selection: clock(\.endMinute), displayedComponents: .hourAndMinute)
                            .accessibilityIdentifier("quiet.end")
                    }
                    Text(L.t("quiet.help")).font(.footnote).foregroundStyle(Palette.muted)
                }
                Surface {
                    if let deadline = box.pausedUntil, deadline > model.now {
                        Text(L.f("pause.until", shortDate(deadline))).font(.footnote)
                        Action(key: "pause.resume", id: "reminders.resume") { setPause(nil) }
                    } else {
                        Action(key: "pause.title", id: "reminders.pause") { pause = true }
                    }
                    Text(L.t("pause.help")).font(.footnote).foregroundStyle(Palette.muted)
                }
                if model.notificationDenied {
                    Surface(tinted: true) {
                        Text(L.t("notifications.denied")).font(.footnote)
                        Action(key: "notifications.settings", id: "reminders.system") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                }
            }
        }
        .sheetTitle("reminders.title")
        .confirmationDialog(L.t("pause.title"), isPresented: $pause, titleVisibility: .visible) {
            Button(L.t("pause.tomorrow")) {
                let cal = Calendar.autoupdatingCurrent
                setPause(cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: model.now)))
            }
            Button(L.t("pause.choose")) { pauseDate = model.now.addingTimeInterval(3600); choosingDate = true }
        }
        .sheet(isPresented: $choosingDate) {
            NavigationStack {
                Form {
                    DatePicker(L.t("pause.title"), selection: $pauseDate, in: Date()...)
                    Action(key: "save", id: "pause.save", primary: true) { setPause(pauseDate); choosingDate = false }
                }
                .sheetTitle("pause.title")
            }
        }
        .alert(L.t("reminders.custom"), isPresented: $customOpen) {
            TextField(L.t("reminders.hours"), text: $hours).keyboardType(.numberPad)
            Button(L.t("save")) {
                if let number = Int(hours), (1...8760).contains(number) { setInterval(custom, hours: number) }
                else { model.error = "error.hours" }
            }
            Button(L.t("cancel"), role: .cancel) {}
        } message: { Text(L.t("reminders.hoursRange")) }
    }

    @ViewBuilder
    private func options(_ kind: CareKind, box: LitterBox) -> some View {
        ForEach(kind.presets, id: \.self) { preset in
            let label = preset < 72 ? L.f("interval.hours", preset) : L.f("interval.days", preset / 24)
            Button {
                setInterval(kind, hours: preset)
            } label: {
                Text(label).font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .frame(minWidth: 44, minHeight: 44)
                    .background(box[kind].hours == preset ? Palette.sand : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(box[kind].hours == preset ? .isSelected : [])
            .accessibilityIdentifier("reminders.\(kind.rawValue).\(preset)")
        }
        Action(key: "reminders.custom", id: "reminders.custom." + kind.rawValue, compact: true) {
            hours = String(box[kind].hours)
            custom = kind
            customOpen = true
        }
    }

    private func setInterval(_ kind: CareKind, hours: Int) {
        change { item, _ in item[kind].hours = hours }
    }

    private func setPause(_ date: Date?) {
        change { item, now in
            var intervals = item.pauses ?? []
            if let last = intervals.last, last.end > now {
                intervals[intervals.count - 1] = DateInterval(start: last.start, end: max(last.start, now))
            }
            if let date, date > now { intervals.append(DateInterval(start: now, end: date)) }
            item.pauses = Array(intervals.filter { $0.end > now - 70 * 86_400 })
            item.pausedUntil = date
        }
    }

    private func change(_ update: @escaping (inout LitterBox, Date) -> Void, completed: (() -> Void)? = nil) {
        model.edit({ home, now, pro in
            guard let index = home.boxes.firstIndex(where: { $0.id == id }),
                  home.writable(home.boxes[index], pro: pro) else { throw EditingError.unavailable }
            update(&home.boxes[index], now)
        }, completed: completed)
    }

    private func quiet(_ path: WritableKeyPath<QuietHours, Bool>) -> Binding<Bool> {
        Binding(get: { model.home?.quiet[keyPath: path] ?? false }, set: { value in
            model.edit { home, _, _ in home.quiet[keyPath: path] = value }
        })
    }

    private func clock(_ path: WritableKeyPath<QuietHours, Int>) -> Binding<Date> {
        let calendar = Calendar.autoupdatingCurrent
        return Binding(get: {
            let minute = model.home?.quiet[keyPath: path] ?? 0
            return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: .now) ?? .now
        }, set: { value in
            let result = calendar.component(.hour, from: value) * 60 + calendar.component(.minute, from: value)
            model.edit { home, _, _ in home.quiet[keyPath: path] = result }
        })
    }
}
