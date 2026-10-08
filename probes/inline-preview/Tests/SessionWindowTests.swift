import ApplicationServices

@main
enum SessionWindowTests {
    private static let pid: pid_t = 42
    private static let window: CGWindowID = 15305
    private static let frame = CGRect(x: 10, y: 35, width: 2540, height: 1035)

    private static func candidate(id: CGWindowID = window, owner: pid_t = pid, bounds: CGRect = frame,
                                  layer: Int = 0, onScreen: Bool = true) -> [String: Any] {
        [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: owner,
         kCGWindowBounds as String: bounds.dictionaryRepresentation, kCGWindowLayer as String: layer,
         kCGWindowIsOnscreen as String: onScreen]
    }

    static func main() {
        let own = candidate()
        let unique = ProbeSessionWindow.match(pid: pid, window: window, focusedBounds: frame, windows: [own])
        precondition(unique.bounds == frame && unique.gate == "ready" && unique.candidates == 1)

        let unrelated = [own, candidate(id: window + 1, owner: pid + 1), candidate(id: window + 2, layer: 3)]
        precondition(ProbeSessionWindow.match(pid: pid, window: window, focusedBounds: frame,
                                             windows: unrelated).bounds == frame)

        for hidden in [false, true] {
            let overlap = candidate(id: window + 1, onScreen: !hidden)
            let ambiguous = ProbeSessionWindow.match(pid: pid, window: window, focusedBounds: frame, windows: [own, overlap])
            precondition(ambiguous.bounds == nil && ambiguous.gate == "window-frame-ambiguous" && ambiguous.candidates == 2,
                         "window order or visibility resolved identical frames")
        }

        let wrongID = ProbeSessionWindow.match(pid: pid, window: window + 1, focusedBounds: frame, windows: [own])
        precondition(wrongID.bounds == nil && wrongID.gate == "window-mismatch")
        let moved = ProbeSessionWindow.match(pid: pid, window: window,
                                            focusedBounds: frame.offsetBy(dx: 1, dy: 0), windows: [own])
        precondition(moved.bounds == nil && moved.gate == "window-frame-unmatched")
        let hidden = ProbeSessionWindow.match(pid: pid, window: window, focusedBounds: frame, windows: [candidate(onScreen: false)])
        precondition(hidden.bounds == nil && hidden.gate == "window-offscreen")

        let secondary = CGRect(x: -2000, y: -100, width: 1600, height: 900)
        precondition(ProbeSessionWindow.match(pid: pid, window: window, focusedBounds: secondary,
                                             windows: [candidate(bounds: secondary)]).bounds == secondary)
        for invalid in [CGRect.zero, CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1),
                        CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 1)] {
            let match = ProbeSessionWindow.match(pid: pid, window: window, focusedBounds: invalid, windows: [own])
            precondition(match.bounds == nil && match.gate == "focused-frame-invalid")
        }
        for key in [kCGWindowNumber as String, kCGWindowOwnerPID as String, kCGWindowLayer as String, kCGWindowBounds as String] {
            var malformed = own
            malformed.removeValue(forKey: key)
            precondition(ProbeSessionWindow.match(pid: pid, window: window, focusedBounds: frame, windows: [malformed]).bounds == nil)
        }
        print("Session window matching checks passed")
    }
}
