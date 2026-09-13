import Foundation
import NotifyBridgeCore

/// Bridges WeChat / QQ notifications into Atoll's Dynamic Island.
/// The work lives in `NotifyBridgeCore` so it can be tested; this is only the
/// entry point launchd starts.
@main
struct NotifyBridgeMain {
    static func main() async {
        await NotifyBridge.run()
    }
}
