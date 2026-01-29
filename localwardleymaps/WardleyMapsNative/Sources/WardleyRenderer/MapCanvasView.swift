import SwiftUI
import WardleyModel
import WardleyTheme

/// SwiftUI Canvas view that renders a complete Wardley Map.
public struct MapCanvasView: View {
    public let map: WardleyMap
    public let theme: MapTheme
    public let highlightedLine: Int?
    public let glitchProgress: [String: GlitchInfo]
    public let dragOverride: (elementName: String, position: CGPoint)?
    public let onDragChanged: ((_ elementName: String, _ canvasPosition: CGPoint) -> Void)?
    public let onDragEnded: ((_ elementName: String, _ canvasPosition: CGPoint) -> Void)?

    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var dragElementName: String? = nil

    public init(
        map: WardleyMap,
        theme: MapTheme,
        highlightedLine: Int? = nil,
        glitchProgress: [String: GlitchInfo] = [:],
        dragOverride: (elementName: String, position: CGPoint)? = nil,
        onDragChanged: ((_ elementName: String, _ canvasPosition: CGPoint) -> Void)? = nil,
        onDragEnded: ((_ elementName: String, _ canvasPosition: CGPoint) -> Void)? = nil
    ) {
        self.map = map
        self.theme = theme
        self.highlightedLine = highlightedLine
        self.glitchProgress = glitchProgress
        self.dragOverride = dragOverride
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
    }

    var mapWidth: CGFloat {
        map.presentation.size.width > 0 ? map.presentation.size.width : MapDefaults.canvasWidth
    }

    var mapHeight: CGFloat {
        map.presentation.size.height > 0 ? map.presentation.size.height : MapDefaults.canvasHeight
    }

    public var body: some View {
        GeometryReader { geo in
            let fitScale = min(
                geo.size.width / (mapWidth + 40),
                geo.size.height / (mapHeight + 60)
            )
            let effectiveScale = fitScale * scale

            ScrollView([.horizontal, .vertical]) {
                canvas
                    .frame(width: mapWidth + 40, height: mapHeight + 60)
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in
                                handleCanvasDragChanged(value)
                            }
                            .onEnded { value in
                                handleCanvasDragEnded(value)
                            }
                    )
                    .scaleEffect(effectiveScale)
                    .frame(
                        width: (mapWidth + 40) * effectiveScale,
                        height: (mapHeight + 60) * effectiveScale
                    )
            }
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        scale = max(0.5, min(3.0, value.magnification))
                    }
            )
        }
    }

    private func handleCanvasDragChanged(_ value: DragGesture.Value) {
        let calc = PositionCalculator(mapWidth: mapWidth, mapHeight: mapHeight)

        // First touch: hit-test to find nearest element
        if dragElementName == nil {
            let hitRadius: CGFloat = theme.component.radius + 8
            var bestDist: CGFloat = .infinity
            var bestName: String? = nil

            for element in map.elements {
                let pt = calc.point(visibility: element.visibility, maturity: element.maturity)
                let dx = pt.x - value.startLocation.x
                let dy = pt.y - value.startLocation.y
                let dist = sqrt(dx * dx + dy * dy)
                if dist < hitRadius && dist < bestDist {
                    bestDist = dist
                    bestName = element.name
                }
            }
            for anchor in map.anchors {
                let pt = calc.point(visibility: anchor.visibility, maturity: anchor.maturity)
                let dx = pt.x - value.startLocation.x
                let dy = pt.y - value.startLocation.y
                let dist = sqrt(dx * dx + dy * dy)
                if dist < hitRadius && dist < bestDist {
                    bestDist = dist
                    bestName = anchor.name
                }
            }
            for submap in map.submaps {
                let pt = calc.point(visibility: submap.visibility, maturity: submap.maturity)
                let dx = pt.x - value.startLocation.x
                let dy = pt.y - value.startLocation.y
                let dist = sqrt(dx * dx + dy * dy)
                if dist < hitRadius && dist < bestDist {
                    bestDist = dist
                    bestName = submap.name
                }
            }
            dragElementName = bestName
        }

        if let name = dragElementName {
            onDragChanged?(name, value.location)
        }
    }

    private func handleCanvasDragEnded(_ value: DragGesture.Value) {
        if let name = dragElementName {
            onDragEnded?(name, value.location)
        }
        dragElementName = nil
    }

    var canvas: some View {
        Canvas { context, size in
            let calc = PositionCalculator(mapWidth: mapWidth, mapHeight: mapHeight)

            // Build position overrides from drag state
            var posOverrides: [String: CGPoint] = [:]
            if let drag = dragOverride {
                posOverrides[drag.elementName] = drag.position
            }

            // 1. Grid background
            GridDrawing.draw(
                context: &context,
                size: size,
                theme: theme,
                evolution: map.evolution,
                calc: calc
            )

            // 2. Attitudes (behind everything)
            AttitudeDrawing.draw(
                context: &context,
                attitudes: map.attitudes,
                theme: theme,
                calc: calc
            )

            // 3. Pipelines
            PipelineDrawing.draw(
                context: &context,
                pipelines: map.pipelines,
                elements: map.elements,
                theme: theme,
                calc: calc
            )

            // 4. Links
            LinkDrawing.draw(
                context: &context,
                links: map.links,
                elements: map.elements,
                anchors: map.anchors,
                submaps: map.submaps,
                evolved: map.evolved,
                theme: theme,
                calc: calc,
                positionOverrides: posOverrides
            )

            // 5. Evolution links (dashed red)
            EvolutionLinkDrawing.draw(
                context: &context,
                elements: map.elements,
                evolved: map.evolved,
                theme: theme,
                calc: calc,
                positionOverrides: posOverrides
            )

            // 6. Components
            ComponentDrawing.drawElements(
                context: &context,
                elements: map.elements,
                theme: theme,
                calc: calc,
                highlightedLine: highlightedLine,
                glitchProgress: glitchProgress,
                positionOverrides: posOverrides
            )

            // 7. Anchors
            ComponentDrawing.drawAnchors(
                context: &context,
                anchors: map.anchors,
                theme: theme,
                calc: calc
            )

            // 8. Submaps
            ComponentDrawing.drawSubmaps(
                context: &context,
                submaps: map.submaps,
                theme: theme,
                calc: calc
            )

            // 9. Annotations
            AnnotationDrawing.draw(
                context: &context,
                annotations: map.annotations,
                presentation: map.presentation,
                theme: theme,
                calc: calc
            )

            // 10. Notes
            NoteDrawing.drawNotes(
                context: &context,
                notes: map.notes,
                theme: theme,
                calc: calc
            )

            // 11. Accelerators
            NoteDrawing.drawAccelerators(
                context: &context,
                accelerators: map.accelerators,
                theme: theme,
                calc: calc
            )

            // 12. Methods
            MethodDrawing.draw(
                context: &context,
                methods: map.methods,
                elements: map.elements,
                theme: theme,
                calc: calc
            )

            // 13. Title
            if !map.title.isEmpty && map.title != "Untitled Map" {
                context.draw(
                    Text(map.title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(theme.stroke),
                    at: CGPoint(x: mapWidth / 2, y: 10),
                    anchor: .top
                )
            }
        }
    }
}
