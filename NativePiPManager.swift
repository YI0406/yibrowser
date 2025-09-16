import AVFoundation
import AVKit
import Flutter
import UIKit

final class NativePiPManager: NSObject, AVPictureInPictureControllerDelegate {
  static let shared = NativePiPManager()

  private var channel: FlutterMethodChannel?
  private var player: AVPlayer?
  private var playerLayer: AVPlayerLayer?
  private var pipController: AVPictureInPictureController?
  private var shouldResumePlayback = false
  private var notifiedStop = false
  private var hostView: UIView?

  func configure(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "native_pip", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "pip_unavailable", message: "PiP manager released", details: nil))
        return
      }
      switch call.method {
      case "isAvailable":
        result(AVPictureInPictureController.isPictureInPictureSupported())
      case "start":
        guard let args = call.arguments as? [String: Any] else {
          result(false)
          return
        }
        self.start(arguments: args, result: result)
      case "stop":
        self.stop()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  private func start(arguments: [String: Any], result: @escaping FlutterResult) {
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      result(false)
      return
    }
    guard let source = arguments["source"] as? String else {
      result(false)
      return
    }

    let isRemote = (arguments["isRemote"] as? Bool) ?? false
    let resume = (arguments["resume"] as? Bool) ?? false
    let positionMs = (arguments["positionMs"] as? Int) ?? 0
    let autoPlay = (arguments["autoPlay"] as? Bool) ?? true
    let headers = arguments["headers"] as? [String: String]

    let url: URL?
    if isRemote {
      if let remote = URL(string: source) {
        url = remote
      } else if let encoded = source.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
        url = URL(string: encoded)
      } else {
        url = nil
      }
    } else {
      url = URL(fileURLWithPath: source)
    }

    guard let videoURL = url else {
      result(false)
      return
    }

    cleanup(shouldNotify: false)

    let asset: AVURLAsset
    if let headers, !headers.isEmpty {
      asset = AVURLAsset(url: videoURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    } else {
      asset = AVURLAsset(url: videoURL)
    }

    let item = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: item)
    player.usesExternalPlaybackWhileExternalScreenIsActive = true

    if positionMs > 0 {
      let time = CMTime(value: CMTimeValue(positionMs), timescale: 1000)
      player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    let layer = AVPlayerLayer(player: player)
    layer.videoGravity = .resizeAspect

    self.player = player
    self.playerLayer = layer
    self.shouldResumePlayback = resume
    self.notifiedStop = false

    if #available(iOS 15.0, *) {
      pipController = AVPictureInPictureController(
        contentSource: .init(playerLayer: layer, playbackDelegate: nil)
      )
    } else {
      pipController = AVPictureInPictureController(playerLayer: layer)
    }

    guard let pipController else {
      cleanup(shouldNotify: false)
      result(false)
      return
    }

    pipController.delegate = self

    DispatchQueue.main.async {
      guard let controller = self.pipController else {
        result(false)
        return
      }

      if let existing = self.hostView {
        existing.removeFromSuperview()
        self.hostView = nil
      }

      let host = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
      host.isHidden = true
      self.playerLayer?.frame = host.bounds
      if let layer = self.playerLayer {
        host.layer.addSublayer(layer)
      }
      if let window = self.keyWindow() {
        window.addSubview(host)
        self.hostView = host
      }

      if autoPlay {
        self.player?.play()
      }

      controller.startPictureInPicture()
      result(true)
    }
  }

  private func stop() {
    DispatchQueue.main.async {
      if let controller = self.pipController, controller.isPictureInPictureActive {
        controller.stopPictureInPicture()
      } else {
        self.notifyStop()
      }
    }
  }

  private func cleanup(shouldNotify: Bool) {
    player?.pause()
    if shouldNotify {
      notifyStop()
      return
    }
    player?.replaceCurrentItem(with: nil)
    player = nil
    playerLayer?.removeFromSuperlayer()
    playerLayer = nil
    if let hostView {
      hostView.removeFromSuperview()
      self.hostView = nil
    }
    pipController?.delegate = nil
    pipController = nil
  }

  private func notifyStop() {
    guard !notifiedStop else { return }
    notifiedStop = true

    let seconds = player?.currentTime().seconds ?? 0
    let positionMs = Int(seconds * 1000.0)
    channel?.invokeMethod(
      "onPipClosed",
      arguments: [
        "positionMs": positionMs,
        "shouldResume": shouldResumePlayback,
      ]
    )
    shouldResumePlayback = false
    cleanup(shouldNotify: false)
  }

  private func keyWindow() -> UIWindow? {
    if #available(iOS 13.0, *) {
      return UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
        .first { $0.isKeyWindow }
    } else {
      return UIApplication.shared.keyWindow
    }
  }

  func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
    channel?.invokeMethod("onPipStarted", arguments: nil)
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    notifyStop()
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    notifyStop()
    completionHandler(true)
  }
}
