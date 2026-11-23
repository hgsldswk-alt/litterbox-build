import Foundation

enum Launch {
    static let freePeriod = false
    static let uiTesting = ProcessInfo.processInfo.arguments.contains("-ui-testing")
    static func has(_ flag: String) -> Bool {
        uiTesting && ProcessInfo.processInfo.arguments.contains(flag)
    }
    static var isFree: Bool { freePeriod && !has("-paid-mode") && !has("-expired") && !has("-paywall") }
}
