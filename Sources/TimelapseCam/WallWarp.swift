import SwiftUI
import simd

/// The clock's four corners on the wall, as fractions of the frame (top-left origin),
/// in the order top-left, top-right, bottom-right, bottom-left.
struct ClockQuad: Equatable {
    var points: [CGPoint]

    init(points: [CGPoint]) {
        self.points = points
    }

    /// Reads "x,y,x,y,x,y,x,y" as stored in settings.
    init?(storage: String) {
        let values = storage.split(separator: ",").compactMap { Double($0) }
        guard values.count == 8 else { return nil }
        points = stride(from: 0, to: 8, by: 2).map { CGPoint(x: values[$0], y: values[$0 + 1]) }
    }

    var storage: String {
        points.map { String(format: "%.4f,%.4f", $0.x, $0.y) }.joined(separator: ",")
    }

    /// The same clock made `factor` times bigger or smaller within the wall's perspective,
    /// growing from its centre on the wall (not a flat on-screen zoom).
    func scaled(_ factor: CGFloat) -> ClockQuad {
        guard factor > 0, abs(factor - 1) > 0.0001 else { return self }
        let onWall = Homography(unitSquareTo: points)
        let low = 0.5 - factor / 2, high = 0.5 + factor / 2
        return ClockQuad(points: [
            CGPoint(x: low, y: low), CGPoint(x: high, y: low),
            CGPoint(x: high, y: high), CGPoint(x: low, y: high)
        ].map(onWall.apply))
    }

    var centroid: CGPoint {
        CGPoint(x: points.map(\.x).reduce(0, +) / 4, y: points.map(\.y).reduce(0, +) / 4)
    }

    /// An unwarped quad centred on a point, the same size as the normal clock.
    static func upright(centerX: Double, centerY: Double, style: ClockStyle) -> ClockQuad {
        let height = style == .analog ? Double(ClockStyle.analogDiameter) : 0.09
        let width = height * Double(style.canvasAspect) * 9 / 16   // frame is 16:9
        return ClockQuad(points: [
            CGPoint(x: centerX - width / 2, y: centerY - height / 2),
            CGPoint(x: centerX + width / 2, y: centerY - height / 2),
            CGPoint(x: centerX + width / 2, y: centerY + height / 2),
            CGPoint(x: centerX - width / 2, y: centerY + height / 2)
        ])
    }

    /// Places a clock of the given width:height in the middle of a detected wall shape,
    /// following its perspective, so a round clock still looks round on the wall.
    /// The point the clock looks centred on (its centre on the wall, not just the average of the corners).
    var wallCentre: CGPoint {
        Homography(unitSquareTo: points).apply(CGPoint(x: 0.5, y: 0.5))
    }

    /// Average on-screen height of the left and right edges.
    func screenHeight(frameAspect: CGFloat = 16.0 / 9.0) -> CGFloat {
        (Self.length(points[0], points[3], frameAspect) + Self.length(points[1], points[2], frameAspect)) / 2
    }

    /// Distance in frame fractions, with x scaled so both axes use the same units.
    private static func length(_ a: CGPoint, _ b: CGPoint, _ frameAspect: CGFloat) -> CGFloat {
        hypot((a.x - b.x) * frameAspect, a.y - b.y)
    }

    /// The detected shape to take perspective from: the largest one the point sits inside,
    /// otherwise the one whose centre is closest.
    static func nearestWall(to point: CGPoint, in walls: [[CGPoint]]) -> [CGPoint]? {
        if let around = surface(containing: point, in: walls) { return around }
        func centre(_ q: [CGPoint]) -> CGPoint {
            CGPoint(x: q.map(\.x).reduce(0, +) / 4, y: q.map(\.y).reduce(0, +) / 4)
        }
        return walls.min {
            hypot(centre($0).x - point.x, centre($0).y - point.y) < hypot(centre($1).x - point.x, centre($1).y - point.y)
        }
    }

    /// The largest detected shape the point sits inside, if any.
    static func surface(containing point: CGPoint, in walls: [[CGPoint]]) -> [CGPoint]? {
        walls.filter { contains($0, point) }.max { area($0) < area($1) }
    }

