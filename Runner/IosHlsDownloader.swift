import Foundation
import AVFoundation
import Flutter
import UIKit
import UserNotifications

private extension Notification.Name {
  static let hlsLiveActivityProgress = Notification.Name("yibrowser.live_activity.hls_progress")
  static let nativeNotificationShown = Notification.Name("yibrowser.live_activity.end")
}

private struct HlsDownloadMeta {
  let id: String
  let destination: URL
  let headers: [String: String]
  let notificationTitle: String?
  let notificationBody: String?
  let errorTitle: String?
  let errorBody: String?
}

private struct HlsByteProgress {
  let received: Int64
  let expected: Int64
}

private struct HlsTimeProgress {
  var receivedMs: Int
  var totalMs: Int
}

final class IosHlsDownloader: NSObject, FlutterStreamHandler, AVAssetDownloadDelegate, URLSessionDelegate {
  static let shared = IosHlsDownloader()
  private static var notificationAuthStatus: UNAuthorizationStatus?
  private static var notificationAuthCheckedAt: Date?
  private static let notificationAuthTTL: TimeInterval = 30

  private let sessionIdentifier = "com.yibrowser.hls.downloader"
  private var methodChannel: FlutterMethodChannel?
  private var eventChannel: FlutterEventChannel?
  private var eventSink: FlutterEventSink?
  private var session: AVAssetDownloadURLSession?
  private var metaByTaskId: [String: HlsDownloadMeta] = [:]
  private var exportingIds: Set<String> = []
  private var exportSessions: [String: AVAssetExportSession] = [:]
  private var byteProgressById: [String: HlsByteProgress] = [:]
  private var timeProgressById: [String: HlsTimeProgress] = [:]
  private var activeTasksById: [String: AVAssetDownloadTask] = [:]
  private var progressTimers: [String: DispatchSourceTimer] = [:]
  private var backgroundTaskIds: [String: UIBackgroundTaskIdentifier] = [:]
  private var downloadLocationById: [String: URL] = [:]
  private var backgroundCompletion: (() -> Void)?
  private let syncQueue = DispatchQueue(label: "com.yibrowser.hls.downloader.sync")

  private override init() {
    super.init()
  }

  func configure(messenger: FlutterBinaryMessenger) {
    guard methodChannel == nil else { return }

    let method = FlutterMethodChannel(name: "hls.downloader", binaryMessenger: messenger)
    method.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    methodChannel = method

    let event = FlutterEventChannel(name: "hls.downloader/events", binaryMessenger: messenger)
    event.setStreamHandler(self)
    eventChannel = event

    let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
    configuration.httpMaximumConnectionsPerHost = 6
    configuration.waitsForConnectivity = true
    configuration.sessionSendsLaunchEvents = true
    configuration.allowsCellularAccess = true
    configuration.isDiscretionary = false
    configuration.networkServiceType = .video
    if #available(iOS 13.0, *) {
      configuration.allowsConstrainedNetworkAccess = true
      configuration.allowsExpensiveNetworkAccess = true
    }

