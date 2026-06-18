import Foundation

/// A channel shown in the Home -> Following carousel.
struct FollowedChannel: Identifiable, Hashable {
    let id: String
    let login: String
    let displayName: String
    let title: String
    let gameName: String
    let viewerCount: Int?
    let thumbnailURL: URL?
    let profileImageURL: URL?
    let isLive: Bool
    let isMature: Bool

    init(
        id: String,
        login: String,
        displayName: String,
        title: String,
        gameName: String,
        viewerCount: Int?,
        thumbnailURL: URL?,
        profileImageURL: URL?,
        isLive: Bool,
        isMature: Bool = false
    ) {
        self.id = id
        self.login = login
        self.displayName = displayName
        self.title = title
        self.gameName = gameName
        self.viewerCount = viewerCount
        self.thumbnailURL = thumbnailURL
        self.profileImageURL = profileImageURL
        self.isLive = isLive
        self.isMature = isMature
    }
}
