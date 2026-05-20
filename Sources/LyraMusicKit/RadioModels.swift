import Foundation

/// Internet radio entry from Subsonic ``getInternetRadioStations`` (Navidrome).
struct InternetRadioStation: Identifiable, Hashable {
    let id: String
    let name: String
    let streamURL: URL
    let homepageURL: URL?
}

/// Genre-based station surfaced on the Radio tab (library shuffle by tag).
struct RadioGenreStation: Identifiable, Hashable {
    var id: String { genre.name }
    let genre: LibraryGenreSummary
}
