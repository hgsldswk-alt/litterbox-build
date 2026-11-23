import SwiftUI

struct TrialsPage: View {
    @EnvironmentObject private var model: AppModel
    let open: (Overlay) -> Void
    @State private var selected: UUID?
    @State private var selectedDay: Int?
    @State private var noteOpen = false
    @State private var note = ""

    var body: some View {
        Page {
            if let home = model.home {
                let trials = home.trials.sorted { $0.start > $1.start }
                let trial = trials.first { $0.id == selected } ?? trials.first
                PageHeader(title: "trials.title", subtitle: trial.flatMap { trial in home.boxes.first { $0.id == trial.boxID }?.name }) {
                    Action(key: "trial.new", id: "trial.new", compact: true) { open(model.pro ? .newTrial : .paywall) }
                }
                if !model.pro {
                    Surface(tinted: true) {
                        Text(L.t("trial.readonly")).font(.footnote)
                        Action(key: "pro.title", id: "trials.unlock") { open(.paywall) }
                    }
                }
                if let trial {
                    detail(trial, home: home, all: trials)
                } else {
                    Surface { Text(L.t("trial.empty")).font(.subheadline) }
                }
                Action(key: "compare.title", id: "trial.compare", enabled: trials.count >= 2) { open(.compare) }
                if model.pro, let pair = TrialComparison.defaultPair(trials), pair.canShare {
                    Action(key: "share.result", id: "trial.share") { open(.share(.result(pair))) }
                }
            }
        }
    }

    @ViewBuilder
    private func detail(_ trial: LitterTrial, home: Household, all: [LitterTrial]) -> some View {
        let offset = trial.offset(at: model.now, calendar: home.calendar)
        let day = min(trial.duration - 1, max(0, selectedDay ?? offset))
        Surface {
            HStack {
                Text(trial.name).font(.title3.bold())
                Spacer()
                Text(L.f("trial.day", day + 1, trial.duration)).font(.caption.weight(.semibold))
                    .padding(6).background(Palette.sand, in: Capsule())
                    .accessibilityIdentifier("trial.currentDay")
            }
            Text(L.f("trial.started", trial.start.formatted(date: .abbreviated, time: .omitted)))
                .font(.footnote).foregroundStyle(Palette.muted)
            if !trial.conditions.isEmpty { Text(trial.conditions).font(.footnote) }
            if all.count > 1 {
                Picker(L.t("trial.select"), selection: Binding(get: { trial.id }, set: { selected = $0; selectedDay = nil })) {
                    ForEach(all) { Text($0.name).tag($0.id) }
                }
                .accessibilityIdentifier("trial.selector")
            }
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(0..<trial.duration, id: \.self) { index in
                        Button { selectedDay = index } label: {
                            Text((index + 1).formatted()).font(.footnote.weight(.semibold))
                                .frame(minWidth: 44, minHeight: 44)
                                .background(trial.days[index]?.scores.isEmpty == false ? Palette.sand : Palette.paper,
                                            in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(index == day ? Palette.accent : Palette.line)
                                    .allowsHitTesting(false))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(index == day ? .isSelected : [])
                        .accessibilityIdentifier("trial.day." + String(index + 1))
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        let editable = model.pro && day <= offset
        Surface { RatingControls(trial: trial, day: day, enabled: editable) }
        if !editable && model.pro { Text(L.t("trial.future")).font(.footnote) }
        if let existing = trial.days[day]?.note, !existing.isEmpty { Surface { Text(existing).font(.footnote) } }
        if editable {
            HStack {
                if trial.days[day]?.scores.isEmpty == false {
                    Text(L.t("trial.saved")).font(.footnote).foregroundStyle(Palette.muted)
                        .accessibilityIdentifier("trial.saved")
                }
                Spacer()
                Action(key: "trial.note", id: "trial.note", compact: true) { note = trial.days[day]?.note ?? ""; noteOpen = true }
            }
            .sheet(isPresented: $noteOpen) {
                NavigationStack {
                    Form {
                        TextField(L.t("trial.note"), text: $note, axis: .vertical)
                            .lineLimit(4...8).accessibilityIdentifier("trial.note.text")
                        Action(key: "save", id: "trial.note.save", primary: true) {
                            let text = bounded(note, length: 500)
                            model.edit({ home, _, pro in
                                guard pro, let index = home.trials.firstIndex(where: { $0.id == trial.id }) else {
                                    throw EditingError.unavailable
                                }
                                home.trials[index].days[day, default: DailyRating()].note = text
                            }, completed: { noteOpen = false })
                        }
                    }
                    .sheetTitle("trial.note")
                }
            }
        }
    }
}

struct RatingControls: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize
    let trial: LitterTrial
    let day: Int
    var compact = false
    var enabled = true

    var body: some View {
        ForEach(RatingAxis.allCases) { axis in
            if compact && !typeSize.isAccessibilitySize {
                HStack(spacing: 4) {
                    Text(axis.label).font(.footnote.weight(.semibold)).frame(minWidth: 60, alignment: .leading)
                    scores(axis)
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text(axis.label).font(.subheadline.weight(.semibold))
                    scores(axis)
                    HStack(alignment: .top) {
                        Text(axis.low)
                        Spacer(minLength: 5)
                        Text(axis.high).multilineTextAlignment(.trailing)
                    }
                    .font(.caption).foregroundStyle(Palette.muted)
                }
            }
        }
    }

    private func scores(_ axis: RatingAxis) -> some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { value in
                let selected = trial.days[day]?.scores[axis] == value
                Button {
                    model.edit { home, now, pro in
                        guard pro, let index = home.trials.firstIndex(where: { $0.id == trial.id }),
                              day <= home.trials[index].offset(at: now, calendar: home.calendar) else {
                            throw EditingError.unavailable
                        }
                        home.trials[index].rate(axis, score: value, day: day)
                    }
                } label: {
                    Text(value.formatted()).font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(selected ? Palette.sand : Palette.paper, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Palette.accent : Palette.line)
                            .allowsHitTesting(false))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .accessibilityLabel(L.f("rating.accessible", axis.label, value))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier((compact ? "quick." : "rating.") + axis.rawValue + "." + String(value))
            }
        }
    }
}

