import Flutter
import UIKit
import AVFoundation
import receive_sharing_intent


@main
@objc class AppDelegate: FlutterAppDelegate {
    private var shareChannel: FlutterMethodChannel?
    private var pendingShareEvent = false
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

    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)

      if let controller = window?.rootViewController as? FlutterViewController {
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
    }
      SharedDownloadsManager.shared.syncHostMetadata()

    // 提醒（僅註解）：Xcode > Signing & Capabilities 要勾選：
    // Background Modes -> Audio, AirPlay, and Picture in Picture
    return result
  }
    func registerShareChannel(with controller: FlutterViewController) {
        let channel = FlutterMethodChannel(
          name: "com.yibrowser/share",
          binaryMessenger: controller.binaryMessenger
        )
        SharedDownloadsManager.shared.syncHostMetadata()
        shareChannel = channel
        channel.setMethodCallHandler { [weak self] call, result in
          guard let self else {
            result(FlutterMethodNotImplemented)
            return
          }
          switch call.method {
          case "consumeSharedDownloads":
            let items = SharedDownloadsManager.shared.consumePendingItems()
            result(items.map { $0.toDictionary() })
          case "cleanupSharedDownloads":
            if let paths = call.arguments as? [String] {
              SharedDownloadsManager.shared.cleanup(relativePaths: paths)
            }
            result(nil)
          default:
            result(FlutterMethodNotImplemented)
          }
        }
        notifyShareAvailableIfNeeded()
      }

      private func notifyShareAvailableIfNeeded() {
        guard let channel = shareChannel else {
          return
        }
        if pendingShareEvent || SharedDownloadsManager.shared.hasPendingItems {
          pendingShareEvent = false
          channel.invokeMethod("onShareTriggered", arguments: nil)
        }
      }

      override func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
      ) -> Bool {
        if SharedDownloadsManager.shared.canHandle(url: url) {
          pendingShareEvent = true
          notifyShareAvailableIfNeeded()
          return true
        }
        return super.application(app, open: url, options: options)
      }
}
