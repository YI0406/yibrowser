import Flutter
import UIKit
import AVFoundation


@main
@objc class AppDelegate: FlutterAppDelegate {
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

    if let controller = window?.rootViewController as? FlutterViewController,
       let registrar = controller.registrar(forPlugin: "NativePlayerViewFactory") {
      let messenger = registrar.messenger()
      PlayerEngine.shared.configureChannels(messenger: messenger)
      registrar.register(NativePlayerViewFactory(messenger: messenger), withId: "native-player-view")
    }

    // 提醒（僅註解）：Xcode > Signing & Capabilities 要勾選：
    // Background Modes -> Audio, AirPlay, and Picture in Picture
    return result
  }
    
}
