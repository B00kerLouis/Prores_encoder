import Foundation
import Darwin

enum EncodingProgressContext {
    @TaskLocal static var parent: ProgressBar?
}

enum EncodingPhase: String, CaseIterable {
    case analysis = "Analysis"
    case video = "Video"
    case mux = "Mux"
    case audio = "Audio"
    case metadata = "Metadata"
    case finalize = "Finalize"
}

/// A work estimate, not elapsed time. Child scopes have fixed weights so a
/// codec discovering another pass cannot change another file's contribution.
final class ProgressBar: @unchecked Sendable {
    private static let registry = NSLock()
    nonisolated(unsafe) private static var activeBar: ProgressBar?
    private static let stdoutIsTTY = isatty(STDOUT_FILENO) != 0

    static var active: ProgressBar? {
        registry.lock()
        defer { registry.unlock() }
        return activeBar
    }

    private let lock = NSLock()
    private weak var parent: ProgressBar?
    private let id = UUID()
    private let weight: Double
    private var total: Double
    private var current = 0.0
    private var anchorCurrent = 0.0
    private var anchorFraction = 0.0
    private var childUnits: [UUID: Double] = [:]
    private var phases: [EncodingPhase: ProgressBar] = [:]
    private var lastPercent = -1
    private var closed = false
    private let displays: Bool

    init(total: Int, parent: ProgressBar? = nil) {
        self.total = Double(max(total, 1))
        self.weight = Double(max(total, 1))
        self.parent = parent
        Self.registry.lock()
        displays = parent == nil && Self.activeBar == nil
        if displays { Self.activeBar = self }
        Self.registry.unlock()
        lock.lock()
        renderLocked(force: true)
        lock.unlock()
    }

    /// Configure all phases before handing this scope to concurrent workers.
    func configure(phases plan: [(EncodingPhase, Int)]) {
        for (phase, units) in plan {
            phases[phase] = ProgressBar(total: units, parent: self)
        }
    }

    func phase(_ phase: EncodingPhase) -> ProgressBar {
        phases[phase] ?? self
    }

    func completePhase(_ phase: EncodingPhase) {
        phases[phase]?.finish()
    }

    /// Rebase only the remaining work when VideoToolbox requests another pass
    /// or storage recovery starts another attempt. Completed work never retreats.
    func addUnits(_ extra: Int) {
        guard extra > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        anchorFraction = fractionLocked
        anchorCurrent = completedUnitsLocked
        total += Double(extra)
        publishLocked()
    }

    func increment(_ count: Int = 1) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        current += Double(max(count, 0))
        publishLocked()
    }

    private var completedUnitsLocked: Double {
        current + childUnits.values.reduce(0, +)
    }

    private var fractionLocked: Double {
        if closed { return anchorFraction }
        // Keep room for finalization and underestimated/VFR input lengths.
        let remaining = max(total - anchorCurrent, 1)
        return min(0.99, anchorFraction + (1 - anchorFraction)
            * max(0, completedUnitsLocked - anchorCurrent) / remaining)
    }

    /// Exposed internally for deterministic regression checks.
    var fractionCompleted: Double {
        lock.lock()
        defer { lock.unlock() }
        return fractionLocked
    }

    private func updateChild(_ id: UUID, units: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        childUnits[id] = units
        publishLocked()
    }

    private func publishLocked() {
        parent?.updateChild(id, units: weight * fractionLocked)
        renderLocked(force: false)
    }

    func log(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        if displays && Self.stdoutIsTTY && !closed {
            writeStdout("\r\u{1B}[2K")
        }
        writeStdout(message, newline: true)
        if !closed { renderLocked(force: true) }
    }

    func prepareForLog() {}

    /// Only successful completion may publish 100%, including for child jobs.
    func finish() { close(success: true) }
    func endLine() { close(success: false) }

    private func close(success: Bool) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        anchorFraction = success ? 1 : fractionLocked
        closed = true
        publishLocked()
        if displays && Self.stdoutIsTTY { writeStdout("", newline: true) }
        lock.unlock()
        Self.registry.lock()
        if Self.activeBar === self { Self.activeBar = nil }
        Self.registry.unlock()
    }

    private func renderLocked(force: Bool) {
        guard displays else { return }
        let percent = Int((fractionLocked * 100).rounded(.down))
        guard force || percent != lastPercent else { return }
        // Captured logs get actual percentage changes without ANSI redraw spam.
        if !Self.stdoutIsTTY && percent == lastPercent { return }
        lastPercent = percent
        let filled = percent * 40 / 100
        let bar = String(repeating: "█", count: filled)
            + String(repeating: "░", count: 40 - filled)
        writeStdout((Self.stdoutIsTTY ? "\r\u{1B}[2K" : "")
            + "  [\(bar)] \(percent)% overall", newline: !Self.stdoutIsTTY)
    }

    private func writeStdout(_ string: String, newline: Bool = false) {
        fputs(string, stdout)
        if newline { fputs("\n", stdout) }
        fflush(stdout)
    }
}

