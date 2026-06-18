import Foundation

struct TwitchCategory: Identifiable, Hashable {
    let id: String
    let name: String
    let boxArtURL: URL?
    let viewerCount: Int?
    let isMature: Bool

    init(
        id: String,
        name: String,
        boxArtURL: URL?,
        viewerCount: Int?,
        isMature: Bool = false
    ) {
        self.id = id
        self.name = name
        self.boxArtURL = boxArtURL
        self.viewerCount = viewerCount
        self.isMature = isMature
    }
}
