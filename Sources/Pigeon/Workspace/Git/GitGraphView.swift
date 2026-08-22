import AppKit
import SwiftGitX
import SwiftUI

/// One commit in the graph, plus its computed lane and the lanes its
/// parent edges run through — enough for the classic column-of-dots
/// git graph rendering.
struct GitGraphCommit: Identifiable {
    let id: OID
    let summary: String
    let author: String
    let date: Date
    let parentIDs: [OID]

    /// Visual columns: this commit's dot lane, and the lanes that
    /// continue below it (its parents, after merge-lane collapsing).
    var lane: Int = 0
    var edgeLanes: [Int] = []

    init(commit: Commit) {
        id = commit.id
        summary = commit.summary
        author = commit.author.name
        date = commit.date
        parentIDs = (try? commit.parents.map(\.id)) ?? []
    }

    /// Simple lane assignment, newest first: each open lane extends to
    /// its next commit; a commit claims its incoming lane (or the first
    /// free one), children map onto it, parents take the same lane
    /// unless branching/merging forces new/collapsed lanes. Not a full
    /// dot-graph solver — first degree of VS Code's readability.
    static func assignLanes(_ commits: [GitGraphCommit]) -> [GitGraphCommit] {
        var result = commits
        // Lane ownership: lane index -> commit id that will render next
        // in that lane. Parent ids wait for their row.
        var laneHeads: [Int: [OID]] = [:]
        var laneCount = 0

        for index in result.indices {
            let parents = result[index].parentIDs
            // Find the lane this commit arrives on: the first lane whose
            // pending head is this commit.
            var myLane: Int? = nil
            for (lane, heads) in laneHeads.sorted(by: { $0.key < $1.key }) {
                if heads.contains(result[index].id) {
                    myLane = lane
                    // Other lanes waiting on this commit collapse into it.
                    for (otherLane, otherHeads) in laneHeads
                    where otherLane != lane {
                        laneHeads[otherLane] = otherHeads.filter {
                            $0 != result[index].id
                        }
                        if laneHeads[otherLane]?.isEmpty == true {
                            laneHeads.removeValue(forKey: otherLane)
                        }
                    }
                    break
                }
            }
            if myLane == nil {
                myLane = laneCount
                laneCount += 1
            }
            result[index].lane = myLane!

            // Parents occupy lanes: first parent continues this lane,
            // others open new lanes to the right.
            var parentLanes: [Int] = []
            for (position, parent) in parents.enumerated() {
                let lane: Int
                if position == 0 {
                    lane = myLane!
                } else {
                    lane = laneCount
                    laneCount += 1
                }
                laneHeads[lane, default: []].append(parent)
                parentLanes.append(lane)
            }
            // This commit's own head is consumed.
            if var heads = laneHeads[myLane!] {
                heads.removeAll { $0 == result[index].id }
                if heads.isEmpty { laneHeads.removeValue(forKey: myLane!) }
                else { laneHeads[myLane!] = heads }
            }
            result[index].edgeLanes = parentLanes
        }
        return result
    }
}
