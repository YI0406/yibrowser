import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Enable background playback for PiP (handled fully by pip Dart plugin).
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      print("[PiP] AVAudioSession error: \(error)")
    }
      let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)

      if let controller = window?.rootViewController as? FlutterViewController {
        NativePiPManager.shared.configure(with: controller)
      }

      return result
  }
}
