import SwiftUI

/// The clock shown over the preview. Drag it anywhere; its position is stored as
/// fractions of the preview size, so it keeps the same place in the saved clock video.
struct ClockOverlay: View {
    @Binding var x: Double   // centre, fraction of width
    @Binding var y: Double   // centre, fraction of height
    @Binding var quadStorage: String   // wall corners, when fitted to a wall
    var tint: Color
    var style: ClockStyle
    var warp: Bool           // fit the clock to a wall in perspective
    var wallScale: Double = 1   // size on the wall, applied on top of the stored corners
    var editable: Bool       // show the corner handles
    var surfaces: [TrackedSurface] = []   // detected flat shapes, highlighted in surface mode
    var surfaceMode = false             // highlight surfaces; the clock re-shapes to the one it's over
    var occlusionMask: CGImage? = nil   // opaque where the clock may show, clear where a person is
    /// The plane picked in surface mode (stored corners of the clicked shape); empty if none yet.
    var planeStorage: Binding<String> = .constant("")

    @State private var moveStart: ClockQuad?
    @StateObject private var gridCache = PlaneGridCache()

    /// The locked plane's corners, while picking a plane is switched on.
    private var lockedPlane: [CGPoint]? {
        surfaceMode ? ClockQuad(storage: planeStorage.wrappedValue)?.points : nil
    }

    var body: some View {
        if warp {
            warpedBody
        } else {
            uprightBody
        }
    }

    // MARK: Wall mode

    /// The clock's corners as shown: the stored corners scaled by the size setting.
    private var quad: ClockQuad {
        let stored = ClockQuad(storage: quadStorage) ?? .upright(centerX: x, centerY: y, style: style)
        return stored.scaled(wallScale)
    }

    /// Saves corners edited on screen, undoing the size scale so the slider keeps working.
    private func store(_ shown: ClockQuad) {
        quadStorage = shown.scaled(1 / wallScale).storage
        // Keep the flat-clock position in step, so switching modes doesn't make it jump.
        let centre = shown.wallCentre
        x = min(max(Double(centre.x), 0), 1)
        y = min(max(Double(centre.y), 0), 1)
    }

