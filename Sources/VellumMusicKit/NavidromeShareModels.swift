import Foundation

struct NavidromeShareEntry: Identifiable, Equatable, Codable {
    let id: String
    let url: URL
    let description: String?
    let created: Date?
    let expires: Date?
    let visitCount: Int
    let maxVisits: Int?
    let entry: NavidromeShareTarget?
}

struct NavidromeShareTarget: Equatable, Codable {
    let id: String
    let title: String?
    let artist: String?
    let album: String?
    let kind: String?
}

struct NavidromeScanStatus: Equatable {
    let scanning: Bool
    let count: Int
    let total: Int
}
