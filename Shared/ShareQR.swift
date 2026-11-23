import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

enum ShareQR {
    static func destination(storeID: String) -> URL {
        if !storeID.isEmpty, storeID.utf8.allSatisfy({ (48...57).contains($0) }),
           let url = URL(string: "https://apps.apple.com/app/id" + storeID) { return url }
        return URL(string: "https://apps.apple.com/")!
    }

    static func image(url: URL) -> CIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        return filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 9, y: 9))
    }
}