/// Keeps encoder logs above the active overall progress bar.
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let message = items.map { String(describing: $0) }.joined(separator: separator)
    if terminator == "\n", let bar = ProgressBar.active {
        bar.log(message)
    } else {
        Swift.print(message, terminator: terminator)
    }
}

func encodePipelineProgressPlan(
    frames: Int64,
    quality: String,
    cmuMasteringNits: Float?,
    includeGeneratedCMU: Bool,
    hasExternalDolbyVisionXML: Bool,
    exportFormat: String,
    multiPass: Bool = false
) -> [(EncodingPhase, Int)] {
    let frames = min(max(Int(clamping: frames), 1), Int.max / 16)
    let compressed = quality == "hevc" || quality == "av1"
    let mxf = exportFormat == "op1a" || exportFormat == "opatom"
    var plan: [(EncodingPhase, Int)] = [(.video, frames)]
    if multiPass && (quality == "hevc" || quality == "h264") {
        // Budget the usual two passes up front, plus draining the frame silo.
        plan.append((.mux, frames))
        plan[0].1 = frames * 2
    }
    if cmuMasteringNits != nil || (compressed && hasExternalDolbyVisionXML) {
        plan.append((.analysis, frames))
    }
    if exportFormat == "opatom" { plan.append((.audio, frames)) }
    if includeGeneratedCMU && cmuMasteringNits != nil && !compressed && !mxf {
        plan.append((.metadata, frames))
    }
    plan.append((.finalize, max(frames / 20, 1)))
    return plan
}

func encodePipelineProgressUnits(
    frames: Int64, quality: String, cmuMasteringNits: Float?,
    includeGeneratedCMU: Bool, hasExternalDolbyVisionXML: Bool,
    exportFormat: String, multiPass: Bool = false
) -> Int {
    encodePipelineProgressPlan(
        frames: frames, quality: quality, cmuMasteringNits: cmuMasteringNits,
        includeGeneratedCMU: includeGeneratedCMU,
        hasExternalDolbyVisionXML: hasExternalDolbyVisionXML,
        exportFormat: exportFormat, multiPass: multiPass
    ).reduce(0) { sum, phase in
        let result = sum.addingReportingOverflow(phase.1)
        return result.overflow ? Int.max : result.partialValue
    }
}

func makeEncodePipelineProgressBar(
    frames: Int64, quality: String, cmuMasteringNits: Float?,
    includeGeneratedCMU: Bool, hasExternalDolbyVisionXML: Bool,
    exportFormat: String, multiPass: Bool = false, parent: ProgressBar? = nil
) -> ProgressBar? {
    let plan = encodePipelineProgressPlan(
        frames: frames, quality: quality, cmuMasteringNits: cmuMasteringNits,
        includeGeneratedCMU: includeGeneratedCMU,
        hasExternalDolbyVisionXML: hasExternalDolbyVisionXML,
        exportFormat: exportFormat, multiPass: multiPass
    )
    let progress = ProgressBar(total: encodePipelineProgressUnits(
        frames: frames, quality: quality, cmuMasteringNits: cmuMasteringNits,
        includeGeneratedCMU: includeGeneratedCMU,
        hasExternalDolbyVisionXML: hasExternalDolbyVisionXML,
        exportFormat: exportFormat, multiPass: multiPass
    ), parent: parent ?? EncodingProgressContext.parent)
    progress.configure(phases: plan)
    return progress
}
