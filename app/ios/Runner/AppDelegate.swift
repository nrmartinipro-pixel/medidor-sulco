import ARKit
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
    override func application(_ application: UIApplication,
                              didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let controller = window?.rootViewController as! FlutterViewController

        registrar(forPlugin: "ARDepth")!.register(ARDepthViewFactory(), withId: "medidor/ar-depth")

        FlutterMethodChannel(name: "medidor/depth", binaryMessenger: controller.binaryMessenger)
            .setMethodCallHandler { call, result in
                switch call.method {
                case "isSupported":
                    // LiDAR: sceneDepth só existe em aparelhos com o sensor
                    result(ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth))
                case "measureAt":
                    guard let a = call.arguments as? [String: Double], let x = a["x"], let y = a["y"],
                          let v = ARDepthView.active else {
                        return result(FlutterError(code: "NO_DEPTH", message: "View não aberta", details: nil))
                    }
                    v.measure(at: CGPoint(x: x, y: y), result: result)
                default:
                    result(FlutterMethodNotImplemented)
                }
            }

        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}

/*
 Info.plist:
   <key>NSCameraUsageDescription</key>
   <string>A câmera é usada para medir a profundidade dos sulcos do pneu.</string>
   <key>UISupportedInterfaceOrientations</key>
   <array><string>UIInterfaceOrientationLandscapeLeft</string></array>
 Deployment target: iOS 14+ (sceneDepth).
*/
