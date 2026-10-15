// Mac harness: `swift run -c release labkit-physcheck [core|mpm|all]` (no simulator, no Metal).
import Foundation
import LabKitCore

var pc = PhysCheck()
let args = Array(CommandLine.arguments.dropFirst())
let suite = args.first ?? "all"
if suite == "all" || suite == "core" { runCoreChecks(&pc) }
if suite == "all" || suite == "mpm" { runMPMChecks(&pc, arguments: Array(args.dropFirst())) }
pc.finish()
