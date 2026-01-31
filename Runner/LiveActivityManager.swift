import ActivityKit
import Flutter
import UIKit

final class LiveActivityManager {
  static let shared = LiveActivityManager()

  private var channel: FlutterMethodChannel?
  @available(iOS 16.1, *)
  private var currentActivity: Activity<DownloadActivityAttributes>?
  private var currentMode: String?
  private var currentTitle: String?
  private var ytMergeProgress: [String: YtMergeProgress] = [:]
  private var dashProgress: [String: DashProgressEntry] = [:]
  private var hlsProgress: [String: HlsProgressEntry] = [:]
  private var backgroundEntries: [String: BackgroundProgressEntry] = [:]
  private var backgroundCompletedCount: Int = 0
  private var backgroundCompletionNotifiedAt: Date?
  private var lastBackgroundUpdateAt: Date?

  private init() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleYtMergeProgress(_:)),
      name: .ytMergeLiveActivityProgress,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleHlsProgress(_:)),
      name: .hlsLiveActivityProgress,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleDashSegmentComplete(_:)),
      name: .dashLiveActivityProgress,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleHlsSegmentComplete(_:)),
      name: .hlsSegmentLiveActivityProgress,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleNativeNotification(_:)),
      name: .nativeNotificationShown,
      object: nil
    )
  }

  func configure(messenger: FlutterBinaryMessenger) {
    if channel != nil { return }
    let channel = FlutterMethodChannel(
      name: "yibrowser/live_activity",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    self.channel = channel
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      if #available(iOS 16.1, *) {
        result(ActivityAuthorizationInfo().areActivitiesEnabled)
      } else {
        result(false)
      }
    case "startOrUpdate":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "invalid_args", message: "Missing args", details: nil))
        return
      }
      startOrUpdate(args: args)
      result(nil)
    case "end":
      endActivity()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func endFromNativeNotification() {
    if #available(iOS 16.1, *) {
      backgroundEntries.removeAll()
      backgroundCompletedCount = 0
      backgroundCompletionNotifiedAt = nil
      ytMergeProgress.removeAll()
      dashProgress.removeAll()
      hlsProgress.removeAll()
      endActivity()
    }
  }

  private func startOrUpdate(args: [String: Any]) {
    if #available(iOS 16.1, *) {
      if !ActivityAuthorizationInfo().areActivitiesEnabled {
        return
      }
      if UIApplication.shared.applicationState == .active {
        backgroundEntries.removeAll()
        backgroundCompletedCount = 0
        backgroundCompletionNotifiedAt = nil
      }
      let mode = args["mode"] as? String ?? "group"
      let title = args["title"] as? String ?? "Downloading"
      let subtitle = args["subtitle"] as? String
      let progress = args["progress"] as? Double
      let activeCount = args["activeCount"] as? Int ?? 0
      let totalCount = args["totalCount"] as? Int ?? activeCount
      applyActivityUpdate(
        title: title,
        mode: mode,
        subtitle: subtitle,
        progress: progress,
        activeCount: activeCount,
        totalCount: totalCount
      )
    }
  }

  private func endActivity() {
    if #available(iOS 16.1, *) {
      guard let activity = currentActivity else { return }
      let contentState = DownloadActivityAttributes.ContentState(
        progress: 1,
        activeCount: 0,
        totalCount: 0
      )
      Task {
        await activity.end(using: contentState, dismissalPolicy: .immediate)
      }
      currentActivity = nil
      currentMode = nil
      currentTitle = nil
    }
  }

  @objc private func handleYtMergeProgress(_ notification: Notification) {
    if #available(iOS 16.1, *) {
      guard
        let info = notification.userInfo,
        let parent = info["parent"] as? String,
        let part = info["part"] as? String,
        let progress = info["progress"] as? Double
      else {
        return
      }
      guard progress >= 0 else { return }
      let total = info["total"] as? Double
      if UIApplication.shared.applicationState == .active {
        return
      }
      var entry = ytMergeProgress[parent] ?? YtMergeProgress()
      if part == "audio" {
        entry.audio = progress
        if let total {
          entry.audioTotal = total
        }
      } else if part == "video" {
        entry.video = progress
        if let total {
          entry.videoTotal = total
        }
      }
      entry.lastUpdate = Date()
      ytMergeProgress[parent] = entry
      updateBackgroundEntry(
        key: "yt:\(parent)",
        received: aggregateReceived(entry),
        total: aggregateTotal(entry),
        lastUpdate: entry.lastUpdate
      )
      if let audio = entry.audio,
         let video = entry.video,
         let audioTotal = entry.audioTotal,
         let videoTotal = entry.videoTotal,
         audioTotal > 0,
         videoTotal > 0 {
        let received = audio * audioTotal + video * videoTotal
        let total = audioTotal + videoTotal
        if total > 0 && received >= total {
          if backgroundEntries.removeValue(forKey: "yt:\(parent)") != nil {
            backgroundCompletedCount += 1
          }
        }
      }
      updateBackgroundLiveActivity()
    }
  }

  @objc private func handleHlsProgress(_ notification: Notification) {
    if #available(iOS 16.1, *) {
      guard let info = notification.userInfo,
            let id = info["id"] as? String else {
        return
      }
      if UIApplication.shared.applicationState == .active {
        return
      }
      if let state = info["state"] as? String, state == "complete" {
        if backgroundEntries.removeValue(forKey: "hls:\(id)") != nil {
          backgroundCompletedCount += 1
        }
        updateBackgroundLiveActivity()
        return
      }
      guard
        let received = info["received"] as? Double,
        let total = info["total"] as? Double,
        total > 0
      else {
        return
      }
      updateBackgroundEntry(
        key: "hls:\(id)",
        received: min(received, total),
        total: total,
        lastUpdate: Date()
      )
      updateBackgroundLiveActivity()
    }
  }

  @objc private func handleDashSegmentComplete(_ notification: Notification) {
    if #available(iOS 16.1, *) {
      guard
        let info = notification.userInfo,
        let parent = info["parent"] as? String,
        let track = info["track"] as? String
      else {
        return
      }
      if UIApplication.shared.applicationState == .active {
        return
      }
      var entry = dashProgress[parent] ?? DashProgressEntry()
      if let hasVideo = info["hasVideo"] as? Bool {
        entry.hasVideo = hasVideo
      }
      if let hasAudio = info["hasAudio"] as? Bool {
        entry.hasAudio = hasAudio
      }
      if let videoTotal = info["videoTotal"] as? Int {
        entry.videoTotal = videoTotal
      }
      if let audioTotal = info["audioTotal"] as? Int {
        entry.audioTotal = audioTotal
      }
      let isInit = (info["isInit"] as? Bool) ?? false
      let index = (info["index"] as? Int) ?? 0
      if track == "video" {
        if isInit {
          entry.videoInitComplete = true
        } else {
          entry.videoCompleted.insert(index)
        }
      } else if track == "audio" {
        if isInit {
          entry.audioInitComplete = true
        } else {
          entry.audioCompleted.insert(index)
        }
      }
      entry.lastUpdate = Date()
      dashProgress[parent] = entry

      let total = dashTotal(entry)
      let completed = dashCompleted(entry)
      if total > 0 {
        updateBackgroundEntry(
          key: "dash:\(parent)",
          received: min(Double(completed), Double(total)),
          total: Double(total),
          lastUpdate: entry.lastUpdate
        )
      }
      if total > 0 && completed >= total {
        if backgroundEntries.removeValue(forKey: "dash:\(parent)") != nil {
          backgroundCompletedCount += 1
        }
        dashProgress.removeValue(forKey: parent)
      }
      updateBackgroundLiveActivity()
    }
  }

  @objc private func handleHlsSegmentComplete(_ notification: Notification) {
    if #available(iOS 16.1, *) {
      guard
        let info = notification.userInfo,
        let parent = info["parent"] as? String
      else {
        return
      }
      if UIApplication.shared.applicationState == .active {
        return
      }
      let index = (info["index"] as? Int) ?? -1
      var entry = hlsProgress[parent] ?? HlsProgressEntry()
      if let total = info["total"] as? Int {
        entry.total = total
      }
      if let completedBase = info["completed"] as? Int {
        entry.baseCompleted = max(entry.baseCompleted, completedBase)
      }
      if index >= 0 {
        entry.completedIndices.insert(index)
      }
      entry.lastUpdate = Date()
      hlsProgress[parent] = entry

      let total = max(0, entry.total)
      let completed = min(total, entry.baseCompleted + entry.completedIndices.count)
      if total > 0 {
        updateBackgroundEntry(
          key: "hls-seg:\(parent)",
          received: Double(completed),
          total: Double(total),
          lastUpdate: entry.lastUpdate
        )
      }
      if total > 0 && completed >= total {
        if backgroundEntries.removeValue(forKey: "hls-seg:\(parent)") != nil {
          backgroundCompletedCount += 1
        }
        hlsProgress.removeValue(forKey: parent)
      }
      updateBackgroundLiveActivity()
    }
  }

  @available(iOS 16.1, *)
  private func applyActivityUpdate(
    title: String,
    mode: String,
    subtitle: String?,
    progress: Double?,
    activeCount: Int,
    totalCount: Int
  ) {
    if !ActivityAuthorizationInfo().areActivitiesEnabled {
      return
    }
    let contentState = DownloadActivityAttributes.ContentState(
      progress: progress,
      activeCount: activeCount,
      totalCount: totalCount,
      subtitle: subtitle
    )

    let needsRestart =
      currentActivity == nil ||
      currentMode != mode ||
      currentTitle != title

    if needsRestart {
      endActivity()
      let attributes = DownloadActivityAttributes(title: title, mode: mode)
      do {
        currentActivity = try Activity.request(
          attributes: attributes,
          contentState: contentState,
          pushType: nil
        )
        currentMode = mode
        currentTitle = title
      } catch {
        NSLog("[LiveActivity] Failed to start: %@", error.localizedDescription)
      }
    } else if let activity = currentActivity {
      Task { await activity.update(using: contentState) }
    }
  }

  private func aggregateTotal(_ entry: YtMergeProgress) -> Double {
    if let audioTotal = entry.audioTotal,
       let videoTotal = entry.videoTotal,
       audioTotal > 0,
       videoTotal > 0 {
      return audioTotal + videoTotal
    }
    return 0
  }

  private func aggregateReceived(_ entry: YtMergeProgress) -> Double {
    if let audio = entry.audio,
       let video = entry.video,
       let audioTotal = entry.audioTotal,
       let videoTotal = entry.videoTotal,
       audioTotal > 0,
       videoTotal > 0 {
      return audio * audioTotal + video * videoTotal
    }
    if let audio = entry.audio, let audioTotal = entry.audioTotal, audioTotal > 0 {
      return audio * audioTotal
    }
    if let video = entry.video, let videoTotal = entry.videoTotal, videoTotal > 0 {
      return video * videoTotal
    }
    return 0
  }

  private func shouldApplyBackgroundUpdate() -> Bool {
    let now = Date()
    if let last = lastBackgroundUpdateAt, now.timeIntervalSince(last) < 5.0 {
      return false
    }
    lastBackgroundUpdateAt = now
    return true
  }

  private func updateBackgroundEntry(key: String, received: Double, total: Double, lastUpdate: Date) {
    guard total > 0 else { return }
    if backgroundEntries.isEmpty {
      backgroundCompletedCount = 0
      backgroundCompletionNotifiedAt = nil
    }
    backgroundEntries[key] = BackgroundProgressEntry(received: received, total: total, lastUpdate: lastUpdate)
  }

  private func updateBackgroundLiveActivity() {
    pruneBackgroundEntries()
    guard UIApplication.shared.applicationState != .active else { return }
    guard shouldApplyBackgroundUpdate() else { return }
    let count = backgroundEntries.count
    if count == 0 {
      if backgroundCompletedCount > 0 {
        let now = Date()
        if backgroundCompletionNotifiedAt == nil {
          backgroundCompletionNotifiedAt = now
          DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.applyActivityUpdate(
              title: self.currentTitle ?? "Downloading",
              mode: "single",
              subtitle: "Background downloading",
              progress: 1.0,
              activeCount: self.backgroundCompletedCount,
              totalCount: self.backgroundCompletedCount
            )
          }
        }
      }
      return
    }
    let summary = summarizeBackgroundEntries()
    let progress = summary.total > 0 ? summary.received / summary.total : nil
    let totalCount = backgroundCompletedCount + count
    let mode = totalCount <= 1 ? "single" : "group"
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.applyActivityUpdate(
        title: self.currentTitle ?? "Downloading",
        mode: mode,
        subtitle: "Background downloading",
        progress: progress,
        activeCount: self.backgroundCompletedCount,
        totalCount: totalCount
      )
    }
  }

  @objc private func handleNativeNotification(_ notification: Notification) {
    endFromNativeNotification()
  }

  private func pruneBackgroundEntries() {
    let cutoff = Date().addingTimeInterval(-600)
    backgroundEntries = backgroundEntries.filter { $0.value.lastUpdate >= cutoff }
    ytMergeProgress = ytMergeProgress.filter { $0.value.lastUpdate >= cutoff }
    dashProgress = dashProgress.filter { $0.value.lastUpdate >= cutoff }
    hlsProgress = hlsProgress.filter { $0.value.lastUpdate >= cutoff }
  }

  private func summarizeBackgroundEntries() -> (received: Double, total: Double) {
    var received = 0.0
    var total = 0.0
    for entry in backgroundEntries.values {
      received += entry.received
      total += entry.total
    }
    return (received, total)
  }

  private func dashTotal(_ entry: DashProgressEntry) -> Int {
    var total = 0
    if entry.hasVideo {
      total += entry.videoTotal
      if entry.videoInitComplete || entry.videoTotal > 0 {
        total += 1
      }
    }
    if entry.hasAudio {
      total += entry.audioTotal
      if entry.audioInitComplete || entry.audioTotal > 0 {
        total += 1
      }
    }
    return total
  }

  private func dashCompleted(_ entry: DashProgressEntry) -> Int {
    var completed = 0
    if entry.hasVideo {
      completed += entry.videoCompleted.count
      if entry.videoInitComplete {
        completed += 1
      }
    }
    if entry.hasAudio {
      completed += entry.audioCompleted.count
      if entry.audioInitComplete {
        completed += 1
      }
    }
    return completed
  }
}

