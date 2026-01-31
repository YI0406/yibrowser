import Flutter
import background_downloader
import UIKit
import AVFoundation
import UserNotifications

private enum ShareBridge {
  static let channelName = "app.share_bridge"
}

private enum NotificationAuthorizationCache {
  private static var lastStatus: UNAuthorizationStatus?
  private static var lastCheckedAt: Date?
  private static let ttl: TimeInterval = 30

  static func canSend(completion: @escaping (Bool) -> Void) {
    let now = Date()
    if let checkedAt = lastCheckedAt,
       now.timeIntervalSince(checkedAt) < ttl,
       let status = lastStatus {
      completion(status == .authorized || status == .provisional)
      return
    }

    let center = UNUserNotificationCenter.current()
    var didComplete = false
    let timeout = DispatchWorkItem {
      if didComplete { return }
      didComplete = true
      let fallbackAllowed = lastStatus.map {
        $0 == .authorized || $0 == .provisional
      } ?? true
      completion(fallbackAllowed)
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0, execute: timeout)

    center.getNotificationSettings { settings in
      if didComplete { return }
      didComplete = true
      timeout.cancel()
      lastStatus = settings.authorizationStatus
      lastCheckedAt = Date()
      completion(settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
    }
  }
}

final class NativeNotificationPlugin: NSObject, FlutterPlugin {
  private static var channel: FlutterMethodChannel?

  static func register(with registrar: FlutterPluginRegistrar) {
    if channel != nil { return }
    let channel = FlutterMethodChannel(
      name: "yibrowser/native_notifications",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "show":
        guard
          let args = call.arguments as? [String: Any],
          let title = args["title"] as? String,
          let body = args["body"] as? String
        else {
          result(FlutterError(code: "invalid_args", message: "Missing title/body", details: nil))
          return
        }
        let center = UNUserNotificationCenter.current()
        NotificationAuthorizationCache.canSend { allowed in
          guard allowed else {
            result(false)
            return
          }
          let content = UNMutableNotificationContent()
          content.title = title
          content.body = body
          content.sound = .default
          let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
          )
          center.add(request) { error in
            if let error = error {
              result(FlutterError(code: "notification_error", message: error.localizedDescription, details: nil))
            } else {
              NotificationCenter.default.post(
                name: Notification.Name("yibrowser.live_activity.end"),
                object: nil
              )
              result(true)
            }
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var deepLinkChannel: FlutterMethodChannel?
  private var pendingDeepLink: String?
  private var nativeNotificationChannel: FlutterMethodChannel?
  private var shareBridgeChannel: FlutterMethodChannel?
  private var didConfigureFlutterChannels = false
  private var configureRetryCount = 0

  func configureDeepLinkChannel(messenger: FlutterBinaryMessenger) {
    if deepLinkChannel != nil { return }
    deepLinkChannel = FlutterMethodChannel(
      name: "app.deep_link",
      binaryMessenger: messenger
    )
    if let pending = pendingDeepLink {
      deepLinkChannel?.invokeMethod("openUrl", arguments: pending)
      pendingDeepLink = nil
    }
  }

  func configureNativeNotificationChannel(messenger: FlutterBinaryMessenger) {
    if nativeNotificationChannel != nil { return }
    let channel = FlutterMethodChannel(
      name: "yibrowser/native_notifications",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "show":
        guard
          let args = call.arguments as? [String: Any],
          let title = args["title"] as? String,
          let body = args["body"] as? String
        else {
          result(FlutterError(code: "invalid_args", message: "Missing title/body", details: nil))
          return
        }
        let center = UNUserNotificationCenter.current()
        NotificationAuthorizationCache.canSend { allowed in
          guard allowed else {
            result(false)
            return
          }
          let content = UNMutableNotificationContent()
          content.title = title
          content.body = body
          content.sound = .default
          let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
          )
          center.add(request) { error in
            if let error = error {
              result(FlutterError(code: "notification_error", message: error.localizedDescription, details: nil))
            } else {
              LiveActivityManager.shared.endFromNativeNotification()
              result(true)
            }
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    nativeNotificationChannel = channel
  }

  func configureShareBridgeChannel(messenger: FlutterBinaryMessenger) {
    if shareBridgeChannel != nil { return }
    let channel = FlutterMethodChannel(
      name: ShareBridge.channelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "consumeSharedItems":
        let items = SharedDownloadsManager.shared.consumePendingItems()
        result(items.map { $0.toDictionary() })
      case "syncShareMetadata":
        SharedDownloadsManager.shared.syncHostMetadata()
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    shareBridgeChannel = channel
  }


  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {

    // 確保為影音播放情境，讓 PiP 在背景可繼續
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
      try AVAudioSession.sharedInstance().setActive(true)
        
    } catch {
      print("[PiP] AVAudioSession error: \(error)")
    }

    BDPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
      if let registrar = registry.registrar(forPlugin: "NativeNotificationPlugin") {
        NativeNotificationPlugin.register(with: registrar)
      }
    }
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self
    }
    _ = LiveActivityManager.shared
    attemptConfigureFlutterChannels()
    // 提醒（僅註解）：Xcode > Signing & Capabilities 要勾選：
    // Background Modes -> Audio, AirPlay, and Picture in Picture
    return result
  }

  private func attemptConfigureFlutterChannels() {
    if didConfigureFlutterChannels { return }
    guard let controller = window?.rootViewController as? FlutterViewController else {
      scheduleConfigureRetry()
      return
    }
    if let playerRegistrar = controller.registrar(forPlugin: "NativePlayerViewFactory") {
      let messenger = playerRegistrar.messenger()
      PlayerEngine.shared.configureChannels(messenger: messenger)
      playerRegistrar.register(
        NativePlayerViewFactory(messenger: messenger),
        withId: "native-player-view"
      )
    }
    if let airplayRegistrar = controller.registrar(forPlugin: "AirPlayRoutePickerFactory") {
      airplayRegistrar.register(
        AirPlayRoutePickerFactory(),
        withId: "airplay-route-picker"
      )
    }
    BackgroundDownloadManager.shared.configure(messenger: controller.binaryMessenger)
    LiveActivityManager.shared.configure(messenger: controller.binaryMessenger)
    IosHlsDownloader.shared.configure(messenger: controller.binaryMessenger)
    configureDeepLinkChannel(messenger: controller.binaryMessenger)
    configureNativeNotificationChannel(messenger: controller.binaryMessenger)
    configureShareBridgeChannel(messenger: controller.binaryMessenger)
    didConfigureFlutterChannels = true
  }

  private func scheduleConfigureRetry() {
    guard configureRetryCount < 10 else { return }
    configureRetryCount += 1
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      self?.attemptConfigureFlutterChannels()
    }
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  override func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    super.application(application, handleEventsForBackgroundURLSession: identifier, completionHandler: completionHandler)
    if UrlSessionDelegate.handleEventsForBackgroundURLSession(
      identifier: identifier,
      completionHandler: completionHandler
    ) {
      return
    }
    if identifier == "com.yibrowser.hls.downloader" {
      IosHlsDownloader.shared.handleEventsForBackgroundSession(identifier: identifier, completion: completionHandler)
      return
    }
    if identifier == "com.yibrowser.background.downloader" {
      BackgroundDownloadManager.shared.handleEventsForBackgroundSession(completion: completionHandler)
    }
  }

  override func application(
    _ application: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    let handledByPlugins = super.application(application, open: url, options: options)
    if let channel = deepLinkChannel {
      channel.invokeMethod("openUrl", arguments: url.absoluteString)
    } else {
      pendingDeepLink = url.absoluteString
    }
    return handledByPlugins || true
  }
}
