import SwiftUI
import WidgetKit

struct LitterEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?

    var enabled: Bool {
        guard let snapshot, snapshot.pro else { return false }
        return snapshot.expires.map { date < $0 } ?? true
    }

    var selected: WidgetSnapshot.Box? {
        snapshot?.boxes.first { $0.id == snapshot?.lockBoxID } ?? snapshot?.boxes.first
    }
}

struct LitterTimeline: TimelineProvider {
    func placeholder(in context: Context) -> LitterEntry { LitterEntry(date: .now, snapshot: nil) }

    func getSnapshot(in context: Context, completion: @escaping (LitterEntry) -> Void) {
        completion(LitterEntry(date: .now, snapshot: WidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LitterEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetSnapshot.load()
        let limits = [snapshot?.expires, now.addingTimeInterval(3600)].compactMap { $0 }.filter { $0 > now }
        let due = snapshot?.boxes.flatMap { [$0.scoopDue, $0.washDue].compactMap { $0 } } ?? []
        let updates = Set((limits + due.filter { $0 > now && $0 <= now.addingTimeInterval(3600) }).sorted().prefix(10)).sorted()
        let entries = ([now] + updates).map { LitterEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(3600))))
    }
}

struct LitterWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LitterEntry

    var body: some View {
        Group {
            if entry.enabled, let box = entry.selected {
                switch family {
                case .accessoryRectangular:
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.snapshot?.showBoxName == true ? box.name : L.t("widget.generic")).font(.headline).lineLimit(1)
                        Text(line("care.scoop", last: box.scoop, due: nil)).lineLimit(1)
                        Text(nextTask(box)).lineLimit(1)
                    }
                    .font(.caption2)
                    .widgetURL(url(box))
                case .systemMedium:
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L.t("home.title")).font(.headline)
                        ForEach(Array((entry.snapshot?.boxes ?? [box]).prefix(2))) { item in
                            Link(destination: url(item)) {
                                HStack {
                                    Text(item.name).fontWeight(.semibold).frame(maxWidth: .infinity, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(line("care.scoop", last: item.scoop, due: item.scoopDue))
                                        Text(line("care.wash", last: item.wash, due: item.washDue))
                                    }
                                }
                                .lineLimit(1)
                            }
                        }
                    }.font(.caption)
                default:
                    VStack(alignment: .leading, spacing: 7) {
                        Text(box.name).font(.headline).lineLimit(2)
                        Text(line("care.scoop", last: box.scoop, due: box.scoopDue))
                        Text(line("care.wash", last: box.wash, due: box.washDue))
                    }.font(.caption2).widgetURL(url(box))
                }
            } else {
                Text(L.t(entry.snapshot == nil ? "widget.setup" : "widget.inactive")).font(.caption)
                    .widgetURL(URL(string: "litterboxtracker://boxes"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(for: .widget) {
            Color(red: 251.0/255, green: 248.0/255, blue: 242.0/255)
        }
    }

    private func line(_ key: String, last: Date?, due: Date?) -> String {
        if let due, due <= entry.date {
            return L.f("widget.overdue", L.t(key), span(entry.date.timeIntervalSince(due)))
        }
        if let last { return L.f("widget.ago", L.t(key), span(entry.date.timeIntervalSince(last))) }
        if let due { return L.f("widget.due", L.t(key), span(due.timeIntervalSince(entry.date))) }
        return L.f("widget.empty", L.t(key))
    }

    private func nextTask(_ box: WidgetSnapshot.Box) -> String {
        let due = [("care.scoop", box.scoopDue), ("care.wash", box.washDue)]
            .compactMap { key, date in date.map { (key, $0) } }
            .min { $0.1 < $1.1 }
        guard let (key, date) = due else { return L.t("due.none") }
        return line(key, last: nil, due: date)
    }

    private func span(_ time: TimeInterval) -> String {
        if time >= 86_400 { return L.f("time.days", Int(time / 86_400)) }
        if time >= 3600 { return L.f("time.hours", Int(time / 3600)) }
        return L.f("time.minutes", max(0, Int(time / 60)))
    }

    private func url(_ box: WidgetSnapshot.Box) -> URL {
        URL(string: "litterboxtracker://box/" + box.id.uuidString)!
    }
}

@main
struct LitterBoxWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LitterBoxWidget", provider: LitterTimeline()) { entry in
            LitterWidgetView(entry: entry)
        }
        .configurationDisplayName(L.t("app.name"))
        .description(L.t("widget.description"))
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}
