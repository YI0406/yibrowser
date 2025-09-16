import AVFoundation
import AVKit
import Flutter
import UIKit

/// Native iOS picture-in-picture controller that is driven via the
/// `MethodChannel('app.pip')` channel from Dart. The Dart side only supplies
/// the media URL (local file path or http/https URL) and the current playback
/// position. This manager spins up a dedicated `AVPlayer` for PiP so that
/// playback can continue even when the Flutter engine is backgrounded. When
/// PiP stops we report the latest playback position back to Dart so the Flutter
/// video player can resume from the correct timestamp.
final class NativePiPManager: NSObject, AVPictureInPictureControllerDelegate {
  static let shared = NativePiPManager()

  private weak var flutterController: FlutterViewController?
  private var channel: FlutterMethodChannel?

  private var pipController: AVPictureInPictureController?
  private var player: AVPlayer?
  private var playerLayer: AVPlayerLayer?
  private var playerStatusObservation: NSKeyValueObservation?
  private var pipPossibleObservation: NSKeyValueObservation?
  private var timeObserver: Any?

  private var currentUrl: String?
  private var pendingSeek: CMTime?
  private var pendingStartResult: FlutterResult?
  private var pendingStopResult: FlutterResult?
  private var pendingStopPosition: Int?
  private var lastKnownPosition: CMTime = .zero

  // Invisible host view that keeps the AVPlayerLayer attached to the view
  // hierarchy. PiP requires the layer to belong to a view even if that view is
  // not visible.
  private let hostView: UIView = {
    let view = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    view.isHidden = true
    view.backgroundColor = .clear
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private override init() {
    super.init()
  }

  func configure(with controller: FlutterViewController) {
    guard channel == nil else { return }

    flutterController = controller
    controller.view.addSubview(hostView)
    NSLayoutConstraint.activate([
      hostView.widthAnchor.constraint(equalToConstant: 1),
      hostView.heightAnchor.constraint(equalToConstant: 1),
      hostView.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
      hostView.topAnchor.constraint(equalTo: controller.view.topAnchor),
    ])

    let methodChannel = FlutterMethodChannel(
      name: "app.pip",
      binaryMessenger: controller.binaryMessenger
    )
    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    channel = methodChannel

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(self.onWillResignActive),
      name: UIApplication.willResignActiveNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(self.onDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      DispatchQueue.main.async {
        result(AVPictureInPictureController.isPictureInPictureSupported())
      }
    case "prepare":
      let args = call.arguments as? [String: Any]
      let url = args?["url"] as? String
      let positionMs = args?["positionMs"] as? Int
      let ok = self.preparePlayer(with: url ?? "")
      if ok {
        if let ms = positionMs { self.seek(toMilliseconds: ms) }
        result(true)
      } else {
        result(false)
      }
    case "enter":
      let args = call.arguments as? [String: Any]
      let url = args?["url"] as? String
      let positionMs = args?["positionMs"] as? Int
      startPiP(url: url, positionMs: positionMs, result: result)
    case "exit":
      stopPiP(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startPiP(url: String?, positionMs: Int?, result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        result(false)
        return
      }

      guard AVPictureInPictureController.isPictureInPictureSupported() else {
        result(false)
        return
      }

      if let providedUrl = url, !providedUrl.isEmpty {
        if self.currentUrl != providedUrl {
          guard self.preparePlayer(with: providedUrl) else {
            result(false)
            return
          }
        }
      } else if self.player == nil {
        result(false)
        return
      }

      if let ms = positionMs {
        self.seek(toMilliseconds: ms)
      }

      guard let controller = self.pipController else {
        result(false)
        return
      }

      if controller.isPictureInPictureActive {
        result(true)
        return
      }

      self.pendingStartResult = result
      self.startPiPWhenPossible()
    }
  }

  private func stopPiP(result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        result(nil)
        return
      }

      let position = self.currentPositionMilliseconds()

      guard let controller = self.pipController,
            controller.isPictureInPictureActive else {
        self.completePendingStart(success: false)
        self.teardownPlayer()
        result(position)
        return
      }

      self.pendingStopResult = result
      self.pendingStopPosition = position
      controller.stopPictureInPicture()
    }
  }

  private func preparePlayer(with urlString: String) -> Bool {
    guard let url = resolveUrl(from: urlString) else {
      return false
    }

    teardownPlayer()

    let item = AVPlayerItem(url: url)
    if #available(iOS 15.0, *) {
      item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
    }

    let player = AVPlayer(playerItem: item)
    player.automaticallyWaitsToMinimizeStalling = true
    player.preventsDisplaySleepDuringVideoPlayback = true

    let layer = AVPlayerLayer(player: player)
    layer.frame = hostView.bounds
    layer.videoGravity = .resizeAspect
    hostView.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
    hostView.layer.addSublayer(layer)

