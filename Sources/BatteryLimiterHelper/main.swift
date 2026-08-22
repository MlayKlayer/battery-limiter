import Foundation

// `--check` prints which SMC key set this Mac speaks and the bytes each action
// would write, and exits without writing any of them. Needs no root. This is
// the check for the key-set split: the failure it guards against is a limiter
// that silently stops limiting, which is invisible until the pack hits 100%.
if CommandLine.arguments.contains("--check") {
    print(ChargeControl.dryRun())
    exit(0)
}

let controller = ChargeController()
controller.run()
