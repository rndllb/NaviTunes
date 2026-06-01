import SwiftUI

/// Local text drafts so typing in Settings does not publish every keystroke to ``AppModel``.
@MainActor
enum SettingsFormDrafts {
    static func pullServer(from app: AppModel, into drafts: inout ServerConnectionDraft) {
        drafts.baseURL = app.baseURLString
        drafts.secondaryURL = app.secondaryURLString
        drafts.username = app.username
        drafts.password = app.password
    }

    static func pushServer(_ drafts: ServerConnectionDraft, to app: AppModel) {
        app.baseURLString = drafts.baseURL
        app.secondaryURLString = drafts.secondaryURL
        app.username = drafts.username
        app.password = drafts.password
    }
}

struct ServerConnectionDraft: Equatable {
    var baseURL: String = ""
    var secondaryURL: String = ""
    var username: String = ""
    var password: String = ""
}