    /// The clock drawn upright, then mapped onto the four wall corners with a perspective transform.
    private var warpedBody: some View {
        GeometryReader { geo in
            let size = geo.size
            let corners = quad.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            let base = CGSize(width: 240 * style.canvasAspect, height: 240)

            ZStack(alignment: .topLeading) {
                if editable, let plane = lockedPlane {
                    // The plane extended across the whole view; click anywhere to put the clock there.
                    planeGrid(plane, size: size)
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            SpatialTapGesture(coordinateSpace: .named("clockArea"))
                                .onEnded { value in
                                    move(to: CGPoint(x: value.location.x / size.width, y: value.location.y / size.height),
                                         keepingHeight: quad.screenHeight())
                                }
                        )
                } else if surfaceMode && editable {
                    surfaceHighlights(size: size)
                }
                ZStack(alignment: .topLeading) {
                    uprightFace(base: base)
                        .frame(width: base.width, height: base.height)
                        .projectionEffect(Homography(unitSquareTo: corners).projection(for: base))
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .mask(alignment: .topLeading) { occlusion(size) }
                .allowsHitTesting(false)
                if editable {
                    handles(corners: corners, size: size)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .coordinateSpace(name: "clockArea")
    }

    /// The clock filling a canvas of `base` size, matching what's drawn into the video.
    @ViewBuilder
    private func uprightFace(base: CGSize) -> some View {
        switch style {
        case .analog:
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                AnalogClockFace(date: context.date, tint: tint, flatGlass: true)
                    .padding(base.height * 0.05)
            }
        case .digital:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(context.date, format: .dateTime.hour().minute().second())
                    .font(.system(size: base.height * 0.42, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: base.width, height: base.height * 0.9)
                    // Drawn like the saved video: system glass doesn't survive a perspective warp.
                    .background(Capsule().fill(tint.opacity(0.22)))
                    .overlay(Capsule().stroke(tint.opacity(0.5), lineWidth: 2))
            }
        }
    }

    /// Four corner handles to line the clock up with the wall, a centre handle to move it,
    /// and a dashed outline of the shape.
    @ViewBuilder
    private func handles(corners: [CGPoint], size: CGSize) -> some View {
        Path { path in
            path.addLines(corners)
            path.closeSubpath()
        }
        .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        .allowsHitTesting(false)

        ForEach(0..<4, id: \.self) { i in
            Circle()
                .fill(Color.white)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(Color.black.opacity(0.3), lineWidth: 1))
                .shadow(radius: 2)
                .contentShape(Circle().inset(by: -6))   // a slightly larger grab area
                .gesture(
                    DragGesture(coordinateSpace: .named("clockArea"))
                        .onChanged { value in
                            var updated = quad
                            updated.points[i] = CGPoint(x: min(max(value.location.x / size.width, 0), 1),
                                                        y: min(max(value.location.y / size.height, 0), 1))
                            store(updated)
                        }
                )
                .position(corners[i])
        }

        let centre = CGPoint(x: corners.map(\.x).reduce(0, +) / 4, y: corners.map(\.y).reduce(0, +) / 4)
        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color.black.opacity(0.45)))
            .contentShape(Circle())
            .gesture(
                DragGesture(coordinateSpace: .named("clockArea"))
                    .onChanged { value in
                        let start = moveStart ?? quad
                        if moveStart == nil { moveStart = start }
                        let target = CGPoint(x: start.wallCentre.x + value.translation.width / size.width,
                                             y: start.wallCentre.y + value.translation.height / size.height)
                        move(to: target, keepingHeight: start.screenHeight())
                    }
                    .onEnded { _ in moveStart = nil }
            )
            .position(centre)
    }

    /// Moves the clock so it's centred on `target`. In surface mode it takes the perspective of the
    /// surface it's now over; elsewhere it keeps its current shape.
    private func move(to target: CGPoint, keepingHeight height: CGFloat) {
        if let plane = lockedPlane,
           let onPlane = ClockQuad.placed(at: target, height: height, onWall: plane, aspect: style.canvasAspect) {
            store(onPlane)
            return
        }
        if surfaceMode,
           let surface = ClockQuad.surface(containing: target, in: surfaces.map(\.corners)),
           let reshaped = ClockQuad.placed(at: target, height: height, onWall: surface, aspect: style.canvasAspect) {
            store(reshaped)
            return
        }
        let current = quad
        let dx = target.x - current.wallCentre.x, dy = target.y - current.wallCentre.y
        store(ClockQuad(points: current.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }))
    }

    /// The locked plane drawn as a perspective grid across the whole view, with the picked shape outlined.
    private func planeGrid(_ plane: [CGPoint], size: CGSize) -> some View {
        let lines = gridCache.lines(for: planeStorage.wrappedValue, plane: plane)
        return Canvas { context, canvasSize in
            func screen(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * canvasSize.width, y: p.y * canvasSize.height) }
            var grid = Path()
            for segment in lines {
                grid.addLines(segment.map(screen))
            }
            context.stroke(grid, with: .color(.white.opacity(0.35)), lineWidth: 1)
            var picked = Path()
            picked.addLines(plane.map(screen))
            picked.closeSubpath()
            context.stroke(picked, with: .color(.accentColor), lineWidth: 2)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    /// Every detected surface, tinted and outlined. Click one to put the clock there.
    @ViewBuilder
    private func surfaceHighlights(size: CGSize) -> some View {
        ForEach(surfaces) { tracked in
            let surface = tracked.corners
            let outline = Path { path in
                path.addLines(surface.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) })
                path.closeSubpath()
            }
            outline
                .fill(Color.accentColor.opacity(0.18))
                .overlay(outline.stroke(Color.accentColor.opacity(0.9), lineWidth: 1.5))
                .contentShape(outline)
                .gesture(
                    SpatialTapGesture(coordinateSpace: .named("clockArea"))
                        .onEnded { value in
                            let point = CGPoint(x: value.location.x / size.width, y: value.location.y / size.height)
                            planeStorage.wrappedValue = ClockQuad(points: surface).storage
                            if let placed = ClockQuad.placed(at: point, height: quad.screenHeight(),
                                                             onWall: surface, aspect: style.canvasAspect) {
                                store(placed)
                            }
                        }
                )
                .transition(.opacity)
        }
        // Surfaces fade in and out rather than popping.
        .animation(.easeInOut(duration: 0.25), value: surfaces.map(\.id))
    }

    /// Lets the clock show everywhere except where a person is.
    @ViewBuilder
    private func occlusion(_ size: CGSize) -> some View {
        if let occlusionMask {
            Image(decorative: occlusionMask, scale: 1)
                .resizable()
                .frame(width: size.width, height: size.height)
        } else {
            Rectangle().frame(width: size.width, height: size.height)
        }
    }

    // MARK: Normal mode

    private var uprightBody: some View {
        GeometryReader { geo in
            clock(in: geo.size)
                .gesture(
                    DragGesture(coordinateSpace: .named("clockArea"))
                        .onChanged { value in
                            let margin = margins(in: geo.size)
                            let newX = min(max(value.location.x / geo.size.width, margin.x), 1 - margin.x)
                            let newY = min(max(value.location.y / geo.size.height, margin.y), 1 - margin.y)
                            // Carry any wall shape along, so switching to wall mode keeps this spot.
                            if let wallShape = ClockQuad(storage: quadStorage) {
                                let dx = newX - x, dy = newY - y
                                quadStorage = ClockQuad(points: wallShape.points.map {
                                    CGPoint(x: $0.x + dx, y: $0.y + dy)
                                }).storage
                            }
                            x = newX
                            y = newY
                        }
                )
                .position(x: x * geo.size.width, y: y * geo.size.height)
                .mask(alignment: .topLeading) { occlusion(geo.size) }
        }
        .coordinateSpace(name: "clockArea")
    }

    @ViewBuilder
    private func clock(in size: CGSize) -> some View {
        switch style {
        case .digital:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(context.date, format: .dateTime.hour().minute().second())
                    .font(.system(.title3, design: .rounded).monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassSurface(in: Capsule(), tint: tint.opacity(0.35))
                    .contentShape(Capsule())
            }
        case .analog:
            let diameter = size.height * ClockStyle.analogDiameter
            // ~30 fps so the second hand sweeps smoothly.
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                AnalogClockFace(date: context.date, tint: tint)
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
        }
    }

    /// Keeps the whole clock inside the preview while dragging.
    private func margins(in size: CGSize) -> (x: Double, y: Double) {
        switch style {
        case .digital:
            return (0.08, 0.08)
        case .analog:
            let radius = size.height * ClockStyle.analogDiameter / 2
            return (Double(radius / max(size.width, 1)) + 0.01, Double(radius / max(size.height, 1)) + 0.01)
        }
    }
}

