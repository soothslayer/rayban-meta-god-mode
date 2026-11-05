import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

@main
struct CJApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, live: model.live, glasses: model.glasses)
                .tint(Color(red: 0.48, green: 0.93, blue: 0.75))
                .preferredColorScheme(.dark)
                .task { model.setup() }
                .onOpenURL { url in Task { await model.glasses.handle(url) } }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { model.setForeground(false); model.glasses.enteredBackground() }
                    if phase == .active { model.setForeground(true) }
                }
        }
    }
}
