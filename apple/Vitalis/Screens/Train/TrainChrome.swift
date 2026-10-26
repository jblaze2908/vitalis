import SwiftUI
import VitalisKit
import VitalisUI

/// One-line error under cached content, or the no-cache body with Try again (spec 20 §7).
struct TrainLoadError: View {
    let error: Error?
    let hasValue: Bool
    let retry: () -> Void

    var body: some View {
        if error != nil, !hasValue {
            VStack(alignment: .leading, spacing: VSpace.s4) {
                Text("Connect to your server to see your training.").vText(.body, color: VColor.text2)
                SecondaryButton("Try again", action: retry)
            }
            .accessibilityElement(children: .contain)
        } else if let error = error as? APIError, hasValue {
            Text(error.statusLine).vText(.secondary, color: VColor.watch)
        }
    }
}
