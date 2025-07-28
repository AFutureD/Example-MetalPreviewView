//
//  File.swift
//  
//
//  Created by 尼诺 on 2023/12/8.
//

import Foundation
import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        true
    }
    
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        return .defaultScene
    }
}

extension UISceneConfiguration {
    public static let defaultScene: UISceneConfiguration = {
        let scene = UISceneConfiguration.init(name: "Default Scene Configuration", sessionRole: .windowApplication)
        scene.delegateClass = SceneDelegate.self
        return scene
    }()
}
