import Foundation

@main
struct SharedWindowManagerTests {
    static func main() {
        typealias Policy = SharedWindowManagerPolicy
        typealias Backend = SharedWindowManagerBackend
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
        }
        check(
            Policy.choose(.native, stableBarSource: "rift", running: [.rift]) == .native,
            "explicit native")
        check(
            Policy.choose(.automatic, stableBarSource: nil, running: []) == .native,
            "no manager")
        for backend in Backend.allCases {
            check(
                Policy.choose(.automatic, stableBarSource: nil, running: [backend]) == .external(backend),
                "automatic detection")
            check(
                Policy.choose(.automatic, stableBarSource: "spaces", running: [backend]) == .external(backend),
                "Spaces does not override tiler")
            check(
                Policy.choose(
                    .automatic, stableBarSource: backend.rawValue, running: Set(Backend.allCases))
                    == .external(backend),
                "StableBar choice")
            check(
                Policy.choose(
                    SharedWindowManagerSelection(rawValue: backend.rawValue)!,
                    stableBarSource: nil, running: []) == .external(backend),
                "explicit selection does not fall back")
            check(
                Policy.command(.leftHalf, for: backend) == nil,
                "no arbitrary frame writes to tiled windows")
            check(Policy.command(.closeWindow, for: backend) != nil, "close mapping")
            check(
                Policy.workspace(1, moveWindow: true, backend: backend)
                    != Policy.workspace(1, moveWindow: false, backend: backend),
                "switch versus move")
        }
        if case .unavailable = Policy.choose(.automatic, stableBarSource: nil, running: [.rift, .yabai]) {
        } else {
            fatalError("ambiguous managers")
        }
        if case .unavailable = Policy.choose(.automatic, stableBarSource: "unknown", running: []) {
        } else {
            fatalError("unknown source")
        }
        check(
            Policy.workspace(1, moveWindow: false, backend: .rift)
                == ["execute", "workspace", "switch", "0"],
            "Rift zero-based switch")
        check(
            Policy.workspace(20, moveWindow: true, backend: .rift)
                == ["execute", "workspace", "move-window", "19"],
            "Rift zero-based move")
        check(
            Policy.command(.moveLeft, for: .rift) == ["execute", "layout", "move-node", "left"],
            "Rift move")
        check(
            Policy.command(.moveRight, for: .omniwm) == ["command", "move", "right"],
            "OmniWM move")
        check(Policy.command(.moveUp, for: .kiwidesk) == ["swap", "up"], "KiwiDesk swap")
        check(
            Policy.workspace(2, moveWindow: true, backend: .aerospace)
                == ["move-node-to-workspace", "--", "2"],
            "AeroSpace legacy mapping")
        check(
            Policy.workspace(2, moveWindow: false, backend: .yabai)
                == ["-m", "space", "--focus", "2"],
            "yabai legacy mapping")
        check(Backend.rift.cliName == "rift-cli" && Backend.omniwm.cliName == "omniwmctl", "actual executable names")
        check(
            Backend.aerospace.permitsNativeFloatingGeometry && !Backend.rift.permitsNativeFloatingGeometry,
            "floating policy")
        print("Shared window manager policy: passed")
    }
}
