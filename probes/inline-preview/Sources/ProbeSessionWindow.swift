#if EPOS_SESSION_PROTOTYPE
import ApplicationServices

/// Public AX and Quartz window geometry share the main display's top-left
/// origin. Exact geometry is sufficient only when one window of this process
/// matches. Identical frames, including hidden windows, remain ambiguous.
enum ProbeSessionWindow {
    static func focusedBounds(_ element: AXUIElement, pid: pid_t) -> CGRect? {
        var actualPID: pid_t = 0
        guard AXUIElementGetPid(element, &actualPID) == .success, actualPID == pid else { return nil }
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        let position = unsafeBitCast(positionValue, to: AXValue.self)
        let size = unsafeBitCast(sizeValue, to: AXValue.self)
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetType(position) == .cgPoint, AXValueGetType(size) == .cgSize,
              AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    static func match(pid: pid_t, window: CGWindowID, focusedBounds: CGRect,
                      windows: [[String: Any]], requireOnScreen: Bool = true,
                      expectedBounds: CGRect? = nil) -> (bounds: CGRect?, gate: String, candidates: Int) {
        guard focusedBounds.origin.x.isFinite, focusedBounds.origin.y.isFinite,
              focusedBounds.width.isFinite, focusedBounds.height.isFinite,
              focusedBounds.width > 0, focusedBounds.height > 0 else {
            return (nil, "focused-frame-invalid", 0)
        }
        if let expectedBounds, focusedBounds != expectedBounds {
            return (nil, "window-frame-changed", 0)
        }
        let candidates = windows.filter { info in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                  info[kCGWindowLayer as String] as? Int == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID, id > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return rect == focusedBounds
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            return (nil, candidates.isEmpty ? "window-frame-unmatched" : "window-frame-ambiguous", candidates.count)
        }
        guard candidate[kCGWindowNumber as String] as? CGWindowID == window else {
            return (nil, "window-mismatch", 1)
        }
        guard !requireOnScreen || candidate[kCGWindowIsOnscreen as String] as? Bool == true else {
            return (nil, "window-offscreen", 1)
        }
        return (focusedBounds, "ready", 1)
    }

    /// IMK exposes the bundle but no PID/window identifier. A background test
    /// refuses when another window from that bundle could supply this caret.
    static func exclusiveCaret(_ caret: CGRect, pid: pid_t, window: CGWindowID,
                               bundlePIDs: Set<pid_t>, windows: [[String: Any]]) -> Bool {
        guard caret.origin.x.isFinite, caret.origin.y.isFinite, caret.width.isFinite, caret.height.isFinite,
              caret.width > 0, caret.height > 0 else { return false }
        let candidates = windows.filter { info in
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, bundlePIDs.contains(owner),
                  info[kCGWindowLayer as String] as? Int == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return rect.intersects(caret)
        }
        return candidates.count == 1 && candidates[0][kCGWindowOwnerPID as String] as? pid_t == pid
            && candidates[0][kCGWindowNumber as String] as? CGWindowID == window
    }
}
#endif