private struct YtMergeProgress {
  var audio: Double?
  var video: Double?
  var audioTotal: Double?
  var videoTotal: Double?
  var lastUpdate: Date = Date()
}

private struct BackgroundProgressEntry {
  let received: Double
  let total: Double
  let lastUpdate: Date
}

private struct DashProgressEntry {
  var hasVideo: Bool = false
  var hasAudio: Bool = false
  var videoTotal: Int = 0
  var audioTotal: Int = 0
  var videoInitComplete: Bool = false
  var audioInitComplete: Bool = false
  var videoCompleted: Set<Int> = []
  var audioCompleted: Set<Int> = []
  var lastUpdate: Date = Date()
}

private struct HlsProgressEntry {
  var total: Int = 0
  var baseCompleted: Int = 0
  var completedIndices: Set<Int> = []
  var lastUpdate: Date = Date()
}

private extension Notification.Name {
  static let ytMergeLiveActivityProgress = Notification.Name("yibrowser.live_activity.yt_merge_progress")
  static let hlsLiveActivityProgress = Notification.Name("yibrowser.live_activity.hls_progress")
  static let dashLiveActivityProgress = Notification.Name("yibrowser.live_activity.dash_segment")
  static let hlsSegmentLiveActivityProgress = Notification.Name("yibrowser.live_activity.hls_segment")
  static let nativeNotificationShown = Notification.Name("yibrowser.live_activity.end")
}