struct NewTrialPage: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var conditions = ""
    @State private var boxID: UUID?
    @State private var start = Date()
    @State private var duration = 7

    var body: some View {
        Form {
            let boxes = model.home?.boxes.filter { !$0.archived } ?? []
            TextField(L.t("trial.name"), text: $name).accessibilityIdentifier("trial.name")
            TextField(L.t("trial.conditions"), text: $conditions, axis: .vertical).accessibilityIdentifier("trial.conditions")
            Text(L.t("trial.conditions.help")).font(.footnote).foregroundStyle(.secondary)
            Picker(L.t("box.name"), selection: $boxID) {
                ForEach(boxes) { Text($0.name).tag(Optional($0.id)) }
            }
            .accessibilityIdentifier("trial.box")
            DatePicker(L.t("trial.startDate"), selection: $start, displayedComponents: .date).accessibilityIdentifier("trial.startDate")
            Stepper(L.f("trial.duration", duration), value: $duration, in: 1...30).accessibilityIdentifier("trial.duration")
            Action(key: "trial.start", id: "trial.start", primary: true, enabled: !(bounded(name, length: 60).isEmpty) && boxID != nil && model.pendingWrites == 0) {
                guard let boxID else { return }
                let text = bounded(name, length: 60)
                let context = bounded(conditions, length: 200)
                model.edit({ home, _, pro in
                    guard pro, home.boxes.contains(where: { $0.id == boxID && !$0.archived }) else {
                        throw EditingError.unavailable
                    }
                    home.trials.append(LitterTrial(boxID: boxID, name: text, conditions: context,
                                                 start: home.calendar.startOfDay(for: start), duration: duration))
                }, completed: { dismiss() })
            }
        }
        .onAppear { boxID = model.home?.freeBox }
        .sheetTitle("trial.new")
    }
}

