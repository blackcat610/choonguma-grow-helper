import AppKit
import Darwin

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--self-test" {
    let exitCode = SelfTestRunner.run(paths: Array(arguments.dropFirst()))
    exit(exitCode)
}

if arguments.first == "--sequence-test" {
    let exitCode = SequenceTestRunner.run(paths: Array(arguments.dropFirst()))
    exit(exitCode)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
withExtendedLifetime(delegate) {
    application.run()
}
