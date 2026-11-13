import CoreGraphics

/// A detected flat shape that keeps the same identity from scan to scan.
struct TrackedSurface: Identifiable, Equatable {
    let id: Int
    let corners: [CGPoint]   // fractions of the frame, top-left origin: TL, TR, BR, BL
}

/// Follows detected surfaces over time so the highlights don't jump or flicker.
/// Each scan's shapes are matched to the ones already being tracked; matched corners are eased
/// towards the new reading, a shape survives a few missed scans, and a new shape must be seen
/// twice before it's shown (which filters out one-off false detections).
final class SurfaceTracker {
    /// How far (average corner distance, in frame fractions) a detection may be from a tracked shape to match it.
    var matchDistance: CGFloat = 0.06
    /// How much each new reading moves the corners (0 = never, 1 = jump straight there).
    var smoothing: CGFloat = 0.35
    /// Scans a confirmed shape may go undetected before it's dropped (about 2 s at 3 scans a second).
    var allowedMisses = 6
    /// Scans a new shape must be seen in before it's shown.
    var confirmations = 2

    private struct Track {
        let id: Int
        var corners: [CGPoint]
        var hits: Int
        var misses: Int
    }

    private var tracks: [Track] = []
    private var nextID = 0

    func reset() {
        tracks = []
    }

    /// Feeds one scan's detections; returns the surfaces to show.
    func update(with detections: [[CGPoint]]) -> [TrackedSurface] {
        var unmatched = Array(detections.indices)

        // Match each tracked shape to its closest new detection (closest pairs first).
        var pairs: [(track: Int, detection: Int, distance: CGFloat)] = []
        for t in tracks.indices {
            for d in detections.indices {
                pairs.append((t, d, Self.distance(tracks[t].corners, detections[d])))
            }
        }
        pairs.sort { $0.distance < $1.distance }
        var matchedTracks = Set<Int>()
        for pair in pairs where pair.distance < matchDistance
            && !matchedTracks.contains(pair.track) && unmatched.contains(pair.detection) {
            matchedTracks.insert(pair.track)
            unmatched.removeAll { $0 == pair.detection }
            tracks[pair.track].corners = zip(tracks[pair.track].corners, detections[pair.detection]).map {
                CGPoint(x: $0.x + ($1.x - $0.x) * smoothing, y: $0.y + ($1.y - $0.y) * smoothing)
            }
            tracks[pair.track].hits += 1
            tracks[pair.track].misses = 0
        }

        // Shapes not seen this time count a miss, and are dropped after too many.
        for t in tracks.indices where !matchedTracks.contains(t) {
            tracks[t].misses += 1
        }
        // Unconfirmed shapes get no second chance, so stray one-off detections can't add up into a false shape.
        tracks.removeAll { $0.misses > ($0.hits >= confirmations ? allowedMisses : 0) }

        // Anything left over is a new shape.
        for d in unmatched {
            tracks.append(Track(id: nextID, corners: detections[d], hits: 1, misses: 0))
            nextID += 1
        }

        return tracks
            .filter { $0.hits >= confirmations }
            .map { TrackedSurface(id: $0.id, corners: $0.corners) }
    }

    /// Average distance between corresponding corners.
    private static func distance(_ a: [CGPoint], _ b: [CGPoint]) -> CGFloat {
        guard a.count == 4, b.count == 4 else { return .infinity }
        return zip(a, b).map { hypot($0.x - $1.x, $0.y - $1.y) }.reduce(0, +) / 4
    }
}