struct ComparePage: View {
    @EnvironmentObject private var model: AppModel
    @State private var first: UUID?
    @State private var second: UUID?
    @State private var editing = false

    var body: some View {
        Page {
            if let home = model.home {
                let list = home.trials.sorted { $0.start > $1.start }
                let defaultPair = TrialComparison.defaultPair(list)
                if editing {
                    Surface {
                        selector("compare.first", id: "compare.first", selection: $first, list: list)
                        selector("compare.second", id: "compare.second", selection: $second, list: list)
                    }
                }
                if let a = list.first(where: { $0.id == first }) ?? defaultPair?.first ?? list.first,
                   let b = list.first(where: { $0.id == second }) ?? defaultPair?.second ?? list.dropFirst().first, a.id != b.id {
                    comparison(TrialComparison(first: a, second: b), home: home)
                } else {
                    Surface { Text(L.t("compare.empty")) }
                }
                Action(key: "compare.change", id: "compare.change") {
                    if !editing {
                        first = first ?? defaultPair?.first.id ?? list.first?.id
                        second = second ?? defaultPair?.second.id ?? list.dropFirst().first?.id
                    }
                    editing.toggle()
                }
            }
        }
        .sheetTitle("compare.title")
    }

    private func selector(_ key: String, id: String, selection: Binding<UUID?>, list: [LitterTrial]) -> some View {
        Picker(L.t(key), selection: selection) {
            ForEach(list) { Text($0.name).tag(Optional($0.id)) }
        }
        .accessibilityIdentifier(id)
    }

    @ViewBuilder
    private func comparison(_ pair: TrialComparison, home: Household) -> some View {
        Text(L.f("compare.range", pair.span)).font(.footnote).foregroundStyle(Palette.muted)
        HStack(alignment: .top) {
            ForEach([pair.first, pair.second]) { trial in
                Surface {
                    Text(trial.name).font(.headline)
                    Text(L.f("compare.days", pair.daysLogged(trial))).font(.footnote)
                    let end = home.calendar.date(byAdding: .day, value: pair.span - 1, to: trial.start) ?? trial.start
                    Text(trial.start.formatted(date: .abbreviated, time: .omitted) + " – " + end.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption).foregroundStyle(Palette.muted)
                }
            }
        }
        Surface {
            ComparisonTable(pair: pair, counts: true)
            Text(L.t("compare.higher")).font(.footnote).foregroundStyle(Palette.muted)
        }
        Surface(tinted: true) {
            if !pair.sameConditions { Text(L.t("compare.different")).font(.footnote) }
            else {
                ForEach(RatingAxis.allCases) { axis in
                    Text(pair.conclusion(axis) ?? L.f("compare.insufficient", axis.label)).font(.footnote)
                }
            }
        }
        if pair.canShare && model.pro {
            NavigationLink {
                SharePage(content: .result(pair))
            } label: {
                Text(L.t("share.result")).font(.title3.bold()).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 47)
                    .background(Palette.accent, in: RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("compare.share")
        }
    }
}

struct ComparisonTable: View {
    let pair: TrialComparison
    var counts = false

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Text(L.t("compare.score"))
                Text(pair.first.name)
                Text(pair.second.name)
            }
            .font(.caption.weight(.semibold))
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(RatingAxis.allCases) { axis in
                GridRow {
                    Text(axis.label)
                    cell(pair.sample(pair.first, axis: axis))
                    cell(pair.sample(pair.second, axis: axis))
                }
                .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cell(_ value: TrialComparison.Sample) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.average.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? L.t("empty.value"))
                .monospacedDigit()
            if counts { Text(L.f("compare.samples", value.count)).font(.caption2).foregroundStyle(Palette.muted) }
        }
    }
}
