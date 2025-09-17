import UIKit
import AVFoundation
import AVKit
import Flutter

/// Native iOS picture-in-picture controller that is driven via the
/// `MethodChannel('app.pip')` channel from Dart. Instead of spinning up a
/// dedicated background-only player, this implementation reuses the same
/// `AVPlayerLayer` that renders the inline video inside Flutter so that iOS can
/// automatically transition to PiP when the app leaves the foreground.
final class NativePiPManager: NSObject, AVPictureInPictureControllerDelegate {
  static let shared = NativePiPManager()

  private weak var flutterController: FlutterViewController?
  private var channel: FlutterMethodChannel?

  private var pipController: AVPictureInPictureController?
  private var playerLayer: AVPlayerLayer?
  private weak var observedPlayer: AVPlayer?
  private var playerLayerReadyObservation: NSKeyValueObservation?
  private var pipPossibleObservation: NSKeyValueObservation?
  private var timeControlObservation: NSKeyValueObservation?
  private var timeObserver: Any?

  private var pendingStartResult: FlutterResult?
  private var pendingStopResult: FlutterResult?
  private var pendingStopPosition: Int?

  private var lastKnownPosition: CMTime = .zero
  private var lifecycleNotificationsRegistered = false
  private var shouldAttemptStartWhenReady = false
  private var autoStartArmed = false

  @available(iOS 13.0, *)
  private weak var lifecycleSceneHint: UIScene?

  private var lastKnownInlineRect: CGRect = .zero

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

