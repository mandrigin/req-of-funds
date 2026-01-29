import SwiftUI
import WardleyModel
import WardleyTheme

/// Draws components (circles with labels), anchors, and evolved components.
public struct ComponentDrawing {
    // CRT glitch brand colors
    private static let alertColor = Color(red: 1.0, green: 0.267, blue: 0.0)       // #FF4400
    private static let signalColor = Color(red: 0.0, green: 1.0, blue: 0.533)      // #00FF88
    private static let cyanColor = Color(red: 0.0, green: 0.8, blue: 1.0)          // #00CCFF

    /// Snap curve: cubic-bezier(0.12, 0.8, 0.32, 1) approximation
    private static func snapCurve(_ t: Double) -> Double {
        let t2 = t * t
        let t3 = t2 * t
        return 3.0 * (1.0 - t) * (1.0 - t) * t * 0.8 + 3.0 * (1.0 - t) * t2 * 1.0 + t3
    }

    public static func drawElements(
        context: inout GraphicsContext,
        elements: [MapElement],
        theme: MapTheme,
        calc: PositionCalculator,
        highlightedLine: Int? = nil,
        glitchProgress: [String: GlitchInfo] = [:],
        positionOverrides: [String: CGPoint] = [:]
    ) {
        for element in elements {
            let pt = positionOverrides[element.name] ?? calc.point(visibility: element.visibility, maturity: element.maturity)
            let isDragging = positionOverrides[element.name] != nil
            let isHighlighted = highlightedLine == element.line
            let isEvolved = element.evolved
            let strokeColor = isEvolved ? theme.component.evolved : theme.component.stroke
            let fillColor = isEvolved ? theme.component.evolvedFill : theme.component.fill
            let textColor = isEvolved ? theme.component.evolvedTextColor : theme.component.textColor
            let r = theme.component.radius

            if isDragging {
                // === DRAG EFFECT: enlarged, semi-transparent, chromatic aberration ===
                let dragR = r * 1.5

                // Chromatic aberration ghosts (fixed offset, CRT style)
                let aberration: CGFloat = 3.0
                let rightPt = CGPoint(x: pt.x + aberration, y: pt.y - 1)
                let rightRect = CGRect(x: rightPt.x - dragR, y: rightPt.y - dragR, width: dragR * 2, height: dragR * 2)
                context.fill(Path(ellipseIn: rightRect), with: .color(alertColor.opacity(0.35)))

                let leftPt = CGPoint(x: pt.x - aberration, y: pt.y + 1)
                let leftRect = CGRect(x: leftPt.x - dragR, y: leftPt.y - dragR, width: dragR * 2, height: dragR * 2)
                context.fill(Path(ellipseIn: leftRect), with: .color(cyanColor.opacity(0.35)))

                // Main dot — semi-transparent, enlarged
                let rect = CGRect(x: pt.x - dragR, y: pt.y - dragR, width: dragR * 2, height: dragR * 2)
                context.fill(Path(ellipseIn: rect), with: .color(fillColor.opacity(0.55)))
                context.stroke(
                    Path(ellipseIn: rect),
                    with: .color(strokeColor.opacity(0.7)),
                    style: StrokeStyle(lineWidth: theme.component.strokeWidth + 1)
                )

                // Hard shadow slab (brand accent, offset)
                let shadowRect = CGRect(
                    x: pt.x - dragR + 4, y: pt.y - dragR + 4,
                    width: dragR * 2, height: dragR * 2
                )
                context.fill(Path(roundedRect: shadowRect, cornerRadius: 0), with: .color(signalColor.opacity(0.18)))

                // Label with slight jitter
                let jitterX: Double = (element.name.hashValue % 3 == 0) ? 1.5 : -1.5
                let labelPt = CGPoint(
                    x: pt.x + element.label.x + jitterX,
                    y: pt.y + element.label.y
                )
                context.draw(
                    Text(element.name)
                        .font(.system(size: theme.component.fontSize, weight: theme.component.fontWeight))
                        .foregroundStyle(textColor.opacity(0.6)),
                    at: labelPt,
                    anchor: .topLeading
                )

                // Inertia marker
                if element.inertia {
                    var inertiaPath = Path()
                    inertiaPath.move(to: CGPoint(x: pt.x + dragR + 2, y: pt.y - 10))
                    inertiaPath.addLine(to: CGPoint(x: pt.x + dragR + 2, y: pt.y + 10))
                    context.stroke(
                        inertiaPath,
                        with: .color(strokeColor.opacity(0.5)),
                        style: StrokeStyle(lineWidth: 2)
                    )
                }

            } else if let glitch = glitchProgress[element.name], glitch.progress < 1.0 {
                // === CRT GLITCH EFFECT ===
                let p = glitch.progress
                let primaryColor = glitch.isNew ? signalColor : alertColor

                if p < 0.2 {
                    // --- TEAR PHASE (0.0–0.2) ---
                    let tearProgress = p / 0.2
                    let aberration = 3.0 * (1.0 - tearProgress)

                    // Right-shifted ghost in primary color
                    let rightPt = CGPoint(x: pt.x + aberration, y: pt.y)
                    let rightRect = CGRect(x: rightPt.x - r, y: rightPt.y - r, width: r * 2, height: r * 2)
                    context.fill(Path(ellipseIn: rightRect), with: .color(primaryColor.opacity(0.6)))

                    // Left-shifted ghost in cyan
                    let leftPt = CGPoint(x: pt.x - aberration, y: pt.y)
                    let leftRect = CGRect(x: leftPt.x - r, y: leftPt.y - r, width: r * 2, height: r * 2)
                    context.fill(Path(ellipseIn: leftRect), with: .color(cyanColor.opacity(0.6)))

                    // Original dot at reduced opacity
                    let rect = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(fillColor.opacity(0.3)))
                    context.stroke(
                        Path(ellipseIn: rect),
                        with: .color(strokeColor.opacity(0.3)),
                        style: StrokeStyle(lineWidth: theme.component.strokeWidth)
                    )

                    // Label with horizontal jitter
                    let jitterDirection: Double = element.name.hashValue % 2 == 0 ? 1.0 : -1.0
                    let jitter = 2.0 * (1.0 - tearProgress) * jitterDirection
                    let labelPt = CGPoint(
                        x: pt.x + element.label.x + jitter,
                        y: pt.y + element.label.y
                    )
                    context.draw(
                        Text(element.name)
                            .font(.system(size: theme.component.fontSize, weight: theme.component.fontWeight))
                            .foregroundStyle(textColor.opacity(0.3)),
                        at: labelPt,
                        anchor: .topLeading
                    )

                } else if p < 0.45 {
                    // --- SNAP PHASE (0.2–0.45) ---
                    let snapT = (p - 0.2) / 0.25
                    let curved = snapCurve(snapT)

                    // Collapsing aberration
                    let aberration = 3.0 * (1.0 - curved)
                    let rightPt = CGPoint(x: pt.x + aberration, y: pt.y)
                    let rightRect = CGRect(x: rightPt.x - r, y: rightPt.y - r, width: r * 2, height: r * 2)
                    context.fill(Path(ellipseIn: rightRect), with: .color(primaryColor.opacity(0.6 * (1.0 - curved))))

                    let leftPt = CGPoint(x: pt.x - aberration, y: pt.y)
                    let leftRect = CGRect(x: leftPt.x - r, y: leftPt.y - r, width: r * 2, height: r * 2)
                    context.fill(Path(ellipseIn: leftRect), with: .color(cyanColor.opacity(0.6 * (1.0 - curved))))

                    // Flash: brief full-opacity primary rectangle behind dot
                    let flashOpacity = snapT < 0.3 ? (0.3 - snapT) / 0.3 * 0.8 : 0.0
                    if flashOpacity > 0 {
                        let flashRect = CGRect(
                            x: pt.x - r - 2, y: pt.y - r - 2,
                            width: (r + 2) * 2, height: (r + 2) * 2
                        )
                        context.fill(Path(roundedRect: flashRect, cornerRadius: 1), with: .color(primaryColor.opacity(flashOpacity)))
                    }

                    // Normal dot (opacity rising from 0.3 to 1.0)
                    let dotOpacity = 0.3 + 0.7 * curved
                    let rect = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(fillColor.opacity(dotOpacity)))
                    context.stroke(
                        Path(ellipseIn: rect),
                        with: .color(strokeColor.opacity(dotOpacity)),
                        style: StrokeStyle(lineWidth: theme.component.strokeWidth)
                    )

                    // Label (normal position, rising opacity)
                    let labelPt = CGPoint(
                        x: pt.x + element.label.x,
                        y: pt.y + element.label.y
                    )
                    context.draw(
                        Text(element.name)
                            .font(.system(size: theme.component.fontSize, weight: theme.component.fontWeight))
                            .foregroundStyle(textColor.opacity(dotOpacity)),
                        at: labelPt,
                        anchor: .topLeading
                    )

                } else {
                    // --- SETTLE PHASE (0.45–1.0) ---
                    let settleT = (p - 0.45) / 0.55

                    // Hard shadow rectangle fading out (4px offset, brand style)
                    let shadowOpacity = 0.6 * (1.0 - settleT)
                    if shadowOpacity > 0.01 {
                        let shadowRect = CGRect(
                            x: pt.x - r + 4, y: pt.y - r + 4,
                            width: r * 2, height: r * 2
                        )
                        context.fill(Path(roundedRect: shadowRect, cornerRadius: 0), with: .color(primaryColor.opacity(shadowOpacity)))
                    }

                    // Normal dot at full opacity
                    let rect = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(fillColor))
                    context.stroke(
                        Path(ellipseIn: rect),
                        with: .color(strokeColor),
                        style: StrokeStyle(lineWidth: theme.component.strokeWidth)
                    )

                    // Label at normal position
                    let labelPt = CGPoint(
                        x: pt.x + element.label.x,
                        y: pt.y + element.label.y
                    )
                    context.draw(
                        Text(element.name)
                            .font(.system(size: theme.component.fontSize, weight: theme.component.fontWeight))
                            .foregroundStyle(textColor),
                        at: labelPt,
                        anchor: .topLeading
                    )
                }

