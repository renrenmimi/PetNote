#if DEBUG
import SwiftUI
import UIKit

/// Diagnosis only, on `wip/navbar-hit-diagnosis`; never in a candidate.
///
/// Asks the app itself what answers at given window points, both ways:
/// `accessibilityHitTest` — what XCUITest's `isHittable` and VoiceOver's
/// touch exploration go by — and `hitTest` — where a finger's touch goes.
/// Points come from `-petnote-hit-probe "x,y;x,y"`. Tapping the probe takes
/// a reading and publishes it as the probe's accessibility value.
struct HitTestProbe: View {
    @State private var reading = "none"

    private static var points: [CGPoint]? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-petnote-hit-probe"),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1].split(separator: ";").compactMap { pair in
            let xy = pair.split(separator: ",").compactMap { Double($0) }
            return xy.count == 2 ? CGPoint(x: xy[0], y: xy[1]) : nil
        }
    }

    var body: some View {
        if let points = Self.points {
            Button("hit") { reading = Self.read(points) }
                .font(.caption2)
                .frame(width: 44, height: 44)
                .opacity(0.02)
                .accessibilityIdentifier("diag.hitProbe")
                .accessibilityValue(reading)
        }
    }

    private static func read(_ points: [CGPoint]) -> String {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        else { return "no key window" }
        return points.map { point in
            let ax = accessibilityHit(window, point)
            let view = window.hitTest(point, with: nil)
            return "@\(Int(point.x)),\(Int(point.y)) AX=[\(describe(ax))] VIEW=[\(chain(view))]"
        }.joined(separator: " || ")
    }

    /// UIKit's accessibility hit test, looked up at run time: it is not in
    /// the public headers on iOS, and the accessibility runtime XCUITest turns
    /// on provides it. Says so rather than guessing when it is not there.
    private static func accessibilityHit(_ window: UIWindow, _ point: CGPoint) -> Any? {
        typealias HitTest = @convention(c) (AnyObject, Selector, CGPoint, UIEvent?) -> Unmanaged<AnyObject>?
        for name in ["accessibilityHitTest:withEvent:", "_accessibilityHitTest:withEvent:"] {
            let selector = NSSelectorFromString(name)
            guard window.responds(to: selector) else { continue }
            let function = unsafeBitCast(window.method(for: selector), to: HitTest.self)
            return function(window, selector, point, nil)?.takeUnretainedValue() ?? "nil via \(name)"
        }
        return "no accessibility hit test available"
    }

    private static func describe(_ object: Any?) -> String {
        guard let object else { return "nil" }
        var parts = [String(describing: type(of: object))]
        if let o = object as? NSObject {
            if let id = (o as? UIAccessibilityIdentification)?.accessibilityIdentifier, !id.isEmpty {
                parts.append("id=\(id)")
            }
            if let label = o.accessibilityLabel, !label.isEmpty { parts.append("label=\(label)") }
            parts.append("frame=\(o.accessibilityFrame)")
            parts.append("traits=\(o.accessibilityTraits.rawValue)")
            parts.append("isElement=\(o.isAccessibilityElement)")
        }
        if let view = object as? UIView { parts.append("in=\(chain(view.superview))") }
        return parts.joined(separator: " ")
    }

    /// The view and five of its ancestors, innermost first.
    private static func chain(_ view: UIView?) -> String {
        var names: [String] = []
        var current = view
        while let v = current, names.count < 6 {
            var name = String(describing: type(of: v))
            if let id = v.accessibilityIdentifier, !id.isEmpty { name += "#\(id)" }
            name += "\(v.frame.integral)"
            names.append(name)
            current = v.superview
        }
        return names.isEmpty ? "nil" : names.joined(separator: " < ")
    }
}
#endif
