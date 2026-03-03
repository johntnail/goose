#!/usr/bin/env swift
import Foundation
import CoreGraphics

enum Mode: String {
    case down
    case up
}

struct Options {
    var mode: Mode = .down
    var keyCode: CGKeyCode = 49 // space
    var timeout: TimeInterval?
    var pollMs: UInt32 = 15
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("goose-voice-ptt-keywatch: \(message)\n").utf8))
    exit(code)
}

func parseArgs() -> Options {
    var opts = Options()
    var i = 1
    let args = CommandLine.arguments

    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--mode":
            i += 1
            guard i < args.count else { fail("missing value for --mode") }
            guard let mode = Mode(rawValue: args[i]) else {
                fail("invalid --mode '\(args[i])' (expected down|up)")
            }
            opts.mode = mode
        case "--key-code":
            i += 1
            guard i < args.count else { fail("missing value for --key-code") }
            guard let value = Int(args[i]), value >= 0, value <= 255 else {
                fail("invalid --key-code '\(args[i])'")
            }
            opts.keyCode = CGKeyCode(value)
        case "--timeout":
            i += 1
            guard i < args.count else { fail("missing value for --timeout") }
            guard let value = Double(args[i]), value > 0 else {
                fail("invalid --timeout '\(args[i])'")
            }
            opts.timeout = value
        case "--poll-ms":
            i += 1
            guard i < args.count else { fail("missing value for --poll-ms") }
            guard let value = UInt32(args[i]), value > 0 else {
                fail("invalid --poll-ms '\(args[i])'")
            }
            opts.pollMs = value
        case "-h", "--help":
            print("""
Usage:
  goose-voice-ptt-keywatch.swift --mode down|up [--key-code 49] [--timeout SEC] [--poll-ms 15]

Polls macOS key state using CoreGraphics.
""")
            exit(0)
        default:
            fail("unknown argument '\(arg)'")
        }
        i += 1
    }

    return opts
}

func isKeyDown(_ keyCode: CGKeyCode) -> Bool {
    CGEventSource.keyState(.combinedSessionState, key: keyCode)
}

let opts = parseArgs()
let sleepMicros = useconds_t(opts.pollMs * 1_000)
let start = Date()

while true {
    let down = isKeyDown(opts.keyCode)
    let done: Bool

    switch opts.mode {
    case .down:
        done = down
    case .up:
        done = !down
    }

    if done {
        print(opts.mode.rawValue)
        exit(0)
    }

    if let timeout = opts.timeout, Date().timeIntervalSince(start) >= timeout {
        exit(3)
    }

    usleep(sleepMicros)
}
