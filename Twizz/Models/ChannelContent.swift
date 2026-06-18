import Foundation

/// A highlight clip from a channel, shown in the channel page's "Clips" row.
/// Clips resolve to a direct MP4 and play in the native on-demand player.
struct ChannelClip: Identifiable, Hashable {
  let slug: String
  let title: String
  let viewCount: Int
  let durationSeconds: Int
  let thumbnailURL: URL?
  let gameName: String?
  let createdAt: Date?

  var id: String { slug }
}

/// A past broadcast (VOD) from a channel, shown in the "Past Broadcasts" row.
/// VODs resolve to a seekable HLS playlist and play in the on-demand player.
struct ChannelVOD: Identifiable, Hashable {
  let id: String
  let title: String
  let lengthSeconds: Int
  let thumbnailURL: URL?
  let gameName: String?
  let publishedAt: Date?
  let viewCount: Int
}
