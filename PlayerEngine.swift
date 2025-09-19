import AVFoundation
import AVKit
import Flutter

/// Centralized video player engine that owns a single AVPlayer instance and exposes
/// playback/PiP control over Flutter channels. The same player drives the inline view,
/// fullscreen transitions, and system Picture in Picture.
final class PlayerEngine: NSObject, FlutterStreamHandler, AVPictureInPictureControllerDelegate, AVPlayerViewControllerDelegate {
  static let shared = PlayerEngine()

  private let player = AVPlayer()
  private let playerLayer = AVPlayerLayer()
  private var pipController: AVPictureInPictureController?

  private var channel: FlutterMethodChannel?
  private var eventSink: FlutterEventSink?

  private weak var hostView: PlayerContainerView?
  private var timeObserver: Any?
  private var statusObserver: NSKeyValueObservation?
  private var presentationSizeObserver: NSKeyValueObservation?
  private var keepUpObserver: NSKeyValueObservation?
  private var bufferEmptyObserver: NSKeyValueObservation?
  private var observingRate = false
  private var desiredRate: Float = 1.0

  private var lastKnownPosition: CMTime = .zero
  private var isReadyForDisplay = false

  private override init() {
    super.init()
    configureAudioSession()
    playerLayer.player = player
    playerLayer.videoGravity = .resizeAspect
    addPeriodicObserver()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handlePlaybackEnded(_:)),
      name: .AVPlayerItemDidPlayToEndTime,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    if let observer = timeObserver {
      player.removeTimeObserver(observer)
      timeObserver = nil
    }
    removeRateObserver()
  }

  // MARK: - Public API -----------------------------------------------------------------

  func configureChannels(messenger: FlutterBinaryMessenger) {
    if channel != nil { return }
    let method = FlutterMethodChannel(name: "app.player", binaryMessenger: messenger)
    method.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    channel = method

    let eventChannel = FlutterEventChannel(name: "app.player/events", binaryMessenger: messenger)
    eventChannel.setStreamHandler(self)
  }

  func attach(to view: PlayerContainerView) {
    if hostView === view { return }
    hostView?.detachPlayerLayer()
    hostView = view
    view.attach(playerLayer: playerLayer)
  }

  private var lastViewport: CGRect = .zero

  func updateViewport(frame: CGRect) {
    lastViewport = frame
    // Avoid using private KVC setters like `_sourceViewFrame` which crash on device.
    // Modern AVPictureInPictureController automatically animates from the
    // inline player layer when `canStartPictureInPictureAutomaticallyFromInline`
    // is enabled, so we only keep the viewport for potential future API usage.
  }

  // MARK: - Method channel handling -----------------------------------------------------

  private func handle(call: FlutterMethodCall, result: FlutterResult) {
    switch call.method {
    case "setSource":
      guard let urlString = call.arguments as? String else {
        result(FlutterError(code: "invalid_args", message: "Missing url", details: nil))
        return
      }
      setSource(urlString: urlString, result: result)
    case "play":
      if player.currentItem != nil {
        if #available(iOS 10.0, *) {
          player.playImmediately(atRate: desiredRate)
        } else {
          player.play()
          player.rate = desiredRate
        }
      }
      sendStatusEvent()
      result(nil)
    case "pause":
      player.pause()
      sendStatusEvent()
      result(nil)
    case "seekTo":
      if let ms = call.arguments as? Int {
        let target = CMTime(value: CMTimeValue(ms), timescale: 1000)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
          self?.sendProgressEvent()
        }
        result(nil)
      } else {
        result(FlutterError(code: "invalid_args", message: "Missing position", details: nil))
      }
    case "setRate":
      if let rate = call.arguments as? Double {
        desiredRate = Float(rate)
        if player.rate > 0.0 {
          player.rate = desiredRate
        }
        result(nil)
      } else {
        result(FlutterError(code: "invalid_args", message: "Missing rate", details: nil))
      }
    case "setVolume":
      if let volume = call.arguments as? Double {
        player.volume = Float(min(max(volume, 0.0), 1.0))
        result(nil)
      } else {
        result(FlutterError(code: "invalid_args", message: "Missing volume", details: nil))
      }
    case "enterPiP":
      enterPiP(result: result)
    case "stopPiP":
      stopPiP(result: result)
    case "isPiPPossible":
      result(isPiPPossible())
    case "currentState":
      result(currentState())
    case "updateViewport":
      if let dict = call.arguments as? [String: Any],
         let x = dict["x"] as? Double,
         let y = dict["y"] as? Double,
         let width = dict["width"] as? Double,
         let height = dict["height"] as? Double {
        updateViewport(frame: CGRect(x: x, y: y, width: width, height: height))
        result(nil)
      } else {
        result(FlutterError(code: "invalid_args", message: "updateViewport expects {x,y,width,height}", details: nil))
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func setSource(urlString: String, result: FlutterResult) {
    guard let url = resolveURL(from: urlString) else {
      result(FlutterError(code: "invalid_url", message: "Cannot resolve url", details: urlString))
      return
    }
    let asset = AVURLAsset(url: url)
    let item = AVPlayerItem(asset: asset)
    attachObservers(to: item)
    player.replaceCurrentItem(with: item)
    ensurePiPController()
    result(nil)
  }

  private func enterPiP(result: FlutterResult) {
    guard let pip = pipController else {
      result(false)
      return
    }
    guard pip.isPictureInPicturePossible else {
      result(false)
      return
    }
    if pip.isPictureInPictureActive {
      result(true)
      return
    }
    pip.startPictureInPicture()
    result(true)
  }

  private func stopPiP(result: FlutterResult) {
    guard let pip = pipController else {
      result(nil)
      return
    }
    if pip.isPictureInPictureActive {
      pip.stopPictureInPicture()
    }
    result(nil)
  }

  private func isPiPPossible() -> Bool {
    guard let pip = pipController else { return false }
    return pip.isPictureInPicturePossible && isReadyForDisplay
  }

  private func currentState() -> [String: Any] {
    let position = player.currentTime()
    let duration = player.currentItem?.duration ?? .zero
    let size = player.currentItem?.presentationSize ?? .zero
    return [
      "positionMs": milliseconds(from: position),
      "durationMs": milliseconds(from: duration),
      "isPlaying": player.rate > 0.1,
      "isReady": isReadyForDisplay,
      "width": size.width,
      "height": size.height,
      "volume": player.volume,
      "speed": player.rate,
    ].compactMapValues { $0 }
  }

  // MARK: - Observers -------------------------------------------------------------------

  private func addPeriodicObserver() {
    if timeObserver == nil {
      timeObserver = player.addPeriodicTimeObserver(
        forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
        queue: .main
      ) { [weak self] _ in
        self?.sendProgressEvent()
      }
    }
    ensureRateObserver()
  }

  private func attachObservers(to item: AVPlayerItem) {
    statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
      self?.handleStatusChange(status: item.status)
    }
    keepUpObserver = item.observe(\.isPlaybackLikelyToKeepUp, options: [.initial, .new]) { [weak self] item, _ in
      self?.handleBufferingChange(likelyToKeepUp: item.isPlaybackLikelyToKeepUp)
    }
    bufferEmptyObserver = item.observe(\.isPlaybackBufferEmpty, options: [.initial, .new]) { [weak self] item, _ in
      self?.handleBufferEmpty(empty: item.isPlaybackBufferEmpty)
    }
    presentationSizeObserver = item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
      self?.sendPresentationEvent(size: item.presentationSize)
    }
  }

  private func handleStatusChange(status: AVPlayerItem.Status) {
    DispatchQueue.main.async {
      self.isReadyForDisplay = status == .readyToPlay
      if status == .failed {
        self.sendErrorEvent(error: self.player.currentItem?.error)
      }
      self.sendStatusEvent()
    }
  }

  private func handleBufferingChange(likelyToKeepUp: Bool) {
    DispatchQueue.main.async {
      self.sendStatusEvent(isBuffering: !likelyToKeepUp)
    }
  }

  private func handleBufferEmpty(empty: Bool) {
    DispatchQueue.main.async {
      if empty {
        self.sendStatusEvent(isBuffering: true)
      }
    }
  }

  @objc private func handlePlaybackEnded(_ notification: Notification) {
    guard let item = notification.object as? AVPlayerItem, item === player.currentItem else { return }
    DispatchQueue.main.async {
      self.player.seek(to: .zero)
      self.player.pause()
      self.sendStatusEvent()
      self.sendEvent(["type": "ended"])
    }
  }

  // MARK: - Event helpers ----------------------------------------------------------------

  private func sendProgressEvent() {
    var payload = currentState()
    payload["type"] = "progress"
    sendEvent(payload)
  }

  private func sendStatusEvent(isBuffering: Bool? = nil) {
    var payload = currentState()
    payload["type"] = "status"
    if let isBuffering {
      payload["isBuffering"] = isBuffering
    }
    sendEvent(payload)
  }

  private func sendPresentationEvent(size: CGSize) {
    sendEvent([
      "type": "presentation",
      "width": size.width,
      "height": size.height,
    ])
  }

  private func sendErrorEvent(error: Error?) {
    var payload: [String: Any] = ["type": "error"]
    if let error {
      payload["message"] = error.localizedDescription
    }
    sendEvent(payload)
  }

  private func sendEvent(_ payload: [String: Any]) {
    guard let sink = eventSink else { return }
    sink(payload)
  }

  private func ensureRateObserver() {
    guard !observingRate else { return }
    player.addObserver(self, forKeyPath: #keyPath(AVPlayer.rate), options: [.initial, .new], context: nil)
    observingRate = true
  }

  private func removeRateObserver() {
    guard observingRate else { return }
    observingRate = false
    player.removeObserver(self, forKeyPath: #keyPath(AVPlayer.rate))
  }

  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
    if keyPath == #keyPath(AVPlayer.rate) {
      DispatchQueue.main.async { [weak self] in
        self?.sendStatusEvent()
      }
      return
    }
    super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
  }

  // MARK: - PiP -------------------------------------------------------------------------

  private func ensurePiPController() {
    guard pipController == nil else { return }
    if #available(iOS 15.0, *) {
      let source = AVPictureInPictureController.ContentSource(playerLayer: playerLayer)
      let controller = AVPictureInPictureController(contentSource: source)
      controller.delegate = self
      pipController = controller
    }
  }

  func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    sendEvent(["type": "pip", "state": "started"])
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    sendEvent(["type": "pip", "state": "stopped", "positionMs": milliseconds(from: player.currentTime())])
  }

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
    sendEvent(["type": "pip", "state": "failed", "message": error.localizedDescription])
  }

  // MARK: - Stream handler --------------------------------------------------------------

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    sendStatusEvent()
    sendProgressEvent()
    if let size = player.currentItem?.presentationSize {
      sendPresentationEvent(size: size)
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  // MARK: - Helpers ---------------------------------------------------------------------

  private func configureAudioSession() {
    #if os(iOS)
      let session = AVAudioSession.sharedInstance()
      try? session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay, .allowBluetooth])
      try? session.setActive(true)
    #endif
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
}

// MARK: - PlayerContainerView ------------------------------------------------------------

/// Simple UIView subclass that hosts the AVPlayerLayer and updates its frame when the
/// Flutter platform view resizes.
final class PlayerContainerView: UIView {
  private weak var playerLayer: AVPlayerLayer?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = true
    backgroundColor = .black
    autoresizingMask = [.flexibleWidth, .flexibleHeight]
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  func attach(playerLayer: AVPlayerLayer) {
    self.playerLayer?.removeFromSuperlayer()
    self.playerLayer = playerLayer
    layer.addSublayer(playerLayer)
    setNeedsLayout()
  }

  func detachPlayerLayer() {
    playerLayer?.removeFromSuperlayer()
    playerLayer = nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    playerLayer?.frame = bounds
    CATransaction.commit()
  }
}