    static func contains(_ q: [CGPoint], _ p: CGPoint) -> Bool {
        let signs = (0..<4).map { i -> CGFloat in
            let a = q[i], b = q[(i + 1) % 4]
            return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
        }
        return signs.allSatisfy { $0 >= 0 } || signs.allSatisfy { $0 <= 0 }
    }

    private static func area(_ q: [CGPoint]) -> CGFloat {
        abs((0..<4).reduce(0) { $0 + q[$1].x * q[($1 + 1) % 4].y - q[($1 + 1) % 4].x * q[$1].y }) / 2
    }

    /// A clock centred on `centre` with on-screen height `height`, lying flat on the same plane as `wall`.
    /// The clock stays where it is; only its perspective (and the matching shape) comes from the wall.
    static func placed(at centre: CGPoint, height: CGFloat, onWall wall: [CGPoint], aspect: CGFloat,
                       frameAspect: CGFloat = 16.0 / 9.0, wallAspect: CGFloat? = nil) -> ClockQuad? {
        // Work on a true square on the wall's plane when its 3D angle can be recovered,
        // so a round clock stays round wherever it's placed on that plane.
        if wallAspect == nil, let square = PlaneGeometry.trueSquare(on: wall, frameAspect: frameAspect) {
            return placed(at: centre, height: height, onWall: square, aspect: aspect,
                          frameAspect: frameAspect, wallAspect: 1)
        }

        let toWall = Homography(unitSquareTo: wall)
        guard let onWall = toWall.invert(centre) else { return nil }

        // The wall shape's real width:height. Known for a true square; otherwise a rough guess from the screen.
        let wallWidth = (length(wall[0], wall[1], frameAspect) + length(wall[3], wall[2], frameAspect)) / 2
        let wallHeight = (length(wall[0], wall[3], frameAspect) + length(wall[1], wall[2], frameAspect)) / 2
        guard wallWidth > 0, wallHeight > 0, height > 0 else { return nil }
        let realAspect = wallAspect ?? wallWidth / wallHeight

        func clock(_ dv: CGFloat) -> ClockQuad {
            let du = dv * aspect / realAspect
            return ClockQuad(points: [
                CGPoint(x: onWall.x - du / 2, y: onWall.y - dv / 2),
                CGPoint(x: onWall.x + du / 2, y: onWall.y - dv / 2),
                CGPoint(x: onWall.x + du / 2, y: onWall.y + dv / 2),
                CGPoint(x: onWall.x - du / 2, y: onWall.y + dv / 2)
            ].map(toWall.apply))
        }

        // Size it so its on-screen height matches the clock's current height (perspective makes
        // this slightly non-linear, so refine a few times).
        var dv = height / wallHeight
        for _ in 0..<5 {
            let current = clock(dv).screenHeight(frameAspect: frameAspect)
            guard current > 0, current.isFinite else { return nil }
            dv *= height / current
        }
        let result = clock(dv)
        guard result.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        return result
    }
}

/// Perspective (projective) map from the unit square onto a quadrilateral.
/// Corner order: (0,0)→q[0], (1,0)→q[1], (1,1)→q[2], (0,1)→q[3].
struct Homography {
    private var a, b, c, d, e, f, g, h: CGFloat

    init(unitSquareTo q: [CGPoint]) {
        let (x0, y0, x1, y1) = (q[0].x, q[0].y, q[1].x, q[1].y)
        let (x2, y2, x3, y3) = (q[2].x, q[2].y, q[3].x, q[3].y)
        let dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3
        let dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3
        let den = dx1 * dy2 - dx2 * dy1
        if abs(den) < 1e-12 {
            g = 0; h = 0
        } else {
            g = (dx3 * dy2 - dx2 * dy3) / den
            h = (dx1 * dy3 - dx3 * dy1) / den
        }
        a = x1 - x0 + g * x1
        b = x3 - x0 + h * x3
        c = x0
        d = y1 - y0 + g * y1
        e = y3 - y0 + h * y3
        f = y0
    }

    func apply(_ p: CGPoint) -> CGPoint {
        let w = g * p.x + h * p.y + 1
        return CGPoint(x: (a * p.x + b * p.y + c) / w, y: (d * p.x + e * p.y + f) / w)
    }

