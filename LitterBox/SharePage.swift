import CoreImage
import SwiftUI
import UIKit

enum ShareContent {
    case result(TrialComparison), milestone(Date)
    var id: String {
        switch self {
        case .result(let pair): return pair.first.id.uuidString + pair.second.id.uuidString
        case .milestone(let date): return String(date.timeIntervalSince1970)
        }
    }
    var caption: String {
        switch self {
        case .result(let pair): return L.f("share.caption", pair.span)
        case .milestone: return L.t("milestone.caption")
        }
    }
}

struct SharePage: View {
    @EnvironmentObject private var model: AppModel
    let content: ShareContent
    @State private var qr: CGImage?
    @State private var activity: SharedImage?
    @State private var copied = false

    private var storeID: String { Bundle.main.infoDictionary?["APP_STORE_ID"] as? String ?? "" }
    private var allowed: Bool {
        switch content {
        case .result: return model.pro
        case .milestone: return true
        }
    }

    var body: some View {
        Page {
            if allowed {
                ShareArtwork(content: content, qr: qr, isPlaceholder: storeID.isEmpty)
                    .accessibilityIdentifier("share.preview")
                Action(key: "share.image", id: "share.image", primary: true, enabled: qr != nil) { generate() }
                Action(key: "share.caption.copy", id: "share.caption") {
                    if !Launch.uiTesting { UIPasteboard.general.string = content.caption }
                    copied = true
                }
                if copied { Text(L.t("share.copied")).font(.footnote) }
                if Launch.uiTesting && model.shareRequested {
                    Text(L.t("share.requested")).font(.footnote).accessibilityIdentifier("share.requested")
                }
            } else {
                Surface { Text(L.t("trial.readonly")) }
            }
        }
        .sheetTitle("share.title")
        .task {
            model.shareRequested = false
            let url = ShareQR.destination(storeID: storeID)
            qr = await Task.detached(priority: .userInitiated) {
                guard let image = ShareQR.image(url: url) else { return nil as CGImage? }
                return CIContext().createCGImage(image, from: image.extent)
            }.value
        }
        .sheet(item: $activity) { item in
            ActivitySheet(items: [item.image, content.caption])
        }
    }

    @MainActor
    private func generate() {
        let view = ShareArtwork(content: content, qr: qr, isPlaceholder: storeID.isEmpty)
            .environment(\.dynamicTypeSize, .medium)
            .frame(width: 360, height: 450)
            .background(Palette.paper)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        renderer.isOpaque = true
        guard let image = renderer.uiImage, let pixels = image.cgImage, pixels.width == 1080, pixels.height == 1350 else {
            model.error = "error.share"
            return
        }
        if Launch.uiTesting { model.shareRequested = true }
        else { activity = SharedImage(image: image) }
    }
}

private struct SharedImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct ShareArtwork: View {
    let content: ShareContent
    let qr: CGImage?
    let isPlaceholder: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            switch content {
            case .result(let pair):
                Text(L.f("share.sample", pair.span)).font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                if let conclusion = pair.conclusion(.clump) {
                    Text(conclusion).font(.title2.bold()).lineLimit(3).minimumScaleFactor(0.75)
                }
                ForEach([RatingAxis.odor, .dust]) { axis in
                    if let detail = pair.conclusion(axis) {
                        Text(detail).font(.caption).lineLimit(2).minimumScaleFactor(0.7)
                    }
                }
                ComparisonTable(pair: pair, counts: true).lineLimit(2).minimumScaleFactor(0.65)
                Text(L.f("share.days", pair.daysLogged(pair.first), pair.daysLogged(pair.second)))
                    .font(.caption).foregroundStyle(Palette.muted)
            case .milestone:
                Text("30").font(.system(size: 76, weight: .bold, design: .rounded)).foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)
                Text(L.t("milestone.title")).font(.largeTitle.bold())
                Text(L.t("milestone.detail")).font(.subheadline).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 7)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L.t("share.tags")).font(.caption.weight(.semibold))
                    Text(L.t("app.name")).font(.caption)
                    Text(L.t(isPlaceholder ? "share.qr.preview" : "share.qr.app")).font(.caption2)
                }
                Spacer()
                if let qr {
                    Image(decorative: qr, scale: 1)
                        .interpolation(.none).resizable().scaledToFit().frame(width: 64, height: 64)
                        .padding(9).background(.white)
                        .accessibilityLabel(L.t("share.qr.label"))
                }
            }
            .foregroundStyle(Palette.muted)
        }
        .foregroundStyle(Palette.ink)
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.sand, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct ActivitySheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
