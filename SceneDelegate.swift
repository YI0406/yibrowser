import UIKit
import Flutter

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }

    let window = UIWindow(windowScene: windowScene)
    let flutterVC = FlutterViewController(project: nil, nibName: nil, bundle: nil)
    GeneratedPluginRegistrant.register(with: flutterVC)

    if let registrar = flutterVC.registrar(forPlugin: "NativePlayerViewFactory") {
      let messenger = registrar.messenger()
      PlayerEngine.shared.configureChannels(messenger: messenger)
      registrar.register(NativePlayerViewFactory(messenger: messenger), withId: "native-player-view")
    }

    window.rootViewController = flutterVC
    self.window = window
    window.makeKeyAndVisible()
  }
}