    /// The projective weight at a plane point. Its sign says which side of the horizon the point is on.
    func weight(_ p: CGPoint) -> CGFloat {
        g * p.x + h * p.y + 1
    }

    /// The unit-square point that maps to `q` (the reverse of `apply`), or nil if there isn't one.
    func invert(_ q: CGPoint) -> CGPoint? {
        // From X(gu + hv + 1) = au + bv + c and the same for Y: a 2×2 linear system in u, v.
        let m11 = a - g * q.x, m12 = b - h * q.x, r1 = q.x - c
        let m21 = d - g * q.y, m22 = e - h * q.y, r2 = q.y - f
        let det = m11 * m22 - m12 * m21
        guard abs(det) > 1e-12 else { return nil }
        return CGPoint(x: (r1 * m22 - m12 * r2) / det, y: (m11 * r2 - r1 * m21) / det)
    }

    /// SwiftUI transform that maps a view of `size` (top-left at 0,0) onto the quadrilateral.
    func projection(for size: CGSize) -> ProjectionTransform {
        var t = ProjectionTransform()
        t.m11 = a / size.width;  t.m12 = d / size.width;  t.m13 = g / size.width
        t.m21 = b / size.height; t.m22 = e / size.height; t.m23 = h / size.height
        t.m31 = c;               t.m32 = f;               t.m33 = 1
        return t
    }
}

/// Grid lines of a plane extended across the whole frame, in perspective.
enum PlaneGrid {
    /// Line segments (in frame fractions, top-left origin) for a grid on the plane through `plane`'s corners.
    /// `step` is the grid spacing as a fraction of the picked shape, so the shape itself is 1 / step cells across.
    /// Lines stop at the plane's horizon, where they would otherwise flip over.
    static func lines(on plane: [CGPoint], step: CGFloat = 0.25, maxLinesPerAxis: Int = 60) -> [[CGPoint]] {
        guard plane.count == 4 else { return [] }
        let toScreen = Homography(unitSquareTo: plane)
        let visibleSide = toScreen.weight(CGPoint(x: 0.5, y: 0.5)) > 0

        // A plane point is drawable if it's on the same side of the horizon as the picked shape.
        func drawable(_ p: CGPoint) -> Bool {
            let w = toScreen.weight(p)
            return (w > 0) == visibleSide && abs(w) > 0.02
        }

        // Which part of the plane the frame shows: map the frame's edge points back onto the plane.
        var us: [CGFloat] = [], vs: [CGFloat] = []
        var horizonOnScreen = false
        for i in 0...8 {
            let t = CGFloat(i) / 8
            for edgePoint in [CGPoint(x: t, y: 0), CGPoint(x: t, y: 1), CGPoint(x: 0, y: t), CGPoint(x: 1, y: t)] {
                if let p = toScreen.invert(edgePoint), drawable(p) {
                    us.append(p.x); vs.append(p.y)
                } else {
                    horizonOnScreen = true
                }
            }
        }
        guard let uMin = us.min(), let uMax = us.max(), let vMin = vs.min(), let vMax = vs.max() else { return [] }
        // With the horizon in view the plane runs off to infinity, so reach further towards it.
        let reach: CGFloat = horizonOnScreen ? 20 : 0
        let maxSpan = CGFloat(maxLinesPerAxis) * step / 2
        func clamp(_ low: CGFloat, _ high: CGFloat) -> (CGFloat, CGFloat) {
            (max(low - reach, 0.5 - maxSpan), min(high + reach, 0.5 + maxSpan))
        }
        let (u0, u1) = clamp(uMin, uMax)
        let (v0, v1) = clamp(vMin, vMax)

        // Each grid line is straight on screen, so sample it and keep the drawable, on-screen-ish runs.
        func line(from start: CGPoint, to end: CGPoint) -> [[CGPoint]] {
            var runs: [[CGPoint]] = [], current: [CGPoint] = []
            let samples = 80
            for i in 0...samples {
                let t = CGFloat(i) / CGFloat(samples)
                let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                let s = toScreen.apply(p)
                if drawable(p), s.x > -1, s.x < 2, s.y > -1, s.y < 2 {
                    current.append(s)
                } else if current.count > 1 {
                    runs.append(current); current = []
                } else {
                    current = []
                }
            }
            if current.count > 1 { runs.append(current) }
            return runs
        }

        var segments: [[CGPoint]] = []
        var k = (u0 / step).rounded(.up)
        while k * step <= u1 {
            segments += line(from: CGPoint(x: k * step, y: v0), to: CGPoint(x: k * step, y: v1))
            k += 1
        }
        k = (v0 / step).rounded(.up)
        while k * step <= v1 {
            segments += line(from: CGPoint(x: u0, y: k * step), to: CGPoint(x: u1, y: k * step))
            k += 1
        }
        return segments
    }
}


