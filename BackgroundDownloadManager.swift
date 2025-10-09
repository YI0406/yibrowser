import Foundation
import Flutter

/// Bridge between Flutter and native iOS background downloads using URLSession.
final class BackgroundDownloadManager: NSObject, FlutterStreamHandler, URLSessionDownloadDelegate {
  static let shared = BackgroundDownloadManager()

  private let identifier = "com.yibrowser.background.downloader"
  private var methodChannel: FlutterMethodChannel?
  private var eventChannel: FlutterEventChannel?
  private var eventSink: FlutterEventSink?
  private var session: URLSession?
  private var pendingCompletionHandler: (() -> Void)?
  private var activeTasks: [String: URLSessionTask] = [:]
  private var completedTaskIds: Set<String> = []
  private let ioQueue = DispatchQueue(label: "BackgroundDownloadManager.io")

  private override init() {
    super.init()
  }

  func configure(messenger: FlutterBinaryMessenger) {
    if methodChannel != nil { return }

    let method = FlutterMethodChannel(name: "background.downloader", binaryMessenger: messenger)
    method.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    methodChannel = method

    let event = FlutterEventChannel(name: "background.downloader/events", binaryMessenger: messenger)
    event.setStreamHandler(self)
    eventChannel = event

    let config = URLSessionConfiguration.background(withIdentifier: identifier)
    config.isDiscretionary = false
    config.sessionSendsLaunchEvents = true
    if #available(iOS 11.0, *) {
      config.multipathServiceType = .handover
    }
    config.httpMaximumConnectionsPerHost = 4
    config.waitsForConnectivity = true
    config.allowsCellularAccess = true
    if #available(iOS 13.0, *) {
      config.allowsExpensiveNetworkAccess = true
      config.allowsConstrainedNetworkAccess = true
    }

    session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    restoreOutstandingTasks()
  }

  func handleEventsForBackgroundSession(completion: @escaping () -> Void) {
    pendingCompletionHandler = completion
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      guard let args = call.arguments as? [String: Any],
            let id = args["id"] as? String,
            let urlString = args["url"] as? String,
            let dest = args["destinationPath"] as? String,
            let url = URL(string: urlString) else {
        result(FlutterError(code: "invalid_args", message: "Missing id/url/destination", details: nil))
        return
      }
      let allowCellular = (args["allowCellular"] as? Bool) ?? true
      let allowExpensive = (args["allowExpensive"] as? Bool) ?? allowCellular
      let allowConstrained = (args["allowConstrained"] as? Bool) ?? allowCellular
      let headers = args["headers"] as? [String: String] ?? [:]

      ioQueue.async {
        self.cancelTaskIfExists(id: id)
        self.removeFileIfExists(at: dest)
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = headers
        request.httpShouldHandleCookies = true
        request.allowsCellularAccess = allowCellular
        if #available(iOS 13.0, *) {
          request.allowsExpensiveNetworkAccess = allowExpensive
          request.allowsConstrainedNetworkAccess = allowConstrained
        }
        let task = self.session?.downloadTask(with: request)
        task?.taskDescription = self.encodeTaskInfo([
          "id": id,
          "destination": dest,
          "allowCellular": allowCellular ? "1" : "0",
          "allowExpensive": allowExpensive ? "1" : "0",
          "allowConstrained": allowConstrained ? "1" : "0",
        ])
        task?.priority = URLSessionTask.highPriority
        task?.earliestBeginDate = nil
        task?.countOfBytesClientExpectsToSend = NSURLSessionTransferSizeUnknown
        task?.countOfBytesClientExpectsToReceive = NSURLSessionTransferSizeUnknown
        if let task {
          self.activeTasks[id] = task
          task.resume()
          DispatchQueue.main.async { result(nil) }
        } else {
          DispatchQueue.main.async {
            result(FlutterError(code: "session_unavailable", message: "Failed to create download task", details: nil))
          }
        }
      }
    case "cancel":
      guard let args = call.arguments as? [String: Any],
            let id = args["id"] as? String else {
        result(FlutterError(code: "invalid_args", message: "Missing id", details: nil))
        return
      }
      ioQueue.async {
        self.cancelTaskIfExists(id: id)
        DispatchQueue.main.async { result(nil) }
      }
    case "cancelAll":
      ioQueue.async {
        self.session?.getAllTasks { tasks in
          tasks.forEach { $0.cancel() }
          DispatchQueue.main.async { result(nil) }
        }
      }
    case "list":
      ioQueue.async {
        self.session?.getAllTasks { tasks in
          let summaries = tasks.compactMap { task -> [String: Any]? in
            guard let info = self.decodeTaskInfo(task.taskDescription) else { return nil }
            return [
              "id": info["id"],
              "received": task.countOfBytesReceived,
              "total": task.countOfBytesExpectedToReceive,
            ]
          }
          DispatchQueue.main.async { result(summaries) }
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func restoreOutstandingTasks() {
    session?.getAllTasks { tasks in
      for task in tasks {
        if let info = self.decodeTaskInfo(task.taskDescription),
           let id = info["id"] {
          self.activeTasks[id] = task
          let allowCellular = info["allowCellular"] != "0"
          let allowExpensive = info["allowExpensive"] != "0"
          let allowConstrained = info["allowConstrained"] != "0"
          if #available(iOS 13.0, *) {
            task.countOfBytesClientExpectsToReceive = NSURLSessionTransferSizeUnknown
            task.priority = URLSessionTask.highPriority
          }
        }
      }
    }
  }

  private func cancelTaskIfExists(id: String) {
    if let task = activeTasks[id] {
      task.cancel()
      activeTasks.removeValue(forKey: id)
    }
    completedTaskIds.remove(id)
  }

  private func removeFileIfExists(at path: String) {
    let fileURL = URL(fileURLWithPath: path)
    if FileManager.default.fileExists(atPath: fileURL.path) {
      try? FileManager.default.removeItem(at: fileURL)
    }
    let dir = fileURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    markPathForBackgroundAccess(dir)
  }

  private func markPathForBackgroundAccess(_ url: URL) {
    do {
      try FileManager.default.setAttributes([
        .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
      ], ofItemAtPath: url.path)
    } catch {
      NSLog("[Downloader] Failed to relax protection for %@: %@", url.path, error.localizedDescription)
    }
    var resourceValues = URLResourceValues()
    resourceValues.isExcludedFromBackup = true
    do {
      var mutableURL = url
      try mutableURL.setResourceValues(resourceValues)
    } catch {
      // Not critical if this fails.
    }
  }

  private func encodeTaskInfo(_ info: [String: String]) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: info, options: []) else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  private func decodeTaskInfo(_ description: String?) -> [String: String]? {
    guard let description = description,
          let data = description.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data, options: []),
          let map = json as? [String: String] else {
      return nil
    }
    return map
  }

  private func emit(_ payload: [String: Any]) {
    DispatchQueue.main.async {
      self.eventSink?(payload)
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

  // MARK: - URLSessionDownloadDelegate

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    guard let info = decodeTaskInfo(downloadTask.taskDescription), let id = info["id"] else {
      return
    }
    emit([
      "type": "progress",
      "id": id,
      "received": totalBytesWritten,
      "total": totalBytesExpectedToWrite,
    ])
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    guard let info = decodeTaskInfo(downloadTask.taskDescription),
          let id = info["id"],
          let dest = info["destination"] else {
      return
    }
    let fileURL = URL(fileURLWithPath: dest)
    ioQueue.async {
      do {
        self.removeFileIfExists(at: dest)
        try FileManager.default.moveItem(at: location, to: fileURL)
        self.markPathForBackgroundAccess(fileURL)
        self.completedTaskIds.insert(id)
        self.emit([
          "type": "completed",
          "id": id,
          "path": dest,
        ])
      } catch {
        self.emit([
          "type": "error",
          "id": id,
          "message": error.localizedDescription,
        ])
      }
      self.activeTasks.removeValue(forKey: id)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let info = decodeTaskInfo(task.taskDescription),
          let id = info["id"] else {
      return
    }
    activeTasks.removeValue(forKey: id)
    if completedTaskIds.remove(id) != nil {
      return
    }
    if let error = error {
      let nsError = error as NSError
      if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
        emit([
          "type": "cancelled",
          "id": id,
        ])
      } else if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorBackgroundSessionWasDisconnected {
        // iOS raises -997 when the app relaunches to handle background events; ignore.
        return
      } else {
        emit([
          "type": "error",
          "id": id,
          "message": error.localizedDescription,
        ])
      }
    }
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didResumeAtOffset fileOffset: Int64,
    expectedTotalBytes: Int64
  ) {
    guard let info = decodeTaskInfo(downloadTask.taskDescription),
          let id = info["id"] else {
      return
    }
    emit([
      "type": "progress",
      "id": id,
      "received": fileOffset,
      "total": expectedTotalBytes,
    ])
    activeTasks[id] = downloadTask
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    guard let completion = pendingCompletionHandler else { return }
    pendingCompletionHandler = nil
    DispatchQueue.main.async {
      completion()
    }
  }
}