    session = AVAssetDownloadURLSession(configuration: configuration, assetDownloadDelegate: self, delegateQueue: nil)
    restorePendingTasks()
  }

  func handleEventsForBackgroundSession(identifier: String, completion: @escaping () -> Void) {
    guard identifier == sessionIdentifier else { return }
    syncQueue.async {
      self.backgroundCompletion = completion
      self.checkBackgroundCompletionIfNeeded()
    }
  }

  // MARK: - Flutter bridge

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      guard
        let args = call.arguments as? [String: Any],
        let id = args["id"] as? String,
        let urlString = args["url"] as? String,
        let destinationPath = args["destinationPath"] as? String,
        let url = URL(string: urlString)
      else {
        result(FlutterError(code: "invalid_args", message: "Missing id/url/destination", details: nil))
        return
      }
      let headers = args["headers"] as? [String: String] ?? [:]
      let notificationTitle = args["notificationTitle"] as? String
      let notificationBody = args["notificationBody"] as? String
      let errorTitle = args["notificationErrorTitle"] as? String
      let errorBody = args["notificationErrorBody"] as? String
      startDownload(
        id: id,
        url: url,
        destinationPath: destinationPath,
        headers: headers,
        notificationTitle: notificationTitle,
        notificationBody: notificationBody,
        errorTitle: errorTitle,
        errorBody: errorBody,
        result: result
      )

    case "cancel":
      guard let args = call.arguments as? [String: Any], let id = args["id"] as? String else {
        result(FlutterError(code: "invalid_args", message: "Missing id", details: nil))
        return
      }
      cancel(id: id)
      result(nil)

    case "pause":
      guard let args = call.arguments as? [String: Any], let id = args["id"] as? String else {
        result(FlutterError(code: "invalid_args", message: "Missing id", details: nil))
        return
      }
      pause(id: id)
      result(nil)
    case "exportOffline":
      guard
        let args = call.arguments as? [String: Any],
        let sourcePath = args["sourcePath"] as? String,
        let destinationPath = args["destinationPath"] as? String
      else {
        result(FlutterError(code: "invalid_args", message: "Missing source/destination", details: nil))
        return
      }
      exportOfflineAsset(
        sourcePath: sourcePath,
        destinationPath: destinationPath,
        result: result
      )

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func exportOfflineAsset(
    sourcePath: String,
    destinationPath: String,
    result: @escaping FlutterResult
  ) {
    let sourceURL = URL(fileURLWithPath: sourcePath)
    let destinationURL = URL(fileURLWithPath: destinationPath)
    syncQueue.async {
      let fm = FileManager.default
      do {
        let dir = destinationURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
          try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: destinationURL.path) {
          try fm.removeItem(at: destinationURL)
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "export_prep_failed", message: error.localizedDescription, details: nil))
        }
        return
      }

      let asset = AVURLAsset(url: sourceURL)
      guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
        DispatchQueue.main.async {
          result(FlutterError(code: "export_init_failed", message: "Unable to create export session", details: nil))
        }
        return
      }
      exportSession.outputURL = destinationURL
      if exportSession.supportedFileTypes.contains(.mp4) {
        exportSession.outputFileType = .mp4
      } else if let first = exportSession.supportedFileTypes.first {
        exportSession.outputFileType = first
      }
      exportSession.shouldOptimizeForNetworkUse = true
      exportSession.exportAsynchronously {
        DispatchQueue.main.async {
          switch exportSession.status {
          case .completed:
            result(destinationURL.path)
          case .failed, .cancelled:
            let message = exportSession.error?.localizedDescription ?? "Export failed"
            result(FlutterError(code: "export_failed", message: message, details: nil))
          default:
            result(FlutterError(code: "export_failed", message: "Export incomplete", details: nil))
          }
        }
      }
    }
  }

  private func startDownload(
    id: String,
    url: URL,
    destinationPath: String,
    headers: [String: String],
    notificationTitle: String?,
    notificationBody: String?,
    errorTitle: String?,
    errorBody: String?,
    result: @escaping FlutterResult
  ) {
    guard let session = session else {
      NSLog("[HLS] start failed: session not ready id=%@", id)
      sendEvent(["event": "debug", "id": id, "message": "session not ready"])
      result(FlutterError(code: "session_unavailable", message: "Session not ready", details: nil))
      return
    }

    syncQueue.async {
      let destinationURL = URL(fileURLWithPath: destinationPath)
      self.sendEvent(["event": "debug", "id": id, "message": "startDownload invoked"])
      if self.exportingIds.contains(id) || self.exportSessions[id] != nil {
        DispatchQueue.main.async { result(nil) }
        return
      }

      let existingTask = self.currentTask(for: id)
      if let existingTask {
        switch existingTask.state {
        case .running, .suspended:
          let meta = HlsDownloadMeta(
            id: id,
            destination: destinationURL,
            headers: headers,
            notificationTitle: notificationTitle,
            notificationBody: notificationBody,
            errorTitle: errorTitle,
            errorBody: errorBody
          )
          existingTask.taskDescription = self.encode(meta: meta)
          self.metaByTaskId[id] = meta
          self.activeTasksById[id] = existingTask
          if existingTask.state == .suspended {
            existingTask.resume()
          }
          self.startProgressTimer(id: id)
          DispatchQueue.main.async { result(nil) }
          return
        default:
          existingTask.cancel()
        }
      }

      self.metaByTaskId.removeValue(forKey: id)
      self.exportingIds.remove(id)
      if let exportingSession = self.exportSessions.removeValue(forKey: id) {
        exportingSession.cancelExport()
      }
      if let backgroundId = self.backgroundTaskIds.removeValue(forKey: id) {
        self.endBackgroundTask(backgroundId)
      }
      self.byteProgressById.removeValue(forKey: id)
      self.timeProgressById.removeValue(forKey: id)
      self.prepareDestination(url: destinationURL)

      let assetOptions: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": headers]
      let asset = AVURLAsset(url: url, options: assetOptions)
      NSLog("[HLS] start id=%@ url=%@", id, url.absoluteString)

      let task = session.makeAssetDownloadTask(
        asset: asset,
        assetTitle: id,
        assetArtworkData: nil,
        options: nil
      )

      guard let downloadTask = task else {
        let message = "Unable to create AVAssetDownloadTask"
        NSLog("[HLS] start failed id=%@ url=%@ reason=%@", id, url.absoluteString, message)
        self.sendEvent([
          "event": "error",
          "id": id,
          "message": message,
        ])
        self.sendEvent([
          "event": "debug",
          "id": id,
          "message": "makeAssetDownloadTask returned nil",
        ])
        DispatchQueue.main.async {
          result(FlutterError(code: "task_creation_failed", message: message, details: nil))
        }
        return
      }

      let meta = HlsDownloadMeta(
        id: id,
        destination: destinationURL,
        headers: headers,
        notificationTitle: notificationTitle,
        notificationBody: notificationBody,
        errorTitle: errorTitle,
        errorBody: errorBody
      )
      downloadTask.taskDescription = self.encode(meta: meta)
      self.metaByTaskId[id] = meta
      downloadTask.priority = URLSessionTask.highPriority
      self.activeTasksById[id] = downloadTask
      self.sendEvent(["event": "debug", "id": id, "message": "task resume()"])
      downloadTask.resume()
      self.startProgressTimer(id: id)
      DispatchQueue.main.async { result(nil) }
    }
  }

  private func cancel(id: String) {
    syncQueue.async {
      let task = self.currentTask(for: id)
      task?.cancel()
      self.activeTasksById.removeValue(forKey: id)
      self.stopProgressTimer(id: id)
      let meta = self.metaByTaskId.removeValue(forKey: id)
      if let session = self.exportSessions.removeValue(forKey: id) {
        session.cancelExport()
      }
      self.exportingIds.remove(id)
      self.byteProgressById.removeValue(forKey: id)
      self.timeProgressById.removeValue(forKey: id)
      if let location = self.downloadLocationById.removeValue(forKey: id) {
        try? FileManager.default.removeItem(at: location)
      }
      if let backgroundId = self.backgroundTaskIds.removeValue(forKey: id) {
        self.endBackgroundTask(backgroundId)
      }
      if let destination = meta?.destination {
        try? FileManager.default.removeItem(at: destination)
      }
      self.sendEvent(["event": "cancelled", "id": id])
      self.checkBackgroundCompletionIfNeeded()
    }
  }

  private func pause(id: String) {
    syncQueue.async {
      let task = self.currentTask(for: id)
      task?.suspend()
      self.sendEvent(["event": "cancelled", "id": id])
    }
  }

  private func startProgressTimer(id: String) {
    stopProgressTimer(id: id)
    let timer = DispatchSource.makeTimerSource(queue: syncQueue)
    timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
    timer.setEventHandler { [weak self] in
      guard let self = self else { return }
      guard let task = self.activeTasksById[id] else {
        self.stopProgressTimer(id: id)
        return
      }
      let fraction = max(0.0, min(1.0, task.progress.fractionCompleted))
      let receivedBytes = task.countOfBytesReceived
      let expectedBytes = task.countOfBytesExpectedToReceive
      var payload: [String: Any] = [
        "event": "progress",
        "id": id,
        "receivedMs": 0,
        "totalMs": 0,
        "fraction": fraction,
      ]
      if receivedBytes > 0 {
        payload["receivedBytes"] = receivedBytes
      }
      if expectedBytes > 0 {
        payload["totalBytes"] = expectedBytes
      }
      self.sendEvent(payload)
      self.postLiveActivityProgress(
        id: id,
        received: receivedBytes > 0 ? Double(receivedBytes) : fraction,
        total: expectedBytes > 0 ? Double(expectedBytes) : 1.0
      )
    }
    progressTimers[id] = timer
    timer.resume()
  }

  private func stopProgressTimer(id: String) {
    if let timer = progressTimers.removeValue(forKey: id) {
      timer.cancel()
    }
  }

  private func currentTask(for id: String) -> AVAssetDownloadTask? {
    guard let session = session else { return nil }
    var found: AVAssetDownloadTask?
    let semaphore = DispatchSemaphore(value: 0)
    session.getAllTasks { tasks in
      found = tasks.compactMap { $0 as? AVAssetDownloadTask }.first { task in
        self.decode(description: task.taskDescription)?.id == id
      }
      semaphore.signal()
    }
    semaphore.wait()
    return found
  }

  private func restorePendingTasks() {
    guard let session = session else { return }
    session.getAllTasks { tasks in
      self.syncQueue.async {
        tasks.compactMap { $0 as? AVAssetDownloadTask }.forEach { task in
          if let decoded = self.decode(description: task.taskDescription) {
            let destination = decoded.destination ?? self.defaultDestination(for: decoded.id)
            if self.metaByTaskId[decoded.id] == nil {
              self.metaByTaskId[decoded.id] = HlsDownloadMeta(
                id: decoded.id,
                destination: destination,
                headers: [:],
                notificationTitle: decoded.notificationTitle,
                notificationBody: decoded.notificationBody,
                errorTitle: decoded.errorTitle,
                errorBody: decoded.errorBody
              )
            }
          }
        }
      }
    }
  }

  private func prepareDestination(url: URL) {
    let fm = FileManager.default
    if fm.fileExists(atPath: url.path) {
      try? fm.removeItem(at: url)
    }
    let dir = url.deletingLastPathComponent()
    if !fm.fileExists(atPath: dir.path) {
      try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    do {
      try fm.setAttributes([
        .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
      ], ofItemAtPath: dir.path)
    } catch {}
    var resourceValues = URLResourceValues()
    resourceValues.isExcludedFromBackup = true
    var mutableDir = dir
    try? mutableDir.setResourceValues(resourceValues)
  }

  private func defaultDestination(for id: String) -> URL {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    return docs.appendingPathComponent("")
      .appendingPathComponent("downloads")
      .appendingPathComponent("\(id).movpkg")
  }

  private func persistDownloadedAsset(
    id: String,
    from sourceURL: URL,
    to destinationURL: URL
  ) -> URL? {
    let fm = FileManager.default
    do {
      if fm.fileExists(atPath: destinationURL.path) {
        try fm.removeItem(at: destinationURL)
      }
      let parent = destinationURL.deletingLastPathComponent()
      if !fm.fileExists(atPath: parent.path) {
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
      }
      try fm.moveItem(at: sourceURL, to: destinationURL)
      var resourceValues = URLResourceValues()
      resourceValues.isExcludedFromBackup = true
      var mutable = destinationURL
      try? mutable.setResourceValues(resourceValues)
      return destinationURL
    } catch {
      do {
        if fm.fileExists(atPath: destinationURL.path) {
          try fm.removeItem(at: destinationURL)
        }
        try fm.copyItem(at: sourceURL, to: destinationURL)
        try? fm.removeItem(at: sourceURL)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutable = destinationURL
        try? mutable.setResourceValues(resourceValues)
        return destinationURL
      } catch {
        NSLog("[HLS] persist failed id=%@ error=%@", id, error.localizedDescription)
        return nil
      }
    }
  }

  private func encode(meta: HlsDownloadMeta) -> String? {
    var dict: [String: Any] = [
      "id": meta.id,
      "destination": meta.destination.path,
    ]
    if let title = meta.notificationTitle, !title.isEmpty {
      dict["notificationTitle"] = title
    }
    if let body = meta.notificationBody, !body.isEmpty {
      dict["notificationBody"] = body
    }
    if let title = meta.errorTitle, !title.isEmpty {
      dict["notificationErrorTitle"] = title
    }
    if let body = meta.errorBody, !body.isEmpty {
      dict["notificationErrorBody"] = body
    }
    guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []) else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  private func decode(description: String?) -> (id: String, destination: URL?, notificationTitle: String?, notificationBody: String?, errorTitle: String?, errorBody: String?)? {
    guard let description,
          let data = description.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data, options: []),
          let dict = json as? [String: Any],
          let id = dict["id"] as? String
    else {
      return nil
    }
    var destinationURL: URL?
    if let path = dict["destination"] as? String, !path.isEmpty {
      destinationURL = URL(fileURLWithPath: path)
    }
    let notificationTitle = dict["notificationTitle"] as? String
    let notificationBody = dict["notificationBody"] as? String
    let errorTitle = dict["notificationErrorTitle"] as? String
    let errorBody = dict["notificationErrorBody"] as? String
    return (
      id,
      destinationURL,
      notificationTitle,
      notificationBody,
      errorTitle,
      errorBody
    )
  }

  // MARK: - AVAssetDownloadDelegate

  func urlSession(
    _ session: URLSession,
    assetDownloadTask: AVAssetDownloadTask,
    didLoad loadedTimeRanges: [NSValue],
    totalTimeRangesLoaded loaded: CMTimeRange,
    timeRangeExpectedToLoad timeRangeExpectedToLoad: CMTimeRange
  ) {
    guard let decoded = decode(description: assetDownloadTask.taskDescription) else { return }
    let id = decoded.id
    let loadedDuration = loaded.duration.seconds
    let expectedDuration = timeRangeExpectedToLoad.duration.seconds
    let hasTime = expectedDuration.isFinite && expectedDuration > 0
    let progress = hasTime ? max(0.0, min(1.0, loadedDuration / expectedDuration)) : 0.0
    let fraction = max(0.0, min(1.0, assetDownloadTask.progress.fractionCompleted))
    let rawTotalMs = hasTime ? max(Int(expectedDuration * 1000), 0) : 0
    let rawReceivedMs = hasTime ? max(Int(Double(rawTotalMs) * progress), 0) : 0
    let receivedBytes = assetDownloadTask.countOfBytesReceived
    let expectedBytes = assetDownloadTask.countOfBytesExpectedToReceive
    var finalTotalMs = rawTotalMs
    var finalReceivedMs = rawReceivedMs
    syncQueue.sync {
      if receivedBytes > 0 || expectedBytes > 0 {
        self.byteProgressById[id] = HlsByteProgress(
          received: max(receivedBytes, 0),
          expected: max(expectedBytes, 0)
        )
      }
      var timeProgress = self.timeProgressById[id] ?? HlsTimeProgress(receivedMs: 0, totalMs: 0)
      if rawTotalMs > 0 {
        if timeProgress.totalMs <= 0 {
          timeProgress.totalMs = rawTotalMs
        } else if rawTotalMs > timeProgress.totalMs {
          timeProgress.totalMs = rawTotalMs
        }
      }
      finalTotalMs = timeProgress.totalMs > 0 ? timeProgress.totalMs : rawTotalMs
      if finalTotalMs <= 0 {
        finalTotalMs = rawTotalMs
      }
      timeProgress.receivedMs = max(timeProgress.receivedMs, rawReceivedMs)
      if finalTotalMs > 0 {
        timeProgress.receivedMs = min(timeProgress.receivedMs, finalTotalMs)
      }
      finalReceivedMs = timeProgress.receivedMs
      self.timeProgressById[id] = timeProgress
    }
    var payload: [String: Any] = [
      "event": "progress",
      "id": id,
      "receivedMs": finalReceivedMs,
      "totalMs": finalTotalMs,
      "fraction": fraction,
    ]
    if receivedBytes > 0 {
      payload["receivedBytes"] = receivedBytes
    }
    if expectedBytes > 0 {
      payload["totalBytes"] = expectedBytes
    }
    sendEvent(payload)
    postLiveActivityProgress(
      id: id,
      received: receivedBytes > 0 ? Double(receivedBytes) : Double(finalReceivedMs),
      total: expectedBytes > 0 ? Double(expectedBytes) : Double(finalTotalMs)
    )
  }

  func urlSession(
    _ session: URLSession,
    assetDownloadTask: AVAssetDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    guard let decoded = decode(description: assetDownloadTask.taskDescription) else { return }
    let id = decoded.id
    syncQueue.async {
      self.downloadLocationById[id] = location
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    guard let downloadTask = task as? AVAssetDownloadTask else {
      return
    }

    guard let decoded = decode(description: downloadTask.taskDescription) else {
      if let error {
        let nsError = error as NSError
        NSLog(
          "[HLS] complete missing description error domain=%@ code=%d userInfo=%@",
          nsError.domain,
          nsError.code,
          nsError.userInfo.description
        )
      } else {
        NSLog("[HLS] complete missing description (no error)")
      }
      return
    }
    let id = decoded.id

    syncQueue.async {
        self.activeTasksById.removeValue(forKey: id)
        self.stopProgressTimer(id: id)
        if let error {
          self.metaByTaskId.removeValue(forKey: id)
          self.byteProgressById.removeValue(forKey: id)
          self.timeProgressById.removeValue(forKey: id)
          self.downloadLocationById.removeValue(forKey: id)
          let nsError = error as NSError
          NSLog(
            "[HLS] complete error id=%@ domain=%@ code=%d userInfo=%@",
            id,
            nsError.domain,
            nsError.code,
            nsError.userInfo.description
          )
          if nsError.code == NSURLErrorCancelled {
            self.postLiveActivityComplete(id: id)
            self.checkBackgroundCompletionIfNeeded()
            return
          }
        let fallbackName = decoded.destination?.lastPathComponent ?? id
        let errorTitle = decoded.errorTitle ?? "Download failed"
        let errorBody = decoded.errorBody ?? fallbackName
        let bgNotified = self.scheduleNotification(title: errorTitle, body: errorBody)
        self.sendEvent([
          "event": "error",
          "id": id,
          "message": error.localizedDescription,
          "bgNotified": bgNotified,
        ])
        self.postLiveActivityComplete(id: id)
        self.checkBackgroundCompletionIfNeeded()
        return
      }

      let meta = self.metaByTaskId[id] ?? HlsDownloadMeta(
        id: id,
        destination: decoded.destination ?? self.defaultDestination(for: id),
        headers: [:],
        notificationTitle: decoded.notificationTitle,
        notificationBody: decoded.notificationBody,
        errorTitle: decoded.errorTitle,
        errorBody: decoded.errorBody
      )
      self.metaByTaskId[id] = meta
      guard let localURL = self.downloadLocationById[id] else {
        self.metaByTaskId.removeValue(forKey: id)
        self.byteProgressById.removeValue(forKey: id)
        self.timeProgressById.removeValue(forKey: id)
        let message = "Missing offline asset location"
        let fallbackName = decoded.destination?.lastPathComponent ?? id
        let errorTitle = decoded.errorTitle ?? "Download failed"
        let errorBody = decoded.errorBody ?? fallbackName
        let bgNotified = self.scheduleNotification(title: errorTitle, body: errorBody)
        self.sendEvent([
          "event": "error",
          "id": id,
          "message": message,
          "bgNotified": bgNotified,
        ])
        self.postLiveActivityComplete(id: id)
        self.checkBackgroundCompletionIfNeeded()
        return
      }

      let finalURL = self.persistDownloadedAsset(id: id, from: localURL, to: meta.destination) ?? localURL
      let fileSize = self.totalSize(at: finalURL)
      self.downloadLocationById.removeValue(forKey: id)
      let notifyTitle = meta.notificationTitle ?? "Download complete"
      let notifyBody = meta.notificationBody ?? finalURL.lastPathComponent
      let bgNotified = self.scheduleNotification(title: notifyTitle, body: notifyBody)
      self.metaByTaskId.removeValue(forKey: id)
      self.byteProgressById.removeValue(forKey: id)
      self.timeProgressById.removeValue(forKey: id)
      self.sendEvent([
        "event": "complete",
        "id": id,
        "path": finalURL.path,
        "bytes": fileSize,
        "bgNotified": bgNotified,
      ])
      self.postLiveActivityComplete(id: id)
      self.checkBackgroundCompletionIfNeeded()
    }
  }

  private func totalSize(at url: URL) -> Int {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
      if !isDir.boolValue {
        return (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
      }
    } else {
      return 0
    }
    var total: Int = 0
    if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [], errorHandler: nil) {
      for case let fileURL as URL in enumerator {
        if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
          total += size
        }
      }
    }
    return total
  }

  private func exportAsset(task: AVAssetDownloadTask, meta: HlsDownloadMeta) {
    let asset = task.urlAsset
    guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
      exportingIds.remove(meta.id)
      sendEvent([
        "event": "error",
        "id": meta.id,
        "message": "Failed to create export session",
      ])
      checkBackgroundCompletionIfNeeded()
      return
    }

    let destination = meta.destination
    prepareDestination(url: destination)
    exportSession.outputURL = destination
    if exportSession.supportedFileTypes.contains(.mp4) {
      exportSession.outputFileType = .mp4
    } else if let first = exportSession.supportedFileTypes.first {
      exportSession.outputFileType = first
    } else {
      exportingIds.remove(meta.id)
      sendEvent([
        "event": "error",
        "id": meta.id,
        "message": "No supported export file types",
      ])
      checkBackgroundCompletionIfNeeded()
      return
    }
    exportSession.shouldOptimizeForNetworkUse = true
    exportSessions[meta.id] = exportSession
    let backgroundTaskId = beginBackgroundTask(for: meta.id)
    if backgroundTaskId != .invalid {
      backgroundTaskIds[meta.id] = backgroundTaskId
    }

    var processingPayload: [String: Any] = [
      "event": "processing",
      "id": meta.id,
    ]
    if let byteProgress = byteProgressById[meta.id] {
      if byteProgress.received > 0 {
        processingPayload["receivedBytes"] = byteProgress.received
      }
      if byteProgress.expected > 0 {
        processingPayload["totalBytes"] = byteProgress.expected
      }
    }
    if let timeProgress = timeProgressById[meta.id] {
      if timeProgress.receivedMs > 0 {
        processingPayload["receivedMs"] = timeProgress.receivedMs
      }
      if timeProgress.totalMs > 0 {
        processingPayload["totalMs"] = timeProgress.totalMs
      }
    }
    sendEvent(processingPayload)

    exportSession.exportAsynchronously { [weak self] in
      guard let self else { return }
      self.syncQueue.async {
        defer {
          self.exportSessions.removeValue(forKey: meta.id)
          self.exportingIds.remove(meta.id)
          self.byteProgressById.removeValue(forKey: meta.id)
          self.timeProgressById.removeValue(forKey: meta.id)
          if let backgroundId = self.backgroundTaskIds.removeValue(forKey: meta.id) {
            self.endBackgroundTask(backgroundId)
          }
          self.checkBackgroundCompletionIfNeeded()
        }
        switch exportSession.status {
        case .completed:
          let fileSize = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? 0
          self.metaByTaskId.removeValue(forKey: meta.id)
          let fallbackName = destination.lastPathComponent
          let notifyTitle = meta.notificationTitle ?? "Download complete"
          let notifyBody = meta.notificationBody ?? fallbackName
          let bgNotified = self.scheduleNotification(title: notifyTitle, body: notifyBody)
          self.sendEvent([
            "event": "complete",
            "id": meta.id,
            "path": destination.path,
            "bytes": fileSize,
            "bgNotified": bgNotified,
          ])
          self.postLiveActivityComplete(id: meta.id)
        case .failed, .cancelled:
          let message = exportSession.error?.localizedDescription ?? "Export failed"
          let fallbackName = destination.lastPathComponent
          let errorTitle = meta.errorTitle ?? "Download failed"
          let errorBody = meta.errorBody ?? fallbackName
          let bgNotified = self.scheduleNotification(title: errorTitle, body: errorBody)
          self.sendEvent([
            "event": "error",
            "id": meta.id,
            "message": message,
            "bgNotified": bgNotified,
          ])
          self.postLiveActivityComplete(id: meta.id)
        default:
          break
        }
      }
    }
  }

  private func postLiveActivityProgress(id: String, received: Double, total: Double) {
    guard total > 0 else { return }
    NotificationCenter.default.post(
      name: .hlsLiveActivityProgress,
      object: nil,
      userInfo: [
        "id": id,
        "received": received,
        "total": total,
      ]
    )
  }

  private func postLiveActivityComplete(id: String) {
    NotificationCenter.default.post(
      name: .hlsLiveActivityProgress,
      object: nil,
      userInfo: [
        "id": id,
        "state": "complete",
      ]
    )
  }

  private func sendEvent(_ payload: [String: Any]) {
    DispatchQueue.main.async {
      self.eventSink?(payload)
    }
  }

  private func shouldSendBackgroundNotification() -> Bool {
    return UIApplication.shared.applicationState != .active
  }

  @discardableResult
  private func scheduleNotification(title: String?, body: String?) -> Bool {
    guard shouldSendBackgroundNotification() else { return false }
    guard let title, !title.isEmpty, let body, !body.isEmpty else { return false }
    guard notificationsAuthorized() else { return false }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    let request = UNNotificationRequest(
      identifier: UUID().uuidString,
      content: content,
      trigger: nil
    )
    UNUserNotificationCenter.current().add(request) { error in
      if error == nil {
        NotificationCenter.default.post(name: .nativeNotificationShown, object: nil)
      }
    }
    return true
  }

  private func notificationsAuthorized() -> Bool {
    let now = Date()
    if let checkedAt = Self.notificationAuthCheckedAt,
       now.timeIntervalSince(checkedAt) < Self.notificationAuthTTL,
       let status = Self.notificationAuthStatus {
      return status == .authorized || status == .provisional
    }
    let center = UNUserNotificationCenter.current()
    let semaphore = DispatchSemaphore(value: 0)
    var allowed: Bool?
    center.getNotificationSettings { settings in
      Self.notificationAuthStatus = settings.authorizationStatus
      Self.notificationAuthCheckedAt = Date()
      allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
      semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 1.0)
    if let allowed {
      return allowed
    }
    let fallbackAllowed = Self.notificationAuthStatus.map {
      $0 == .authorized || $0 == .provisional
    } ?? true
    return fallbackAllowed
  }

  private func checkBackgroundCompletionIfNeeded() {
    syncQueue.async {
      guard self.exportingIds.isEmpty else { return }
      guard let session = self.session else { return }
      session.getAllTasks { tasks in
        if tasks.isEmpty {
          if let completion = self.backgroundCompletion {
            self.backgroundCompletion = nil
            DispatchQueue.main.async {
              completion()
            }
          }
        }
      }
    }
  }

  private func beginBackgroundTask(for id: String) -> UIBackgroundTaskIdentifier {
    var identifier: UIBackgroundTaskIdentifier = .invalid
    let work = {
      let application = UIApplication.shared
      guard application.applicationState != .active else {
        return
      }
      identifier = application.beginBackgroundTask(withName: "com.yibrowser.hls.export.\(id)") { [weak self] in
        guard let self else { return }
        self.syncQueue.async {
          if let session = self.exportSessions[id] {
            session.cancelExport()
          }
          if let stored = self.backgroundTaskIds.removeValue(forKey: id) {
            self.endBackgroundTask(stored)
          }
        }
      }
    }
    if Thread.isMainThread {
      work()
    } else {
      DispatchQueue.main.sync(execute: work)
    }
    return identifier
  }

  private func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
    guard identifier != .invalid else { return }
    let work = {
      UIApplication.shared.endBackgroundTask(identifier)
    }
    if Thread.isMainThread {
      work()
    } else {
      DispatchQueue.main.async(execute: work)
    }
  }

  // MARK: - FlutterStreamHandler

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}