/// A glassy analog clock with ticks and hour, minute and second hands.
struct AnalogClockFace: View {
    let date: Date
    let tint: Color
    /// Draw the face as a tinted fill (as in the saved video) instead of system glass.
    /// Used in wall mode, where system glass doesn't render correctly under a perspective warp.
    var flatGlass = false

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2
            let angles = clockHandAngles(for: date)

            ZStack {
                // Glass face and an even rim.
                if flatGlass {
                    Circle().fill(tint.opacity(0.25))
                } else {
                    Color.clear
                        .glassSurface(in: Circle(), tint: tint.opacity(0.35))
                }
                Circle()
                    .strokeBorder(Color.white.opacity(0.6), lineWidth: size * 0.02)

                // Ticks: long every 5 minutes, short in between.
                ForEach(0..<60, id: \.self) { i in
                    let major = i % 5 == 0
                    let length = size * (major ? 0.08 : 0.04)
                    Capsule()
                        .fill(Color.white.opacity(major ? 0.9 : 0.4))
                        .frame(width: size * (major ? 0.022 : 0.01), height: length)
                        .offset(y: -(radius * 0.88 - length / 2))
                        .rotationEffect(.degrees(Double(i) * 6))
                }

                hand(length: radius * 0.5, width: size * 0.045, degrees: angles.hour, color: .white)
                hand(length: radius * 0.72, width: size * 0.03, degrees: angles.minute, color: .white)
                hand(length: radius * 0.8, width: size * 0.012, degrees: angles.second, color: .orange)

                Circle().fill(Color.white).frame(width: size * 0.07, height: size * 0.07)
                Circle().fill(Color.orange).frame(width: size * 0.035, height: size * 0.035)
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.3), radius: size * 0.04, y: size * 0.02)
        }
    }

    /// A hand pivoting on the clock centre.
    private func hand(length: CGFloat, width: CGFloat, degrees: Double, color: Color) -> some View {
        Capsule()
            .fill(color)
            .frame(width: width, height: length)
            .shadow(color: .black.opacity(0.35), radius: width * 0.6, y: width * 0.3)
            .offset(y: -length / 2)
            .rotationEffect(.degrees(degrees))
    }
}


/// Remembers the grid for the current plane, so it's only worked out when the plane changes.
final class PlaneGridCache: ObservableObject {
    private var key = ""
    private var cached: [[CGPoint]] = []

    func lines(for key: String, plane: [CGPoint]) -> [[CGPoint]] {
        if key != self.key {
            self.key = key
            // Grid in true squares on the plane when its 3D angle can be recovered.
            cached = PlaneGrid.lines(on: PlaneGeometry.trueSquare(on: plane) ?? plane)
        }
        return cached
    }
}
