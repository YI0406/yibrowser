import UIKit
import Flutter


class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  private var quickActionChannel: FlutterMethodChannel?
  private var pendingShortcutType: String?

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }
    if let shortcut = connectionOptions.shortcutItem {
      pendingShortcutType = shortcut.type
    }

    let window = UIWindow(windowScene: windowScene)
    let flutterVC = FlutterViewController(project: nil, nibName: nil, bundle: nil)
    GeneratedPluginRegistrant.register(with: flutterVC)

    if let registrar = flutterVC.registrar(forPlugin: "NativePlayerViewFactory") {
      let messenger = registrar.messenger()
      PlayerEngine.shared.configureChannels(messenger: messenger)
      registrar.register(NativePlayerViewFactory(messenger: messenger), withId: "native-player-view")
    }
    let channel = FlutterMethodChannel(
      name: "app.quick_actions_bridge",
      binaryMessenger: flutterVC.binaryMessenger
    )
    quickActionChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
      case "readyForQuickActions":
        if let pending = self.pendingShortcutType {
          self.pendingShortcutType = nil
          self.emitShortcut(type: pending, fromLaunch: true)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    window.rootViewController = flutterVC
    self.window = window
    window.makeKeyAndVisible()
    for context in connectionOptions.urlContexts {
      handleIncomingURL(context)
    }
  }
  private func emitShortcut(type: String, fromLaunch: Bool) {
    quickActionChannel?.invokeMethod(
      "launchShortcut",
      arguments: [
        "type": type,
        "from_launch": fromLaunch,
      ]
    )
  }

  func windowScene(
    _ windowScene: UIWindowScene,
    performActionFor shortcutItem: UIApplicationShortcutItem,
    completionHandler: @escaping (Bool) -> Void
  ) {
    if quickActionChannel == nil {
      pendingShortcutType = shortcutItem.type
    } else {
      emitShortcut(type: shortcutItem.type, fromLaunch: false)
    }
    completionHandler(true)
  }

  func scene(
    _ scene: UIScene,
    openURLContexts URLContexts: Set<UIOpenURLContext>
  ) {
    for context in URLContexts {
      handleIncomingURL(context)
    }
  }

  private func handleIncomingURL(_ context: UIOpenURLContext) {
    guard
      let appDelegate = UIApplication.shared.delegate as? FlutterAppDelegate
    else {
      return
    }
    var options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    if let sourceApp = context.options.sourceApplication {
      options[.sourceApplication] = sourceApp
    }
    if let annotation = context.options.annotation {
      options[.annotation] = annotation
    }
    options[.openInPlace] = context.options.openInPlace
      _ = appDelegate.application(
      UIApplication.shared,
      open: context.url,
      options: options
    )
  }
}
