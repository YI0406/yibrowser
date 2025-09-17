import UIKit
import AVFoundation
import AVKit
import Flutter

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
  private var playerLayerReadyObservation: NSKeyValueObservation?
  private var pipPossibleObservation: NSKeyValueObservation?
  private var timeObserver: Any?

  private var currentUrl: String?
  private var pendingSeek: CMTime?
  private var pendingStartResult: FlutterResult?
  private var pendingStopResult: FlutterResult?
  private var pendingStopPosition: Int?
  private var lastKnownPosition: CMTime = .zero
  private var isPrimingPlayback = false
  private var primingTargetTime: CMTime?
    private var autoStartArmed = false
    private var autoStartInProgress = false
    private var autoStartAwaitingBackground = false
  

  private var lifecycleNotificationsRegistered = false
  private var shouldAttemptStartWhenReady = false
  @available(iOS 13.0, *)
  private weak var lifecycleSceneHint: UIScene?

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

    registerLifecycleNotificationsIfNeeded()
  }

  func primePiP(url: String?, positionMs: Int?, result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        result(false)
        return
      }
        print("[PiP] prime: url=\(url ?? "<nil>") posMs=\(positionMs ?? -1)")
      self.registerLifecycleNotificationsIfNeeded()
      guard AVPictureInPictureController.isPictureInPictureSupported() else {
          print("[PiP] prime: isPictureInPictureSupported == false")
        result(false)
        return
      }
      if let providedUrl = url, !providedUrl.isEmpty {
        if self.currentUrl != providedUrl {
          guard self.preparePlayer(with: providedUrl, autoPlay: false) else {
            result(false)
            return
          }
        }
      } else if self.player == nil {
          print("[PiP] prime: no existing player and no url provided")
        result(false)
        return
      }
      if let ms = positionMs {
        self.seek(toMilliseconds: ms)
      }
      self.primingTargetTime = self.pendingSeek ?? self.lastKnownPosition
      if self.playerLayer?.isReadyForDisplay == true {
        self.applyPrimingTargetImmediatelyIfNeeded()
      } else {
        self.beginPrimingPlaybackIfNeeded()
      }
      self.autoStartArmed = true
      self.autoStartAwaitingBackground = true
      self.autoStartInProgress = false
      result(true)
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
        selector: #selector(onSceneDidEnterBackground(_:)),
        name: UIScene.didEnterBackgroundNotification,
        object: nil
      )
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
    if pendingStartResult != nil || autoStartInProgress {
      // Arm and try to start immediately while the scene is still active
      shouldAttemptStartWhenReady = true
      startPiPWhenPossible()
    }
  }

  @objc private func onApplicationDidEnterBackground(_ notification: Notification) {
    requestAutoStartAfterBackground(for: nil)
  }

  @available(iOS 13.0, *)
  @objc private func onSceneWillDeactivate(_ notification: Notification) {
    guard let scene = notification.object as? UIScene else { return }
    lifecycleSceneHint = scene
    if pendingStartResult != nil || autoStartInProgress {
      startPiPWhenPossible()
    }
  }

  @available(iOS 13.0, *)
  @objc private func onSceneDidEnterBackground(_ notification: Notification) {
    guard let scene = notification.object as? UIScene else { return }
    requestAutoStartAfterBackground(for: scene)
  }

  private func requestAutoStartAfterBackground(for scene: UIScene?) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      self?.beginAutoStartAfterBackground(for: scene)
    }
  }

  private func beginAutoStartAfterBackground(for scene: UIScene?) {
    guard autoStartArmed,
          autoStartAwaitingBackground,
          !autoStartInProgress,
          pipController != nil else { return }

    if #available(iOS 13.0, *), let scene = scene {
      if let hint = lifecycleSceneHint, hint !== scene { return }
      lifecycleSceneHint = scene
    }

    autoStartAwaitingBackground = false
    autoStartInProgress = true
    shouldAttemptStartWhenReady = true
    startPiPWhenPossible()
  }

  @objc private func onDidBecomeActive(_ notification: Notification) {
    // Returning to the app: ensure PiP is stopped so the inline player takes over.
    if let controller = pipController, controller.isPictureInPictureActive {
      controller.stopPictureInPicture()
    }
    autoStartArmed = false
    autoStartInProgress = false
    shouldAttemptStartWhenReady = false
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
    case "exit":
      stopPiP(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startPiP(url: String?, positionMs: Int?, result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      print("[PiP] startPiP: url=\(url ?? "<nil>") posMs=\(positionMs ?? -1)")
      guard let self else {
        result(false)
        return
      }

      self.registerLifecycleNotificationsIfNeeded()
      self.autoStartArmed = false
      self.autoStartAwaitingBackground = false
      self.autoStartInProgress = false

      guard AVPictureInPictureController.isPictureInPictureSupported() else {
        result(false)
        return
      }

      if let providedUrl = url, !providedUrl.isEmpty {
        if self.currentUrl != providedUrl {
          guard self.preparePlayer(with: providedUrl, autoPlay: false) else {
            result(false)
            return
          }
        }
      } else if self.player == nil {
        print("[PiP] startPiP: no existing player and no url provided")
        result(false)
        return
      }

      if let ms = positionMs {
        self.seek(toMilliseconds: ms)
      }
      if let player = self.player {
        player.isMuted = false
        if player.timeControlStatus == .paused {
          if player.currentItem?.status == .readyToPlay {
            player.preroll(atRate: 1.0) { _ in }
          } else {
            self.beginPrimingPlaybackIfNeeded()
          }
        }
      }
      if #available(iOS 13.0, *) {
        guard let scene = self.flutterController?.view.window?.windowScene else {
          print("[PiP] No active window scene available; cannot start PiP.")
          result(false)
          return
        }
        self.lifecycleSceneHint = scene
      }
      if self.pipController?.isPictureInPictureActive == true {
        result(true)
        return
      }
      if self.autoStartInProgress {
        self.pendingStartResult = result
        self.startPiPWhenPossible()
        return
      }
      self.pendingStartResult = result
      self.shouldAttemptStartWhenReady = true
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

  private func preparePlayer(with urlString: String, autoPlay: Bool = false) -> Bool {
    print("[PiP] preparePlayer: urlString=\(urlString) autoPlay=\(autoPlay)")
    guard let url = resolveUrl(from: urlString) else {
      print("[PiP] preparePlayer: resolveUrl failed for urlString=\(urlString)")
      return false
    }

    teardownPlayer()

    let item = AVPlayerItem(url: url)
    print("[PiP] preparePlayer: AVPlayerItem created")
    if #available(iOS 15.0, *) {
      item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
    }

    let player = AVPlayer(playerItem: item)
    print("[PiP] preparePlayer: AVPlayer created")
    player.automaticallyWaitsToMinimizeStalling = true
    player.preventsDisplaySleepDuringVideoPlayback = true

    let layer = AVPlayerLayer(player: player)
    layer.frame = hostView.bounds
    layer.videoGravity = .resizeAspect
    hostView.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
    hostView.layer.addSublayer(layer)
    print("[PiP] preparePlayer: AVPlayerLayer attached (frame=\(layer.frame))")

    let controller: AVPictureInPictureController?
    if #available(iOS 15.0, *) {
      let activeScene = self.flutterController?.view.window?.windowScene
        ?? (UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene)
      if let s = activeScene {
        print("[PiP] preparePlayer: using activeScene=\(s) for ContentSource")
        let source = AVPictureInPictureController.ContentSource(playerLayer: layer)
        controller = AVPictureInPictureController(contentSource: source)
      } else {
        print("[PiP] preparePlayer: NO activeScene found; using layer-only ContentSource")
        let source = AVPictureInPictureController.ContentSource(playerLayer: layer)
        controller = AVPictureInPictureController(contentSource: source)
      }
    } else {
      controller = AVPictureInPictureController(playerLayer: layer)
    }

    guard let pipController = controller else {
      print("[PiP] preparePlayer: AVPictureInPictureController init returned nil")
      player.pause()
      return false
    }

    pipController.delegate = self
    pipController.requiresLinearPlayback = false
    print("[PiP] preparePlayer: pipController configured (requiresLinearPlayback=false)")

    pipPossibleObservation = pipController.observe(
      \AVPictureInPictureController.isPictureInPicturePossible,
      options: [.new]
    ) { [weak self] _, change in
      guard let possible = change.newValue, possible else { return }
      print("[PiP] KVO: isPictureInPicturePossible -> \(possible)")
      DispatchQueue.main.async {
        self?.startPiPWhenPossible()
      }
    }

    playerStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
      guard let self else { return }
      if item.status == .readyToPlay {
        print("[PiP] KVO: item.status == .readyToPlay")
        DispatchQueue.main.async {
          self.finishPrimingPlaybackIfNeeded()
          self.applyPendingSeekIfNeeded()
          self.startPiPWhenPossible()
        }
      }
    }

    // Observe playerLayer's isReadyForDisplay property
    playerLayerReadyObservation = layer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, change in
      guard let self else { return }
      if layer.isReadyForDisplay {
        print("[PiP] KVO: layer.isReadyForDisplay == true")
        DispatchQueue.main.async {
          self.finishPrimingPlaybackIfNeeded()
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
    self.isPrimingPlayback = false
    self.primingTargetTime = nil

    if autoPlay {
      player.play()
    }

    registerLifecycleNotificationsIfNeeded()

    if shouldAttemptStartWhenReady {
      startPiPWhenPossible()
    }

    print("[PiP] preparePlayer: finished (autoPlay=\(autoPlay))")
    return pipController != nil
  }

  private func startPiPWhenPossible() {
    guard shouldAttemptStartWhenReady else { return }
    guard let controller = pipController else { return }
    guard pendingStartResult != nil || autoStartInProgress else { return }

    if controller.isPictureInPictureActive {
      completePendingStart(success: true)
      return
    }

    var canStartForState = true
    if #available(iOS 13.0, *) {
      let state: UIScene.ActivationState? = {
        if let activeScene = flutterController?.view.window?.windowScene {
          lifecycleSceneHint = activeScene
          return activeScene.activationState
        }
        return lifecycleSceneHint?.activationState
      }()
      // We allow starting during the transition (foregroundInactive) or when backgrounded.
      if let s = state {
        canStartForState = (s == .foregroundInactive || s == .background)
      }
    }
    if !canStartForState && !autoStartInProgress {
      // Not in a good windowing phase to start; try again when lifecycle changes.
      return
    }

    if player?.timeControlStatus != .playing {
      player?.play()
    }

    // Start only when possible and the layer is ready for display to avoid -1001
    guard controller.isPictureInPicturePossible else { return }
    if let l = playerLayer, l.isReadyForDisplay == false { return }
    autoStartArmed = false
    controller.startPictureInPicture()
  }

  private func beginPrimingPlaybackIfNeeded() {
    guard let player = player else { return }
    guard playerLayer?.isReadyForDisplay != true else {
      applyPrimingTargetImmediatelyIfNeeded()
      return
    }
    guard !isPrimingPlayback else { return }

    isPrimingPlayback = true
    player.isMuted = true
    if player.timeControlStatus != .playing {
      player.play()
    }
  }

  private func finishPrimingPlaybackIfNeeded() {
    guard isPrimingPlayback, let player = player else { return }

    isPrimingPlayback = false
    defer {
      primingTargetTime = nil
      player.isMuted = false
    }

    guard pendingStartResult == nil,
          pipController?.isPictureInPictureActive != true else {
      return
    }

    player.pause()
    if let target = primingTargetTime {
      player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
      lastKnownPosition = target
    }
  }

  private func applyPrimingTargetImmediatelyIfNeeded() {
    guard let player = player else { return }

    defer {
      primingTargetTime = nil
      isPrimingPlayback = false
      player.isMuted = false
    }

    guard pendingStartResult == nil,
          pipController?.isPictureInPictureActive != true else {
      return
    }

    player.pause()
    if let target = primingTargetTime {
      player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
      lastKnownPosition = target
    }
  }

  private func completePendingStart(success: Bool) {
    shouldAttemptStartWhenReady = false
    lifecycleSceneHint = nil
    autoStartInProgress = false
    autoStartAwaitingBackground = false
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
    unregisterLifecycleNotifications()
    shouldAttemptStartWhenReady = false
    lifecycleSceneHint = nil
    autoStartArmed = false
    autoStartInProgress = false
    autoStartAwaitingBackground = false

    if let token = timeObserver {
      player?.removeTimeObserver(token)
      timeObserver = nil
    }
    playerStatusObservation?.invalidate()
    playerStatusObservation = nil
    playerLayerReadyObservation?.invalidate()
    playerLayerReadyObservation = nil
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
    isPrimingPlayback = false
    primingTargetTime = nil
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

  deinit {
    unregisterLifecycleNotifications()
  }
}
