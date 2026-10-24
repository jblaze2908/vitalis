import SwiftUI
import VitalisKit
import VitalisUI

extension WidgetModel {
    var tint: VTint { VTint(rawValue: tone.rawValue) ?? .steel }
}

extension PulseLine {
    /// The server's window and now from the snapshot; a flat line at the start when there is none.
    init(_ pulse: Pulse?, style: Style) {
        guard let p = pulse, let pos = PulseLine.positions(windowStart: p.window.start, windowEnd: p.window.end,
                                                            now: p.now, events: p.events.map(\.at)) else {
            self.init(now: 0, style: style); return
        }
        self.init(events: pos.events, now: pos.now, style: style)
    }
}
