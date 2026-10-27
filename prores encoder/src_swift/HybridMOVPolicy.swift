// Copyright © 2026 B00kerLouis. All rights reserved.

/// Worker counts describe concurrent encoding jobs, not physical media engines.
/// Hardware checks and VT's codec-specific limit take precedence over chip names.
struct HybridMOVWorkerPlan: Sendable {
    let target: Int
    let workers: Int
    let notice: String?

    init(requested: Int, recommendedLimit: Int?, verifiedHardwareSessions: Int,
         fragmentCount: Int, probeFailure: String? = nil) {
        target = requested == 0 ? 2 : requested
        if fragmentCount <= 1 {
            workers = 1
            notice = target > 1 ? "Using 1 worker: the source has only one subdivision." : nil
        } else if target == 1 {
            workers = 1
            notice = nil
        } else {
            let limit = max(1, min(recommendedLimit ?? target, verifiedHardwareSessions))
            workers = min(target, limit, fragmentCount)
            if workers < target && workers < fragmentCount {
                if let recommendedLimit, recommendedLimit < target {
                    notice = "Falling back to \(workers) worker(s): VideoToolbox reports a parallel limit of \(recommendedLimit) (requested \(target))."
                } else {
                    notice = "Falling back to \(workers) worker(s): only \(verifiedHardwareSessions) concurrent hardware session(s) could be verified.\(probeFailure.map { " " + $0 } ?? "")"
                }
            } else {
                notice = workers < target ? "Using \(workers) workers: limited by the source subdivision count." : nil
            }
        }
    }
}
