// Copyright © 2026 B00kerLouis. All rights reserved.
// SDK-free checks of automatic selection and unavailable-hardware fallbacks.
@main
struct HybridMOVWorkerPolicyContracts {
    static func main() {
        func check(_ requested: Int, _ recommendation: Int?, _ verified: Int,
                   _ fragments: Int, _ expected: Int, notice: String? = nil) {
            let result = HybridMOVWorkerPlan(requested: requested, recommendedLimit: recommendation,
                verifiedHardwareSessions: verified, fragmentCount: fragments,
                probeFailure: verified == 0 ? "Hardware encoder unavailable." : nil)
            precondition(result.workers == expected)
            precondition(result.target == (requested == 0 ? 2 : requested))
            if let notice { precondition(result.notice?.contains(notice) == true) }
            precondition(result.workers >= 1 && result.workers <= max(requested, 2))
        }
        // No chip/model classification: a prepared pair works even without a
        // recommended count, as on this machine's ProRes encoder.
        check(0, nil, 2, 11, 2)
        check(0, 4, 2, 3, 2)
        check(0, 2, 2, 3, 2)
        check(0, 1, 2, 3, 1, notice: "VideoToolbox")
        check(0, nil, 1, 3, 1, notice: "Falling back")
        check(0, nil, 0, 3, 1, notice: "unavailable")
        check(0, 4, 0, 3, 1, notice: "Falling back")
        check(0, 4, 2, 1, 1, notice: "one subdivision")
        check(1, 4, 0, 3, 1)
        check(2, nil, 2, 3, 2)
        check(2, 1, 1, 3, 1, notice: "VideoToolbox")
        check(2, nil, 1, 3, 1, notice: "Falling back")
        check(8, 4, 4, 11, 4, notice: "VideoToolbox")
        check(8, nil, 3, 3, 3, notice: "subdivision count")
        print("Hybrid MOV worker policy: 14 contracts passed.")
    }
}
