import UIKit
import Flutter
import AVKit
import AVFoundation

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  // PiP shared state (iOS 15+)
  @available(iOS 15.0, *)
  private var pipController: AVPictureInPictureController?
  private let player = AVPlayer()
  private let playerLayer = AVPlayerLayer()
  private var avc: AVPlayerViewController?
  private var pendingStart = false
  private var itemStatusObs: NSKeyValueObservation?
  private var readyDisplayObs: NSKeyValueObservation?
  private var timeControlObs: NSKeyValueObservation?
  private var pipRetryCount = 0

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    guard let windowScene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: windowScene)
    let flutterVC = FlutterViewController(project: nil, nibName: nil, bundle: nil)
    GeneratedPluginRegistrant.register(with: flutterVC)

    // Register PiP MethodChannel here (UIScene lifecycle)
    let channel = FlutterMethodChannel(name: "app.pip", binaryMessenger: flutterVC.binaryMessenger)
    channel.setMethodCallHandler { (call, result) in
      switch call.method {
      case "isAvailable":
        if #available(iOS 15.0, *) { result(AVPictureInPictureController.isPictureInPictureSupported()) } else { result(false) }
      case "enter":
        if #available(iOS 15.0, *) {
          let args = call.arguments as? [String: Any]
          let urlStr = args?["url"] as? String
          let posMs = args?["positionMs"] as? Int
          result(self.enterPiP(urlString: urlStr, positionMs: posMs))
        } else { result(false) }
      case "exit":
        self.exitPiP()
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    window.rootViewController = flutterVC
    self.window = window
    window.makeKeyAndVisible()
  }

  // MARK: - PiP helpers (duplicate minimal impl for scene)
  @available(iOS 15.0, *)
  private func enterPiP(urlString: String? = nil, positionMs: Int? = nil) -> Bool {
    // 1) Audio session for background playback
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      print("[PiP] audio session error: \(error)")
    }

    // 2) Load/replace current item
    if let s = urlString {
      let url: URL = (s.hasPrefix("http://") || s.hasPrefix("https://") || s.hasPrefix("file://")) ? (URL(string: s) ?? URL(fileURLWithPath: s)) : URL(fileURLWithPath: s)
      let item = AVPlayerItem(url: url)
      player.replaceCurrentItem(with: item)
      if let ms = positionMs { player.seek(to: CMTime(value: CMTimeValue(ms), timescale: 1000)) }
    }

    // 3) Attach a hidden but non-zero-sized player view once
    if avc == nil, let root = window?.rootViewController {
      let controller = AVPlayerViewController()
      controller.player = player
      controller.allowsPictureInPicturePlayback = true
      controller.view.isHidden = false
      controller.view.alpha = 0.01
      // Give the host view a fixed, non-zero frame immediately to avoid PiP "possible? false"
      controller.view.frame = CGRect(x: 8, y: 8, width: 320, height: 180)
      root.addChild(controller)
      root.view.addSubview(controller.view)
      controller.didMove(toParent: root)
      root.view.layoutIfNeeded()
      avc = controller
    } else {
      avc?.player = player
    }

    // 4) Ensure playerLayer is attached and sized (non-zero)
    if playerLayer.superlayer == nil {
      playerLayer.player = player
      playerLayer.videoGravity = .resizeAspect
      playerLayer.needsDisplayOnBoundsChange = true
      // Force a non-zero frame right away; do not rely on bounds before layout
      let hostBounds = avc?.view.bounds ?? CGRect(x: 0, y: 0, width: 320, height: 180)
      playerLayer.frame = hostBounds
      avc?.view.layer.addSublayer(playerLayer)
      CATransaction.flush()
    }

    // 5) Lazily create PiP controller and set delegate
    if pipController == nil {
      guard AVPictureInPictureController.isPictureInPictureSupported() else {
        print("[PiP] not supported")
        return false
      }
      let contentSource = AVPictureInPictureController.ContentSource(playerLayer: playerLayer)
      let pip = AVPictureInPictureController(contentSource: contentSource)
      if #available(iOS 14.2, *) {
        pip.canStartPictureInPictureAutomaticallyFromInline = true
      }
      pip.delegate = self
      pipController = pip
    }

    // 6) Observers to auto-start when ready (fixes "need second tap")
    itemStatusObs = player.currentItem?.observe(\ .status, options: [.initial, .new]) { [weak self] _, _ in
      self?.tryStartIfReady()
    }
    readyDisplayObs = playerLayer.observe(\ .isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
      self?.tryStartIfReady()
    }
    timeControlObs = player.observe(\ .timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
      self?.tryStartIfReady()
    }

    // 7) Queue start and play
    pendingStart = true
    player.playImmediately(atRate: 1.0)
    tryStartIfReady()

    return true
  }

  @available(iOS 15.0, *)
  private func isReadyForPiP() -> Bool {
    let boundsOK = playerLayer.frame.width > 0 && playerLayer.frame.height > 0
    let itemReady = player.currentItem?.status == .readyToPlay
    let layerReady = playerLayer.isReadyForDisplay
    return boundsOK && itemReady && layerReady
  }

  @available(iOS 15.0, *)
  private func tryStartIfReady() {
    guard pendingStart, let pip = pipController, !pip.isPictureInPictureActive else { return }
    // Re-apply a safe non-zero frame to both host and layer if needed
    if let host = avc?.view, (playerLayer.frame.width == 0 || playerLayer.frame.height == 0) {
      // Re-apply a safe non-zero frame to both host and layer
      if host.frame.size == .zero { host.frame = CGRect(x: 8, y: 8, width: 320, height: 180) }
      playerLayer.frame = host.bounds
      CATransaction.flush()
    }
    if isReadyForPiP() {
      let hostF = avc?.view.frame ?? .zero
      let layerF = playerLayer.frame
      print("[PiP] starting PiP; hostFrame=\(hostF) layerFrame=\(layerF)")
      pipRetryCount = 0
      pip.startPictureInPicture()
      return
    }
    // Not ready yet: schedule a short retry loop (up to ~1s total)
    if pipRetryCount < 10 {
      pipRetryCount += 1
      let b = playerLayer.bounds
      print("[PiP] not ready; retry #\(pipRetryCount); layer=\(b), item=\(String(describing: player.currentItem?.status)), readyForDisplay=\(playerLayer.isReadyForDisplay)")
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
        self?.tryStartIfReady()
      }
    }
  }

  private func exitPiP() {
    if #available(iOS 15.0, *) {
      pendingStart = false
      if let pip = pipController, pip.isPictureInPictureActive {
        pip.stopPictureInPicture()
      }
    }
  }
}

@available(iOS 15.0, *)
extension SceneDelegate: AVPictureInPictureControllerDelegate {
  func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    print("[PiP] didStart")
    pendingStart = false
  }
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
    print("[PiP] failedToStart: \(error)")
    // keep pendingStart = true; when readiness flips we will retry automatically
  }
  func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    print("[PiP] didStop")
  }
}