/// Recovers a plane's real 3D angle from a rectangle seen on it, using a pinhole camera model.
enum PlaneGeometry {
    /// Assumed horizontal field of view of the camera. MacBook cameras are roughly 65-80°.
    static let fieldOfView: CGFloat = 70

    /// The on-screen corners of a real square lying on the same plane as `rectangle` (a rectangle in the
    /// real world, seen in perspective), sharing its top-left corner and top edge direction, with sides as
    /// long as the rectangle is tall. Corners are frame fractions, top-left origin: TL, TR, BR, BL.
    /// Returns nil if the shape doesn't give a usable plane.
    static func trueSquare(on rectangle: [CGPoint], frameAspect: CGFloat = 16.0 / 9.0) -> [CGPoint]? {
        guard rectangle.count == 4 else { return nil }
        let focal = (frameAspect / 2) / tan(fieldOfView / 2 * .pi / 180)

        // Camera space: x right, y down, image height 1, principal point at the centre.
        func homogeneous(_ p: CGPoint) -> SIMD3<Double> {
            SIMD3(Double((p.x - 0.5) * frameAspect), Double(p.y - 0.5), 1)
        }
        let corners = rectangle.map(homogeneous)
        let (tl, tr, br, bl) = (corners[0], corners[1], corners[2], corners[3])

        // Vanishing points of the two pairs of opposite edges (may be at infinity: z = 0).
        let horizontal = simd_cross(simd_cross(tl, tr), simd_cross(bl, br))
        let vertical = simd_cross(simd_cross(tl, bl), simd_cross(tr, br))
        // Their 3D directions: K⁻¹ · v.
        let f = Double(focal)
        func direction(_ v: SIMD3<Double>) -> SIMD3<Double> { SIMD3(v.x / f, v.y / f, v.z) }
        var normal = simd_cross(direction(horizontal), direction(vertical))
        guard simd_length(normal) > 1e-9 else { return nil }
        normal = simd_normalize(normal)

        // Back-project a screen point onto the plane n·X = 1.
        func ray(_ p: SIMD3<Double>) -> SIMD3<Double> { SIMD3(p.x, p.y, f) }
        if simd_dot(normal, ray(tl)) < 0 { normal = -normal }
        func onPlane(_ p: SIMD3<Double>) -> SIMD3<Double>? {
            let r = ray(p), along = simd_dot(normal, r)
            guard along > 1e-9 else { return nil }
            return r / along
        }
        guard let topLeft = onPlane(tl), let topRight = onPlane(tr), let bottomLeft = onPlane(bl) else { return nil }

        // Real axes of the rectangle on the plane, made exactly perpendicular.
        var across = topRight - topLeft
        var down = bottomLeft - topLeft
        let side = simd_length(down)
        guard simd_length(across) > 1e-9, side > 1e-9 else { return nil }
        across = simd_normalize(across)
        down = simd_normalize(down - simd_dot(down, across) * across)

        // Project the square back to the screen.
        func screen(_ X: SIMD3<Double>) -> CGPoint? {
            guard X.z > 1e-9 else { return nil }
            let x = X.x / X.z * f, y = X.y / X.z * f
            return CGPoint(x: CGFloat(x) / frameAspect + 0.5, y: CGFloat(y) + 0.5)
        }
        let square = [topLeft, topLeft + side * across, topLeft + side * across + side * down, topLeft + side * down]
        let projected = square.compactMap(screen)
        guard projected.count == 4, projected.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        return projected
    }
}
