import ActivityKit

@available(iOS 16.1, *)
struct DownloadActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    var progress: Double?
    var activeCount: Int
    var totalCount: Int
    var subtitle: String?
  }

  var title: String
  var mode: String
}