                // Inertia marker (always drawn during glitch)
                if element.inertia {
                    var inertiaPath = Path()
                    inertiaPath.move(to: CGPoint(x: pt.x + r + 2, y: pt.y - 8))
                    inertiaPath.addLine(to: CGPoint(x: pt.x + r + 2, y: pt.y + 8))
                    context.stroke(
                        inertiaPath,
                        with: .color(strokeColor),
                        style: StrokeStyle(lineWidth: 2)
                    )
                }

            } else {
                // === NORMAL DRAWING (no glitch) ===

                // Draw circle
                let rect = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: rect), with: .color(fillColor))
                context.stroke(
                    Path(ellipseIn: rect),
                    with: .color(strokeColor),
                    style: StrokeStyle(lineWidth: isHighlighted ? theme.component.strokeWidth + 2 : theme.component.strokeWidth)
                )

                // Inertia marker (small bar)
                if element.inertia {
                    var inertiaPath = Path()
                    inertiaPath.move(to: CGPoint(x: pt.x + r + 2, y: pt.y - 8))
                    inertiaPath.addLine(to: CGPoint(x: pt.x + r + 2, y: pt.y + 8))
                    context.stroke(
                        inertiaPath,
                        with: .color(strokeColor),
                        style: StrokeStyle(lineWidth: 2)
                    )
                }

                // Label
                let labelPt = CGPoint(
                    x: pt.x + element.label.x,
                    y: pt.y + element.label.y
                )
                context.draw(
                    Text(element.name)
                        .font(.system(size: theme.component.fontSize, weight: theme.component.fontWeight))
                        .foregroundStyle(textColor),
                    at: labelPt,
                    anchor: .topLeading
                )

                // Highlight ring
                if isHighlighted {
                    let highlightRect = CGRect(
                        x: pt.x - r - 3, y: pt.y - r - 3,
                        width: (r + 3) * 2, height: (r + 3) * 2
                    )
                    context.stroke(
                        Path(ellipseIn: highlightRect),
                        with: .color(.accentColor),
                        style: StrokeStyle(lineWidth: 2, dash: [4, 2])
                    )
                }
            }
        }
    }

    public static func drawAnchors(
        context: inout GraphicsContext,
        anchors: [MapAnchor],
        theme: MapTheme,
        calc: PositionCalculator
    ) {
        for anchor in anchors {
            let pt = calc.point(visibility: anchor.visibility, maturity: anchor.maturity)

            context.draw(
                Text(anchor.name)
                    .font(.system(size: theme.anchor.fontSize, weight: .bold))
                    .foregroundStyle(theme.component.textColor),
                at: pt,
                anchor: .leading
            )
        }
    }

    public static func drawSubmaps(
        context: inout GraphicsContext,
        submaps: [MapElement],
        theme: MapTheme,
        calc: PositionCalculator
    ) {
        for submap in submaps {
            let pt = calc.point(visibility: submap.visibility, maturity: submap.maturity)
            let r = theme.submap.radius
            let isEvolved = submap.evolved

            let fillColor = isEvolved ? theme.submap.evolvedFill : theme.submap.fill
            let strokeColor = isEvolved ? theme.submap.evolved : theme.submap.stroke
            let textColor = isEvolved ? theme.submap.evolvedTextColor : theme.submap.textColor

            // Draw filled circle
            let rect = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
            context.fill(Path(ellipseIn: rect), with: .color(fillColor))
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(strokeColor),
                style: StrokeStyle(lineWidth: theme.submap.strokeWidth)
            )

            // Label
            let labelPt = CGPoint(
                x: pt.x + submap.label.x,
                y: pt.y + submap.label.y
            )
            context.draw(
                Text(submap.name)
                    .font(.system(size: theme.submap.fontSize))
                    .foregroundStyle(textColor),
                at: labelPt,
                anchor: .topLeading
            )
        }
    }
}
