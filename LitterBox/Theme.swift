import SwiftUI

enum Palette {
    static let accent = Color(red: 140/255, green: 122/255, blue: 30/255)
    static let paper = Color(red: 251/255, green: 248/255, blue: 242/255)
    static let ink = Color(red: 41/255, green: 37/255, blue: 26/255)
    static let muted = Color(red: 99/255, green: 92/255, blue: 74/255)
    static let line = Color(red: 232/255, green: 224/255, blue: 208/255)
    static let sand = Color(red: 244/255, green: 236/255, blue: 210/255)
}

struct Surface<Content: View>: View {
    var tinted = false
    let content: Content

    init(tinted: Bool = false, @ViewBuilder content: () -> Content) {
        self.tinted = tinted
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(tinted ? Palette.sand : .white, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Palette.line).allowsHitTesting(false))
    }
}

struct Action: View {
    @ScaledMetric(relativeTo: .title3) private var primarySize = 19.0
    let key: String
    let id: String
    var primary = false
    var compact = false
    var enabled = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(L.t(key))
                .font(primary ? .system(size: primarySize, weight: .bold) : .subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(primary ? .white : Palette.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(minWidth: 44, maxWidth: compact ? nil : .infinity, minHeight: primary ? 47 : 44)
                .background {
                    if primary || !compact {
                        RoundedRectangle(cornerRadius: 12).fill(primary ? Palette.accent : .white)
                        RoundedRectangle(cornerRadius: 12).strokeBorder(primary ? Palette.accent : Palette.line)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

struct Page<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) { content }
                .frame(maxWidth: 600)
                .padding(.horizontal, 17)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
        }
        .background(Palette.paper)
        .foregroundStyle(Palette.ink)
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let trailing: Trailing
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L.t(title)).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(Palette.muted) }
            }
            Spacer(minLength: 6)
            trailing
        }
    }
}

func shortDate(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }

func relativeDue(_ due: Date?, now: Date) -> String {
    guard let due else { return L.t("due.none") }
    let seconds = due.timeIntervalSince(now)
    return L.f(seconds <= 0 ? "due.late" : "due.next", elapsed(abs(seconds)))
}

func elapsed(_ time: TimeInterval) -> String {
    let seconds = max(0, time)
    if seconds >= 86_400 { return L.f("time.days", Int(seconds / 86_400)) }
    if seconds >= 3600 { return L.f("time.hours", Int(seconds / 3600)) }
    return L.f("time.minutes", Int(seconds / 60))
}

func bounded(_ input: String, length: Int) -> String {
    String(input.trimmingCharacters(in: .whitespacesAndNewlines).prefix(length))
}
