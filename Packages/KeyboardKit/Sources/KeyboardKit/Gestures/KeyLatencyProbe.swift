//
//  KeyLatencyProbe.swift
//  KeyboardKit
//
//  Lyklaborð fork: main-thread timing for the key press/release path, the
//  one layer no bench covers (touch → SwiftUI gesture callback → handler →
//  runloop free). Timings only: no key values, text or identifiers.
//

import Foundation
import os

/// Aggregates per-keystroke timings and logs a percentile summary every
/// `flushEvery` presses. Main thread only. Disabled by default; a disabled
/// probe costs one static bool read per call.
public enum KeyLatencyProbe {

    public static var isEnabled = false
    public static var flushEvery = 40

    private static let logger = Logger(
        subsystem: "is.solberg.lyklabord",
        category: "KeyLatency"
    )
    private static var samples: [String: [Double]] = [:]
    private static var presses = 0

    public static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static var observer: CFRunLoopObserver?
    private static var passStart: TimeInterval = 0
    private static var passCPUStart: TimeInterval = 0
    private static var counts: [String: Int] = [:]

    /// Receives each flushed summary as one JSON line (set by the
    /// extension to append to a file the developer can pull off a device).
    public static var sink: ((String) -> Void)?

    /// CPU time consumed by the calling thread, in seconds. Unlike wall
    /// time this excludes waiting on the render server for vsync.
    private static var threadCPU: TimeInterval {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1e9
    }

    /// Enable the probe and time every main run-loop pass (wake → sleep).
    /// A pass covers event handling plus the SwiftUI update and commit it
    /// triggers. `runloop.wall` is how long a queued touch waits behind a
    /// pass; `runloop.cpu` is the main-thread work in it. Passes under
    /// 0.5 ms of CPU are not recorded.
    public static func start() {
        isEnabled = true
        guard observer == nil else { return }
        let activities: CFRunLoopActivity = [.afterWaiting, .beforeWaiting]
        let obs = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, 0) { _, activity in
            if activity == .afterWaiting {
                passStart = now
                passCPUStart = threadCPU
            } else if passStart > 0 {
                let wall = (now - passStart) * 1000
                let cpu = (threadCPU - passCPUStart) * 1000
                passStart = 0
                if cpu >= 0.5 {
                    record("runloop.wall", ms: wall)
                    record("runloop.cpu", ms: cpu)
                }
            }
        }
        observer = obs
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
    }

    /// Disable the probe and drop anything collected.
    public static func stop() {
        guard isEnabled else { return }
        isEnabled = false
        samples.removeAll()
        counts.removeAll()
        presses = 0
    }

    /// Count one occurrence (view body evaluations and the like).
    public static func count(_ name: String) {
        guard isEnabled else { return }
        counts[name, default: 0] += 1
    }

    /// Record one sample, in milliseconds.
    public static func record(_ metric: String, ms: Double) {
        guard isEnabled else { return }
        samples[metric, default: []].append(ms)
    }

    /// Time a synchronous block.
    @discardableResult
    public static func measure<T>(_ metric: String, _ body: () -> T) -> T {
        guard isEnabled else { return body() }
        let start = now
        defer { record(metric, ms: (now - start) * 1000) }
        return body()
    }

    /// Count one press; flushes the summary every `flushEvery` presses.
    public static func notePress() {
        guard isEnabled else { return }
        presses += 1
        if presses >= flushEvery { flush() }
    }

    public static func flush() {
        guard isEnabled, !samples.isEmpty else { return }
        var fields: [String] = ["\"presses\":\(presses)"]
        for metric in samples.keys.sorted() {
            let values = (samples[metric] ?? []).sorted()
            guard let max = values.last else { continue }
            let p50 = values[values.count / 2]
            let p95 = values[min(values.count - 1, Int(Double(values.count) * 0.95))]
            let sum = values.reduce(0, +)
            logger.notice(
                "\(metric, privacy: .public) n=\(values.count, privacy: .public) p50=\(p50, format: .fixed(precision: 2), privacy: .public) p95=\(p95, format: .fixed(precision: 2), privacy: .public) max=\(max, format: .fixed(precision: 2), privacy: .public) sum=\(sum, format: .fixed(precision: 1), privacy: .public) ms"
            )
            fields.append(String(
                format: "\"%@\":{\"n\":%d,\"p50\":%.2f,\"p95\":%.2f,\"max\":%.2f,\"sum\":%.1f}",
                metric, values.count, p50, p95, max, sum))
        }
        for name in counts.keys.sorted() {
            let value = counts[name] ?? 0
            logger.notice("\(name, privacy: .public) count=\(value, privacy: .public)")
            fields.append("\"\(name)\":\(value)")
        }
        sink?("{" + fields.joined(separator: ",") + "}")
        samples.removeAll(keepingCapacity: true)
        counts.removeAll(keepingCapacity: true)
        presses = 0
    }
}
