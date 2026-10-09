import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  private var privacyCover: UIView?

  override func sceneWillResignActive(_ scene: UIScene) {
    if let scene = scene as? UIWindowScene,
       let window = scene.windows.first(where: { $0.isKeyWindow }) {
      let cover = UIView(frame: window.bounds)
      cover.backgroundColor = UIColor(red: 18/255, green: 20/255, blue: 27/255, alpha: 1)
      cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      cover.isUserInteractionEnabled = true
      window.addSubview(cover)
      privacyCover?.removeFromSuperview()
      privacyCover = cover
    }
    super.sceneWillResignActive(scene)
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    privacyCover?.removeFromSuperview()
    privacyCover = nil
  }
}
