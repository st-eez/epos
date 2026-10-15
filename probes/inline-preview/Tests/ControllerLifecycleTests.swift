import Foundation

@main
enum ControllerLifecycleTests {
    static func main() {
        precondition(EposProbeInputController.cachedReadbackStatesForTesting(["\n", "E", "\n"])
                     == [.unreadable, .owned, .foreign],
                     "a composition retained its cached-text allowance after owned readback")
        for graceful in [true, false] {
            let connection: UInt64 = graceful ? 41 : 42
            EposProbeInputController.stageUnreachableCompositionForTesting(connection: connection)
            precondition(EposProbeInputController.status().contains("owner=test.host"))
            // A stale peer cannot relinquish the current peer's composition.
            EposProbeInputController.releaseConnection(connection + 1, reason: "stale peer")
            precondition(EposProbeInputController.status().contains("owner=test.host"))
            if graceful {
                precondition(EposProbeInputController.end(connection: connection).hasPrefix("ok"))
            } else {
                EposProbeInputController.releaseConnection(connection, reason: "peer disconnected")
            }
            precondition(EposProbeInputController.status().contains("owner=- markedUTF16=0"),
                         "abandoned composition would block acquisition in another app")
            precondition(EposProbeInputController.status().contains("locked=-"))
        }
        print("controller lifecycle: abandoned compositions released without host writes")
    }
}
