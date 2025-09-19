import Flutter
import UIKit

/// Flutter platform view factory that exposes the shared PlayerEngine's view to Dart.
final class NativePlayerViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return NativePlayerView(frame: frame)
  }
}

final class NativePlayerView: NSObject, FlutterPlatformView {
  private let container: PlayerContainerView

  init(frame: CGRect) {
    container = PlayerContainerView(frame: frame)
    super.init()
    PlayerEngine.shared.attach(to: container)
  }

  func view() -> UIView {
    return container
  }
}

