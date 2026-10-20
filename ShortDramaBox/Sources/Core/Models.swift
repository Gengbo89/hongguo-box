import Foundation

struct Series: Identifiable, Hashable, Codable {
    let id: String
    var title: String = ""
    var cover: String = ""
    var intro: String = ""
    var episodeCount: Int = 0
    var accessibleCount: Int = 0
    var rightText: String = ""
    var tags: [String] = []
}

struct Episode: Identifiable, Hashable {
    let index: Int
    let vid: String
    var id: Int { index }
}

struct VideoTrack: Hashable {
    var definition: String = ""
    var width: Int = 0
    var height: Int = 0
    var size: Int = 0
    var url: String = ""
    var spadeA: String = ""
    var codec: String = ""
}

struct HomeSection: Identifiable, Hashable {
    let id: String
    let name: String
    let items: [Series]
}