    registerLifecycleNotificationsIfNeeded()
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    print("[PiP] handle method=\(call.method)")
    switch call.method {
    case "isAvailable":
      DispatchQueue.main.async {
        result(AVPictureInPictureController.isPictureInPictureSupported())
      }
    case "prime":
      let args = call.arguments as? [String: Any]
      let url = args?["url"] as? String
      let positionMs = args?["positionMs"] as? Int
      primePiP(url: url, positionMs: positionMs, result: result)
    case "enter":
      let args = call.arguments as? [String: Any]
      let url = args?["url"] as? String
      let positionMs = args?["positionMs"] as? Int
      startPiP(url: url, positionMs: positionMs, result: result)
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

  func updateHostViewFrame(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
    DispatchQueue.main.async { [weak self] in
      guard let self, let flutterView = self.flutterController?.view else { return }

      let targetRect = CGRect(x: x, y: y, width: width, height: height)
      let convertedRect: CGRect
      if flutterView.window != nil {
        convertedRect = flutterView.convert(targetRect, from: nil)
      } else {
        convertedRect = targetRect
      }

      self.lastKnownInlineRect = convertedRect
      self.locateAndBindInlineLayer(around: convertedRect)
    }
  }

  func primePiP(url: String?, positionMs: Int?, result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        result(false)
        return
      }
      print("[PiP] prime: url=\(url ?? "<nil>") posMs=\(positionMs ?? -1)")

      registerLifecycleNotificationsIfNeeded()

      guard AVPictureInPictureController.isPictureInPictureSupported() else {
        print("[PiP] prime: isPictureInPictureSupported == false")
        result(false)
        return
      }

      guard ensureInlineLayerAvailable() else {
        print("[PiP] prime: no inline AVPlayerLayer located")
        result(false)
        return
      }

      if let ms = positionMs {
        lastKnownPosition = CMTime(value: Int64(ms), timescale: 1000)
      } else if let player = observedPlayer {
        lastKnownPosition = player.currentTime()
      }

      autoStartArmed = true
      updateSystemAutoPiP()
      result(true)
    }
  }

  private func ensureInlineLayerAvailable() -> Bool {
    if let layer = playerLayer, layer.player != nil {
      if pipController == nil {
        return configurePipController(for: layer)
      }
      return true
    }

    guard let flutterView = flutterController?.view else { return false }
    guard let layer = locateInlinePlayerLayer(in: flutterView, around: lastKnownInlineRect),
          layer.player != nil else {
      return false
    }

    playerLayer = layer
    print("[PiP] ensureInlineLayerAvailable: bound inline AVPlayerLayer")
    return configurePipController(for: layer)
  }

  private func locateAndBindInlineLayer(around rect: CGRect?) {
    guard let flutterView = flutterController?.view else { return }
    guard let layer = locateInlinePlayerLayer(in: flutterView, around: rect ?? lastKnownInlineRect) else {
      return
    }
    playerLayer = layer
    _ = configurePipController(for: layer)
    updateSystemAutoPiP()
  }

  private func locateInlinePlayerLayer(in rootView: UIView, around rect: CGRect?) -> AVPlayerLayer? {
    var candidate: AVPlayerLayer?

    if let rect, rect.isNull == false, rect.isInfinite == false, rect.size != .zero {
      let center = CGPoint(x: rect.midX, y: rect.midY)
      if rootView.bounds.contains(center) {
        if let hit = rootView.hitTest(center, with: nil) {
          candidate = findPlayerLayer(in: hit.layer)
          if candidate == nil {
            var current = hit.superview
            while candidate == nil, let view = current {
              candidate = findPlayerLayer(in: view.layer)
              current = view.superview
            }
          }
        }
      }
    }

    if candidate == nil {
      candidate = findPlayerLayer(in: rootView.layer)
    }

    return candidate
  }

  private func findPlayerLayer(in layer: CALayer) -> AVPlayerLayer? {
    if let playerLayer = layer as? AVPlayerLayer, playerLayer.player != nil {
      return playerLayer
    }
    for sublayer in layer.sublayers ?? [] {
      if let found = findPlayerLayer(in: sublayer) {
        return found
      }
    }
    return nil
  }

  private func configurePipController(for layer: AVPlayerLayer) -> Bool {
    resetObservations()

    guard let player = layer.player else {
      print("[PiP] configure: layer has no player")
      return false
    }

    let controller: AVPictureInPictureController
    if #available(iOS 15.0, *) {
      controller = AVPictureInPictureController(
        contentSource: AVPictureInPictureController.ContentSource(playerLayer: layer)
      )
    } else {
      guard let legacy = AVPictureInPictureController(playerLayer: layer) else {
        print("[PiP] configure: legacy AVPictureInPictureController init returned nil")
        return false
      }
      controller = legacy
    }

    controller.delegate = self
    controller.requiresLinearPlayback = false

    pipController = controller
    observedPlayer = player
    print("[PiP] configured: possible=\(controller.isPictureInPicturePossible) ready=\(layer.isReadyForDisplay)")

    pipPossibleObservation = controller.observe(
      \AVPictureInPictureController.isPictureInPicturePossible,
      options: [.new]
    ) { [weak self] _, change in
      guard let possible = change.newValue, possible else { return }
      DispatchQueue.main.async {
        self?.updateSystemAutoPiP()
        self?.startPiPWhenPossible()
      }
    }

    playerLayerReadyObservation = layer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, change in
      guard let ready = change.newValue, ready else { return }
      DispatchQueue.main.async {
        self?.updateSystemAutoPiP()
        self?.startPiPWhenPossible()
      }
    }

    timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
      self?.updateSystemAutoPiP()
    }

    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
      queue: .main
    ) { [weak self] time in
      self?.lastKnownPosition = time
    }

    updateSystemAutoPiP()
    return true
  }

  private func resetObservations() {
    if let token = timeObserver, let player = observedPlayer {
      player.removeTimeObserver(token)
    }
    timeObserver = nil
    observedPlayer = nil

    timeControlObservation?.invalidate()
    timeControlObservation = nil
    playerLayerReadyObservation?.invalidate()
    playerLayerReadyObservation = nil
    pipPossibleObservation?.invalidate()
    pipPossibleObservation = nil

    if #available(iOS 14.2, *) {
      pipController?.canStartPictureInPictureAutomaticallyFromInline = false
    }

    pipController?.delegate = nil
    pipController = nil
  }

  private func detachFromInlinePlayer() {
    resetObservations()
    playerLayer = nil
    autoStartArmed = false
    shouldAttemptStartWhenReady = false
    lifecycleSceneHint = nil
    unregisterLifecycleNotifications()
  }

  private func startPiP(url: String?, positionMs: Int?, result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      print("[PiP] startPiP: url=\(url ?? "<nil>") posMs=\(positionMs ?? -1)")
      guard let self else {
        result(false)
        return
      }

      registerLifecycleNotificationsIfNeeded()
      autoStartArmed = false
      updateSystemAutoPiP()

      guard AVPictureInPictureController.isPictureInPictureSupported() else {
        result(false)
        return
      }

      guard ensureInlineLayerAvailable() else {
        print("[PiP] startPiP: inline layer unavailable")
        result(false)
        return
      }

      if let ms = positionMs {
        lastKnownPosition = CMTime(value: Int64(ms), timescale: 1000)
      } else if let player = observedPlayer {
        lastKnownPosition = player.currentTime()
      }

      if #available(iOS 13.0, *) {
        guard let scene = self.flutterController?.view.window?.windowScene else {
          print("[PiP] No active window scene available; cannot start PiP.")
          result(false)
          return
        }
        self.lifecycleSceneHint = scene
      }

      guard let controller = self.pipController else {
        result(false)
        return
      }

      if controller.isPictureInPictureActive {
        result(true)
        return
      }

      if #available(iOS 14.2, *) {
        guard controller.isPictureInPicturePossible else {
          self.pendingStartResult = result
          self.shouldAttemptStartWhenReady = true
          return
        }
        if let layer = self.playerLayer, !layer.isReadyForDisplay {
          self.pendingStartResult = result
          self.shouldAttemptStartWhenReady = true
          return
        }
        self.pendingStartResult = result
        self.shouldAttemptStartWhenReady = false
        controller.startPictureInPicture()
        return
      }

      self.pendingStartResult = result
      self.shouldAttemptStartWhenReady = true
      self.startPiPWhenPossible()
    }
  }

  private func startPiPWhenPossible() {
    guard shouldAttemptStartWhenReady else { return }
    guard let controller = pipController else { return }

    if controller.isPictureInPictureActive {
      completePendingStart(success: true)
      return
    }

    if #available(iOS 13.0, *) {
      if let activeScene = flutterController?.view.window?.windowScene {
        lifecycleSceneHint = activeScene
      }
    }

    guard controller.isPictureInPicturePossible else { return }
    if let layer = playerLayer, !layer.isReadyForDisplay { return }

    shouldAttemptStartWhenReady = false
    controller.startPictureInPicture()
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
        // If PiP is not active, do NOT tear down the binding; keep the inline layer attached
        // so auto‑PiP / subsequent starts can still work.
        self.completePendingStart(success: false)
        result(position)
        return
      }

      self.pendingStopResult = result
      self.pendingStopPosition = position
      controller.stopPictureInPicture()
    }
  }

  private func registerLifecycleNotificationsIfNeeded() {
    guard !lifecycleNotificationsRegistered else { return }
    lifecycleNotificationsRegistered = true

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(onApplicationWillResignActive(_:)),
      name: UIApplication.willResignActiveNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(onApplicationDidEnterBackground(_:)),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )

    if #available(iOS 13.0, *) {
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(onSceneWillDeactivate(_:)),
        name: UIScene.willDeactivateNotification,
        object: nil
      )
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(onDidBecomeActive(_:)),
        name: UIScene.didActivateNotification,
        object: nil
      )
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(onSceneDidEnterBackground(_:)),
        name: UIScene.didEnterBackgroundNotification,
        object: nil
      )
    } else {
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(onDidBecomeActive(_:)),
        name: UIApplication.didBecomeActiveNotification,
        object: nil
      )
    }
  }

  private func unregisterLifecycleNotifications() {
    guard lifecycleNotificationsRegistered else { return }
    lifecycleNotificationsRegistered = false

    NotificationCenter.default.removeObserver(self, name: UIApplication.willResignActiveNotification, object: nil)
    NotificationCenter.default.removeObserver(self, name: UIApplication.didEnterBackgroundNotification, object: nil)

    if #available(iOS 13.0, *) {
      NotificationCenter.default.removeObserver(self, name: UIScene.willDeactivateNotification, object: nil)
      NotificationCenter.default.removeObserver(self, name: UIScene.didActivateNotification, object: nil)
      NotificationCenter.default.removeObserver(self, name: UIScene.didEnterBackgroundNotification, object: nil)
    } else {
      NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
    }
  }

    @objc private func onApplicationWillResignActive(_ notification: Notification) {
      // Do NOT start PiP here: the scene is transitioning away from ForegroundActive
      // and attempting to start PiP at this moment can cause AVKitErrorDomain -1001.
      shouldAttemptStartWhenReady = false
      updateSystemAutoPiP()
      #if DEBUG
      print("[PiP] willResignActive: armed=\(autoStartArmed) possible=\(pipController?.isPictureInPicturePossible ?? false) ready=\(playerLayer?.isReadyForDisplay ?? false)")
      #endif
    }

  @available(iOS 13.0, *)
  @objc private func onSceneWillDeactivate(_ notification: Notification) {
    guard let scene = notification.object as? UIScene else { return }
    lifecycleSceneHint = scene
    shouldAttemptStartWhenReady = false
    updateSystemAutoPiP()
  }

  @objc private func onDidBecomeActive(_ notification: Notification) {
    if #available(iOS 13.0, *) {
      guard let scene = notification.object as? UIScene else { return }
      if lifecycleSceneHint == nil || lifecycleSceneHint === scene {
        if pendingStartResult != nil {
          shouldAttemptStartWhenReady = true
          startPiPWhenPossible()
        } else {
          shouldAttemptStartWhenReady = false
        }
      }
    } else {
      if pendingStartResult != nil {
        shouldAttemptStartWhenReady = true
        startPiPWhenPossible()
      } else {
        shouldAttemptStartWhenReady = false
      }
    }
    updateSystemAutoPiP()
  }

  @objc private func onApplicationDidEnterBackground(_ notification: Notification) {
    shouldAttemptStartWhenReady = false
    updateSystemAutoPiP()
  }

  @available(iOS 13.0, *)
  @objc private func onSceneDidEnterBackground(_ notification: Notification) {
    guard let scene = notification.object as? UIScene else { return }
    lifecycleSceneHint = scene
    shouldAttemptStartWhenReady = false
    updateSystemAutoPiP()
  }

  private func updateSystemAutoPiP() {
    guard #available(iOS 14.2, *) else { return }
    guard let controller = pipController else { return }
    let status = observedPlayer?.timeControlStatus ?? .paused
    let playingLike = (status == .playing) || (status == .waitingToPlayAtSpecifiedRate)
    let enable = autoStartArmed && playingLike
    controller.canStartPictureInPictureAutomaticallyFromInline = enable
    print("[PiP] updateSystemAutoPiP: armed=\(autoStartArmed) status=\(status.rawValue) enable=\(enable)")
  }

  private func currentPositionMilliseconds() -> Int? {
    if let player = observedPlayer {
      return milliseconds(from: player.currentTime())
    }
    return milliseconds(from: lastKnownPosition)
  }

  private func milliseconds(from time: CMTime) -> Int? {
    guard time.isValid && time.isNumeric else { return nil }
    let seconds = CMTimeGetSeconds(time)
    if seconds.isNaN || seconds.isInfinite { return nil }
    return Int((seconds * 1000.0).rounded())
  }

  private func completePendingStart(success: Bool) {
    shouldAttemptStartWhenReady = false
    lifecycleSceneHint = nil
    if let callback = pendingStartResult {
      pendingStartResult = nil
      callback(success)
    }
  }

  private func finishPendingStop() {
    completePendingStart(success: false)
    let position = pendingStopPosition ?? currentPositionMilliseconds()
    pendingStopPosition = nil
    detachFromInlinePlayer()
    if let result = pendingStopResult {
      pendingStopResult = nil
      result(position)
    }
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

  deinit {
    unregisterLifecycleNotifications()
  }
}
