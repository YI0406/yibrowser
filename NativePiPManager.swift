import UIKit
import AVFoundation
import AVKit
import Flutter

/// Native iOS picture-in-picture manager that presents an `AVPlayerViewController`
/// and lets the system handle PiP transitions automatically.
final class NativePiPManager: NSObject, AVPlayerViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
  static let shared = NativePiPManager()

  private weak var flutterController: FlutterViewController?
  private var channel: FlutterMethodChannel?

  private var playerViewController: AVPlayerViewController?
  private var player: AVPlayer?
  private var timeObserver: Any?
  private var statusObserver: NSKeyValueObservation?
  private var keepUpObserver: NSKeyValueObservation?
  private var bufferEmptyObserver: NSKeyValueObservation?
  private var itemReadyForDisplay = false
  private var pendingPrimeResult: FlutterResult?
  private var inlineViewHidden = true
  private var inlineTargetFrame: CGRect = .zero

  private var pendingStopResult: FlutterResult?
  private var pendingStopPosition: Int?

  private var lastKnownPosition: CMTime = .zero
  private var lastConfiguredURL: URL?
  private var inlinePiPActive = false
  private var allowInlineDisplay = false
  private var inlineMuted = true

  private override init() {
    super.init()
  }

  func configure(with controller: FlutterViewController) {
    guard channel == nil else { return }

    flutterController = controller

    let methodChannel = FlutterMethodChannel(
      name: "app.pip",
      binaryMessenger: controller.binaryMessenger
    )
    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    channel = methodChannel
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
      prepareNativePlayer(url: url, positionMs: positionMs, isPlaying: nil, result: result)
    case "prime":
      let args = call.arguments as? [String: Any]
      let url = args?["url"] as? String
      let positionMs = args?["positionMs"] as? Int
      let isPlaying = args?["isPlaying"] as? Bool
      prepareNativePlayer(url: url, positionMs: positionMs, isPlaying: isPlaying, result: result)
    case "enter":
      let args = call.arguments as? [String: Any]
      let url = args?["url"] as? String
      let positionMs = args?["positionMs"] as? Int
      let isPlaying = args?["isPlaying"] as? Bool
      presentNativePlayer(url: url, positionMs: positionMs, isPlaying: isPlaying, result: result)
    case "updateHostViewFrame":
      guard
        let args = call.arguments as? [String: Any],
        let x = args["x"] as? Double,
        let y = args["y"] as? Double,
        let width = args["width"] as? Double,
        let height = args["height"] as? Double
      else {
        result(FlutterError(code: "invalid_args", message: "Missing frame values", details: nil))
        return
      }
      updateHostViewFrame(
        x: CGFloat(x),
        y: CGFloat(y),
        width: CGFloat(width),
        height: CGFloat(height)
      )
      result(nil)
    case "exit":
      stopPiP(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func prepareNativePlayer(
    url: String?,
    positionMs: Int?,
    isPlaying: Bool?,
    result: @escaping FlutterResult
  ) {
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        result(false)
        return
      }

      guard AVPictureInPictureController.isPictureInPictureSupported() else {
        result(false)
        return
      }

      self.allowInlineDisplay = false

      if let urlString = url {
        guard let resolvedURL = self.resolveURL(from: urlString) else {
          result(false)
          return
        }
        guard self.configurePlayer(with: resolvedURL) else {
          result(false)
          return
        }
      } else if self.player == nil {
        result(false)
        return
      }

      if let ms = positionMs {
        self.seekPlayer(toMilliseconds: ms)
      }

      self.inlineMuted = true

      if let playing = isPlaying {
        self.applyPlaybackState(playing: playing)
      } else {
        self.player?.pause()
        self.player?.isMuted = true
      }

      let controller = self.ensurePlayerViewController()
      controller.player = self.player
      if let presenter = self.presentationHostViewController() {
        self.embedInline(controller: controller, into: presenter)
      }
      self.updateInlineVisibility(hidden: true)
      print("[PiP] prepareNativePlayer status=", self.player?.currentItem?.status.rawValue ?? -1)
      if self.isPlayerReadyToDisplay() {
        result(true)
      } else {
        self.registerPendingPrimeResult(result)
      }
    }
  }

  private func presentNativePlayer(
    url: String?,
    positionMs: Int?,
    isPlaying: Bool?,
    result: @escaping FlutterResult
  ) {
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        result(false)
        return
      }

      guard AVPictureInPictureController.isPictureInPictureSupported() else {
        result(false)
        return
      }

      if let urlString = url {
        guard let resolvedURL = self.resolveURL(from: urlString) else {
          result(false)
          return
        }
        guard self.configurePlayer(with: resolvedURL) else {
          result(false)
          return
        }
      } else if self.player == nil {
        result(false)
        return
      }

      if let ms = positionMs {
        self.seekPlayer(toMilliseconds: ms)
      }

      let playing = isPlaying ?? false
      self.inlineMuted = !playing

      self.applyPlaybackState(playing: playing)

      let controller = self.ensurePlayerViewController()
      controller.player = self.player

      if isPiPCurrentlyActive(on: controller) {
        result(true)
        return
      }

      if controller.presentingViewController != nil {
        controller.dismiss(animated: false)
      }

      guard let presenter = self.presentationHostViewController() else {
        result(false)
        return
      }

      self.embedInline(controller: controller, into: presenter)
      controller.presentationController?.delegate = self
      self.applyPlaybackState(playing: playing)
      self.inlinePiPActive = false
      self.updateInlineVisibility(hidden: false)
      self.allowInlineDisplay = true
      print("[PiP] presentNativePlayer status=", self.player?.currentItem?.status.rawValue ?? -1)
      if self.isPlayerReadyToDisplay() {
        result(true)
      } else {
        self.registerPendingPrimeResult(result)
      }
    }
  }

  private func stopPiP(result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        result(nil)
        return
      }

      let position = self.currentPositionMilliseconds()

      guard let controller = self.playerViewController else {
        self.detachPlayer()
        result(position)
        return
      }

      self.pendingStopResult = result
      self.pendingStopPosition = position

      self.player?.pause()
      self.player?.isMuted = true
      self.inlineMuted = true

      if isPiPCurrentlyActive(on: controller) {
        self.requestStopPiP(on: controller)
        return
      }

      if controller.presentingViewController != nil {
        controller.dismiss(animated: true) {
          self.finishPendingStop()
        }
        return
      }

      self.finishPendingStop()
    }
  }

  func updateHostViewFrame(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
    guard let controller = playerViewController, let hostView = controller.view.superview else {
      return
    }

    let frame = CGRect(x: x, y: y, width: width, height: height)
    if let window = hostView.window {
      inlineTargetFrame = hostView.convert(frame, from: window)
    } else {
      inlineTargetFrame = frame
    }
    if inlineViewHidden {
      return
    }
    controller.view.frame = inlineTargetFrame
  }

  private func configurePlayer(with url: URL) -> Bool {
    if let currentAsset = player?.currentItem?.asset as? AVURLAsset,
       currentAsset.url == url {
      ensureTimeObserver()
      lastConfiguredURL = url
      return true
    }

    removeTimeObserverIfNeeded()
    statusObserver = nil
    keepUpObserver = nil
    bufferEmptyObserver = nil
    itemReadyForDisplay = false
    inlineViewHidden = true
    inlineTargetFrame = .zero
    inlineViewHidden = true
    inlineViewHidden = true
    if let pending = pendingPrimeResult {
      pendingPrimeResult = nil
      DispatchQueue.main.async {
        pending(false)
      }
    }

    let item = AVPlayerItem(url: url)
    let player = AVPlayer(playerItem: item)
    player.automaticallyWaitsToMinimizeStalling = false
    player.currentItem?.preferredForwardBufferDuration = 0.1
    self.player = player
    lastConfiguredURL = url
    lastKnownPosition = .zero
    ensurePlayerViewController().player = player
    observeCurrentItemStatus()
    attachTimeObserver(to: player)
    return true
  }

  private func ensurePlayerViewController() -> AVPlayerViewController {
    if let controller = playerViewController {
      return controller
    }

    let controller = AVPlayerViewController()
    controller.delegate = self
    controller.allowsPictureInPicturePlayback = true
    controller.showsPlaybackControls = false
    controller.modalPresentationStyle = .overFullScreen
    if #available(iOS 13.0, *) {
      controller.entersFullScreenWhenPlaybackBegins = false
      controller.exitsFullScreenWhenPlaybackEnds = true
    }
    if #available(iOS 14.2, *) {
      controller.canStartPictureInPictureAutomaticallyFromInline = true
    }
    playerViewController = controller
    return controller
  }

  private func presentationHostViewController() -> UIViewController? {
    var presenter: UIViewController? = flutterController
    while let presented = presenter?.presentedViewController {
      presenter = presented
    }
    return presenter
  }

  private func attachTimeObserver(to player: AVPlayer) {
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
      queue: .main
    ) { [weak self] time in
      self?.lastKnownPosition = time
    }
  }

  private func ensureTimeObserver() {
    guard timeObserver == nil, let player else { return }
    attachTimeObserver(to: player)
  }

  private func removeTimeObserverIfNeeded() {
    if let observer = timeObserver, let player = player {
      player.removeTimeObserver(observer)
    }
    timeObserver = nil
  }

  private func observeCurrentItemStatus() {
    statusObserver = player?.currentItem?.observe(
      \.status,
      options: [.initial, .new],
      changeHandler: { [weak self] item, _ in
        guard let self else { return }
        self.evaluateItemReadiness(item: item)
      }
    )
    keepUpObserver = player?.currentItem?.observe(
      \.isPlaybackLikelyToKeepUp,
      options: [.initial, .new],
      changeHandler: { [weak self] item, _ in
        guard let self else { return }
        self.evaluateItemReadiness(item: item)
      }
    )
    bufferEmptyObserver = player?.currentItem?.observe(
      \.isPlaybackBufferEmpty,
      options: [.initial, .new],
      changeHandler: { [weak self] item, _ in
        guard let self else { return }
        self.evaluateItemReadiness(item: item)
      }
    )
  }

  private func isPlayerReadyToDisplay() -> Bool {
    return itemReadyForDisplay
  }

  private func registerPendingPrimeResult(_ result: @escaping FlutterResult) {
    if let pending = pendingPrimeResult {
      DispatchQueue.main.async {
        pending(false)
      }
    }
    pendingPrimeResult = result
  }

  private func completePendingPrime(success: Bool) {
    guard let pending = pendingPrimeResult else { return }
    pendingPrimeResult = nil
    print("[PiP] completePendingPrime success=", success)
    DispatchQueue.main.async {
      pending(success)
    }
  }

  private func evaluateItemReadiness(item: AVPlayerItem) {
    let status = item.status
    let keepUp = item.isPlaybackLikelyToKeepUp
    let empty = item.isPlaybackBufferEmpty
    let ready = status == .readyToPlay && (keepUp || !empty)
    print("[PiP] item status=", status.rawValue, "keepUp=", keepUp, "empty=", empty)
    if ready {
      if !itemReadyForDisplay {
        itemReadyForDisplay = true
        completePendingPrime(success: true)
      }
      updateInlineVisibility(hidden: false)
    } else {
      itemReadyForDisplay = false
      if status == .failed {
        completePendingPrime(success: false)
      }
      updateInlineVisibility(hidden: true)
    }
  }

  private func updateInlineVisibility(hidden: Bool) {
    inlineViewHidden = hidden
    guard let view = playerViewController?.view else { return }
    let shouldDisplayInline = !hidden && allowInlineDisplay
    let targetAlpha: CGFloat
    if hidden {
      targetAlpha = 0.0
    } else if shouldDisplayInline {
      targetAlpha = 1.0
    } else {
      targetAlpha = 0.0001
    }
    let targetHidden = hidden
    let targetFrame = hidden ? offscreenFrame() : effectiveInlineFrame()
    if abs(view.alpha - targetAlpha) < 0.001 && view.isHidden == targetHidden && view.frame == targetFrame {
      return
    }
    DispatchQueue.main.async {
      view.alpha = targetAlpha
      view.isHidden = targetHidden
      view.frame = targetFrame
    }
  }

  private func offscreenFrame() -> CGRect {
    return CGRect(x: -10000, y: -10000, width: 1, height: 1)
  }

  private func effectiveInlineFrame() -> CGRect {
    if inlineTargetFrame != .zero {
      return inlineTargetFrame
    }
    if let superview = playerViewController?.view.superview {
      return superview.bounds
    }
    return CGRect(x: 0, y: 0, width: 1, height: 1)
  }

  private func seekPlayer(toMilliseconds ms: Int) {
    guard let player else { return }
    let time = CMTime(value: Int64(ms), timescale: 1000)
    player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    lastKnownPosition = time
  }

  private func applyPlaybackState(playing: Bool) {
    if playing {
      player?.isMuted = inlineMuted
      player?.play()
    } else {
      player?.pause()
      player?.isMuted = true
    }
  }

  private func currentPositionMilliseconds() -> Int? {
    guard let player else {
      return milliseconds(from: lastKnownPosition)
    }
    let time = player.currentTime()
    lastKnownPosition = time
    return milliseconds(from: time)
  }

  private func finishPendingStop() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.updateInlineVisibility(hidden: true)
      let position = self.pendingStopPosition ?? self.currentPositionMilliseconds()
      let callback = self.pendingStopResult
      self.pendingStopResult = nil
      self.pendingStopPosition = nil
      self.allowInlineDisplay = false
      self.detachPlayer()
      if let callback {
        callback(position)
      } else {
        self.notifyPiPDidStop(with: position)
      }
    }
  }

  private func notifyPiPDidStop(with position: Int?) {
    guard let channel else { return }
    var payload: [String: Any] = [:]
    if let position {
      payload["positionMs"] = position
    }
    channel.invokeMethod("onPiPStopped", arguments: payload)
  }

  private func detachPlayer() {
    removeTimeObserverIfNeeded()
    statusObserver = nil
    keepUpObserver = nil
    bufferEmptyObserver = nil
    itemReadyForDisplay = false
    inlineViewHidden = true
    inlineTargetFrame = .zero
    allowInlineDisplay = false
    if let pending = pendingPrimeResult {
      pendingPrimeResult = nil
      DispatchQueue.main.async {
        pending(false)
      }
    }
    player?.pause()
    player = nil
    lastConfiguredURL = nil
    lastKnownPosition = .zero
    inlinePiPActive = false
    inlineMuted = true

    if let controller = playerViewController {
      controller.player = nil
      controller.delegate = nil
      controller.presentationController?.delegate = nil
      if controller.presentingViewController != nil {
        controller.dismiss(animated: false)
      } else if controller.view.superview != nil {
        controller.view.removeFromSuperview()
      }
    }
    playerViewController = nil
  }

  private func embedInline(controller: AVPlayerViewController, into parent: UIViewController) {
    if controller.parent === parent {
      return
    }

    if controller.presentingViewController != nil {
      controller.dismiss(animated: false)
    }

    if let currentParent = controller.parent {
      controller.willMove(toParent: nil)
      controller.view.removeFromSuperview()
      controller.removeFromParent()
    }

    let hostView = parent.view
    controller.view.translatesAutoresizingMaskIntoConstraints = true
    inlineTargetFrame = hostView?.bounds ?? .zero
    controller.view.frame = inlineViewHidden ? offscreenFrame() : inlineTargetFrame
    controller.view.backgroundColor = .clear
    controller.view.isOpaque = false
    controller.view.alpha = inlineViewHidden ? 0.0 : 1.0
    controller.view.isHidden = inlineViewHidden
    controller.view.isUserInteractionEnabled = false

    parent.addChild(controller)
    hostView?.addSubview(controller.view)
    controller.didMove(toParent: parent)
  }

  private func resolveURL(from value: String) -> URL? {
    if value.hasPrefix("http://") || value.hasPrefix("https://") || value.hasPrefix("file://") {
      return URL(string: value)
    }
    return URL(fileURLWithPath: value)
  }

  private func milliseconds(from time: CMTime) -> Int? {
    guard time.isValid && time.isNumeric else { return nil }
    let seconds = CMTimeGetSeconds(time)
    if seconds.isNaN || seconds.isInfinite { return nil }
    return Int((seconds * 1000.0).rounded())
  }

  private func isPiPCurrentlyActive(on controller: AVPlayerViewController) -> Bool {
    if #available(iOS 15.0, *) {
      // Use KVC so the code compiles with SDKs that do not expose the property.
      if let pipController = controller.value(forKey: "pictureInPictureController") as? AVPictureInPictureController {
        let active = pipController.isPictureInPictureActive
        inlinePiPActive = active
        return active
      }
    }
    return inlinePiPActive
  }

  private func requestStopPiP(on controller: AVPlayerViewController) {
    if #available(iOS 15.0, *) {
      // Access the PiP controller dynamically for cross-SDK compatibility.
      if let pipController = controller.value(forKey: "pictureInPictureController") as? AVPictureInPictureController,
         pipController.isPictureInPictureActive {
        pipController.stopPictureInPicture()
        return
      }
    }

    let selector = NSSelectorFromString("stopPictureInPicture")
    if controller.responds(to: selector) {
      controller.perform(selector)
      return
    }

    finishPendingStop()
  }

  // MARK: - AVPlayerViewControllerDelegate

  func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
    inlinePiPActive = true
  }

  func playerViewController(
    _ playerViewController: AVPlayerViewController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    print("[PiP] Failed to start PiP: \(error)")
  }

  func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
    inlinePiPActive = false
    finishPendingStop()
  }

  func playerViewController(
    _ playerViewController: AVPlayerViewController,
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

  // MARK: - UIAdaptivePresentationControllerDelegate

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    inlinePiPActive = false
    finishPendingStop()
  }
}
