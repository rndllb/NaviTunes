import AppIntents
import Foundation

// Darwin notification name used for cross-process signalling between widget and app.
let widgetCommandNotification = "com.randll.vellum.widgetCommand" as CFString
let widgetCommandKey = "widgetCommand"
let widgetCommandPlay = "play"
let widgetCommandToggle = "toggle"
let widgetCommandPlayIdKey = "widgetPendingPlayId"
let widgetCommandPlayKindKey = "widgetPendingPlayKind"

private func postWidgetCommand(_ command: String, itemId: String? = nil, itemKind: String? = nil) {
    let defaults = UserDefaults(suiteName: WidgetDataStore.appGroupID)
    defaults?.set(command, forKey: widgetCommandKey)
    if let itemId { defaults?.set(itemId, forKey: widgetCommandPlayIdKey) }
    if let itemKind { defaults?.set(itemKind, forKey: widgetCommandPlayKindKey) }
    defaults?.synchronize()
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFNotificationName(widgetCommandNotification),
        nil, nil, true
    )
}

// MARK: - Toggle Playback

public struct TogglePlaybackIntent: AppIntent {
    public static var title: LocalizedStringResource = "Toggle Playback from Widget"
    public static var openAppWhenRun: Bool = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        postWidgetCommand(widgetCommandToggle)
        return .result()
    }
}

// MARK: - Play Item

public struct PlayWidgetItemIntent: AppIntent {
    public static var title: LocalizedStringResource = "Play from Vellum Widget"
    public static var openAppWhenRun: Bool = false

    @Parameter(title: "Item ID")
    public var itemId: String

    @Parameter(title: "Item Kind")
    public var itemKind: String

    public init() {}

    public init(itemId: String, itemKind: String) {
        self.itemId = itemId
        self.itemKind = itemKind
    }

    public func perform() async throws -> some IntentResult {
        postWidgetCommand(widgetCommandPlay, itemId: itemId, itemKind: itemKind)
        return .result()
    }
}