    let controller: AVPictureInPictureController?
    if #available(iOS 15.0, *) {
      let source = AVPictureInPictureController.ContentSource(playerLayer: layer)
      controller = AVPictureInPictureController(contentSource: source)
    } else {
      controller = AVPictureInPictureController(playerLayer: layer)
    }

    guard let pipController = controller else {
      player.pause()
      return false
    }

    pipController.delegate = self
    pipController.requiresLinearPlayback = false

    pipPossibleObservation = pipController.observe(
      \AVPictureInPictureController.isPictureInPicturePossible,
      options: [.new]
    ) { [weak self] _, change in
      guard let possible = change.newValue, possible else { return }
      DispatchQueue.main.async {
        self?.startPiPWhenPossible()
      }
    }

    playerStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
      guard let self else { return }
      if item.status == .readyToPlay {
        DispatchQueue.main.async {
          self.applyPendingSeekIfNeeded()
          self.startPiPWhenPossible()
        }
      }
    }

    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
      queue: .main
    ) { [weak self] time in
      self?.lastKnownPosition = time
    }

    self.player = player
    self.playerLayer = layer
    self.pipController = pipController
    self.currentUrl = urlString
    self.pendingSeek = nil
    self.lastKnownPosition = .zero

    player.play()
    return pipController != nil
  }

  private func startPiPWhenPossible() {
    guard let controller = pipController else { return }
    guard pendingStartResult != nil else { return }

    // Only start when the scene is active to avoid AVKit -1001 errors.
    if let scene = flutterController?.view.window?.windowScene,
       scene.activationState != .foregroundActive {
      return
    }

    if controller.isPictureInPictureActive {
      completePendingStart(success: true)
      return
    }

    if controller.isPictureInPicturePossible {
      controller.startPictureInPicture()
    }
  }

  private func completePendingStart(success: Bool) {
    if let callback = pendingStartResult {
      pendingStartResult = nil
      callback(success)
    }
  }

  private func seek(toMilliseconds value: Int) {
    let time = CMTime(value: Int64(value), timescale: 1000)
    if let player = player, let item = player.currentItem,
       item.status == .readyToPlay {
      player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    } else {
      pendingSeek = time
    }
    lastKnownPosition = time
  }

  private func applyPendingSeekIfNeeded() {
    guard let target = pendingSeek else { return }
    pendingSeek = nil
    player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    lastKnownPosition = target
  }

  private func currentPositionMilliseconds() -> Int? {
    if let pending = pendingSeek,
       let value = milliseconds(from: pending) {
      return value
    }

    let time = player?.currentTime() ?? lastKnownPosition
    return milliseconds(from: time)
  }

  private func milliseconds(from time: CMTime) -> Int? {
    guard time.isValid && time.isNumeric else { return nil }
    let seconds = CMTimeGetSeconds(time)
    if seconds.isNaN || seconds.isInfinite { return nil }
    return Int((seconds * 1000.0).rounded())
  }

  private func resolveUrl(from string: String) -> URL? {
    if let url = URL(string: string), let scheme = url.scheme, !scheme.isEmpty {
      if url.isFileURL {
        return url
      }
      return url
    }
    return URL(fileURLWithPath: string)
  }

  private func teardownPlayer() {
    if let token = timeObserver {
      player?.removeTimeObserver(token)
      timeObserver = nil
    }
    playerStatusObservation?.invalidate()
    playerStatusObservation = nil
    pipPossibleObservation?.invalidate()
    pipPossibleObservation = nil

    pipController?.delegate = nil
    pipController = nil

    playerLayer?.player = nil
    playerLayer?.removeFromSuperlayer()
    playerLayer = nil

    player?.pause()
    player = nil

    currentUrl = nil
    pendingSeek = nil
    lastKnownPosition = .zero
  }

  @objc private func onWillResignActive() {
    // Start PiP right before we lose foreground-active state, if possible.
    guard let controller = pipController else { return }
    guard let scene = flutterController?.view.window?.windowScene,
          scene.activationState == .foregroundActive else { return }
    if controller.isPictureInPictureActive { return }
    if controller.isPictureInPicturePossible {
      if pendingStartResult == nil {
        // Ensure Dart receives a completion even if no 'enter' call is pending.
        pendingStartResult = { _ in }
      }
      controller.startPictureInPicture()
    }
  }

  @objc private func onDidBecomeActive() {
    // If a start was deferred, try again now that we're foreground active.
    startPiPWhenPossible()
  }

  // MARK: - AVPictureInPictureControllerDelegate

  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    completePendingStart(success: true)
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    print("[PiP] Failed to start: \(error)")
    completePendingStart(success: false)
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    finishPendingStop()
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    DispatchQueue.main.async { [weak self] in
      if let controller = self?.flutterController {
        controller.view.window?.makeKeyAndVisible()
        completionHandler(true)
      } else {
        completionHandler(false)
      }
    }
  }

  private func finishPendingStop() {
    completePendingStart(success: false)
    let position = pendingStopPosition ?? currentPositionMilliseconds()
    pendingStopPosition = nil
    teardownPlayer()
    if let result = pendingStopResult {
      pendingStopResult = nil
      result(position)
    }
  }
}
