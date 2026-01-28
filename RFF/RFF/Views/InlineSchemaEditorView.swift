import SwiftUI
import PDFKit

/// Inline schema editor embedded in the Library document preview
/// Allows visual field mapping directly on the document without switching views
struct InlineSchemaEditorView: View {
    @Bindable var document: RFFDocument
    @StateObject private var viewModel = SchemaEditorViewModel()
    @Binding var isEditing: Bool

    /// Callback when schema is saved
    var onSchemaSaved: ((InvoiceSchema) -> Void)?

    @State private var showingSaveSheet = false
    @State private var showingFieldPicker = false
    @State private var selectedRegionForPicker: DetectedTextRegion?

    var body: some View {
        HSplitView {
            // Left: Document with schema overlay
            VStack(spacing: 0) {
                // Toolbar
                InlineSchemaToolbar(
                    viewModel: viewModel,
                    isEditing: $isEditing,
                    onAutoMap: { viewModel.autoMapFields() },
                    onSave: { showingSaveSheet = true }
                )

                Divider()

                // Document preview with interactive regions
                if let url = viewModel.documentURL {
                    InlineDocumentPreview(
                        url: url,
                        regions: viewModel.detectedRegions,
                        selectedRegion: $viewModel.selectedRegion,
                        onRegionTap: handleRegionTap,
                        onRegionDoubleTap: handleRegionDoubleTap
                    )
                } else {
                    ContentUnavailableView(
                        "Processing Document",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Analyzing document structure...")
                    )
                }
            }
            .frame(minWidth: 400)

            // Right: Field mapping sidebar
            InlineFieldSidebar(viewModel: viewModel)
                .frame(width: 280)
        }
        .task {
            await loadDocument()
        }
        .sheet(isPresented: $showingSaveSheet) {
            SaveSchemaSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showingFieldPicker) {
            if let region = selectedRegionForPicker {
                FieldTypePickerSheet(
                    region: region,
                    onSelect: { fieldType in
                        viewModel.mapRegion(region, to: fieldType)
                        showingFieldPicker = false
                        selectedRegionForPicker = nil
                    },
                    onCancel: {
                        showingFieldPicker = false
                        selectedRegionForPicker = nil
                    }
                )
            }
        }
        .overlay {
            if viewModel.isLoading {
                ZStack {
                    Color.black.opacity(0.3)
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Analyzing document...")
                            .font(.headline)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func loadDocument() async {
        guard let path = document.documentPath else { return }
        let url = URL(fileURLWithPath: path)

        await viewModel.loadSchemas()
        await viewModel.processDocument(at: url)
    }

    private func handleRegionTap(_ region: DetectedTextRegion) {
        viewModel.selectedRegion = region
    }

    private func handleRegionDoubleTap(_ region: DetectedTextRegion) {
        selectedRegionForPicker = region
        showingFieldPicker = true
    }
}

// MARK: - Inline Schema Toolbar

struct InlineSchemaToolbar: View {
    @ObservedObject var viewModel: SchemaEditorViewModel
    @Binding var isEditing: Bool
    let onAutoMap: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack {
            // Schema selector
            Picker("Schema", selection: $viewModel.selectedSchema) {
                Text("New Schema").tag(nil as InvoiceSchema?)
                Divider()
                ForEach(viewModel.availableSchemas) { schema in
                    Text(schema.name).tag(schema as InvoiceSchema?)
                }
            }
            .frame(width: 160)
            .onChange(of: viewModel.selectedSchema) { _, _ in
                Task {
                    await viewModel.classifyRegions()
                    viewModel.autoMapFields()
                }
            }

            Divider()
                .frame(height: 20)

            Button {
                onAutoMap()
            } label: {
                Label("Auto-Map", systemImage: "wand.and.stars")
            }
            .help("Automatically map detected text to fields")

            Button {
                onSave()
            } label: {
                Label("Save Schema", systemImage: "square.and.arrow.down")
            }
            .disabled(viewModel.fieldMappings.isEmpty)
            .help("Save current mappings as a schema")

            Spacer()

            // Legend
            HStack(spacing: 12) {
                LegendItem(color: .purple, label: "ID/Number")
                LegendItem(color: .blue, label: "Date")
                LegendItem(color: .green, label: "Amount")
                LegendItem(color: .orange, label: "Vendor")
            }
            .font(.caption)

            Divider()
                .frame(height: 20)

            Button {
                isEditing = false
            } label: {
                Label("Done", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

struct LegendItem: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color.opacity(0.5))
                .frame(width: 10, height: 10)
            Text(label)
        }
    }
}

// MARK: - Inline Document Preview

struct InlineDocumentPreview: View {
    let url: URL
    let regions: [DetectedTextRegion]
    @Binding var selectedRegion: DetectedTextRegion?
    let onRegionTap: (DetectedTextRegion) -> Void
    let onRegionDoubleTap: (DetectedTextRegion) -> Void

    @State private var pdfDocument: PDFDocument?
    @State private var scale: CGFloat = 1.0

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    if url.pathExtension.lowercased() == "pdf" {
                        PDFViewerWithInteractiveOverlay(
                            document: pdfDocument,
                            regions: regions,
                            selectedRegion: selectedRegion,
                            onRegionTap: onRegionTap,
                            onRegionDoubleTap: onRegionDoubleTap
                        )
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                    } else {
                        // Image preview with overlay
                        ImageWithInteractiveOverlay(
                            url: url,
                            regions: regions,
                            selectedRegion: selectedRegion,
                            onRegionTap: onRegionTap,
                            onRegionDoubleTap: onRegionDoubleTap
                        )
                    }
                }
            }
        }
        .onAppear {
            if url.pathExtension.lowercased() == "pdf" {
                pdfDocument = PDFDocument(url: url)
            }
        }
    }
}

// MARK: - PDF Viewer With Interactive Overlay

struct PDFViewerWithInteractiveOverlay: NSViewRepresentable {
    let document: PDFDocument?
    let regions: [DetectedTextRegion]
    let selectedRegion: DetectedTextRegion?
    let onRegionTap: (DetectedTextRegion) -> Void
    let onRegionDoubleTap: (DetectedTextRegion) -> Void

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.backgroundColor = .windowBackgroundColor

        // Add click gesture recognizer
        let clickRecognizer = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleClick(_:))
        )
        pdfView.addGestureRecognizer(clickRecognizer)

        let doubleClickRecognizer = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleClick(_:))
        )
        doubleClickRecognizer.numberOfClicksRequired = 2
        pdfView.addGestureRecognizer(doubleClickRecognizer)

        // Use page overlay provider for correct coordinate handling
        context.coordinator.pdfView = pdfView
        pdfView.pageOverlayViewProvider = context.coordinator

        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if pdfView.document != document {
            pdfView.document = document
        }
        context.coordinator.regions = regions
        context.coordinator.selectedRegion = selectedRegion

        // Force overlay refresh
        pdfView.pageOverlayViewProvider = nil
        pdfView.pageOverlayViewProvider = context.coordinator
        pdfView.layoutDocumentView()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            regions: regions,
            selectedRegion: selectedRegion,
            onRegionTap: onRegionTap,
            onRegionDoubleTap: onRegionDoubleTap
        )
    }

    class Coordinator: NSObject, PDFPageOverlayViewProvider {
        var pdfView: PDFView?
        var regions: [DetectedTextRegion]
        var selectedRegion: DetectedTextRegion?
        let onRegionTap: (DetectedTextRegion) -> Void
        let onRegionDoubleTap: (DetectedTextRegion) -> Void

        init(
            regions: [DetectedTextRegion],
            selectedRegion: DetectedTextRegion?,
            onRegionTap: @escaping (DetectedTextRegion) -> Void,
            onRegionDoubleTap: @escaping (DetectedTextRegion) -> Void
        ) {
            self.regions = regions
            self.selectedRegion = selectedRegion
            self.onRegionTap = onRegionTap
            self.onRegionDoubleTap = onRegionDoubleTap
        }

        // MARK: - PDFPageOverlayViewProvider

        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
            guard let document = view.document else { return nil }
            let pageIndex = document.index(for: page)

            let pageRegions = regions.filter { $0.pageIndex == pageIndex }
            guard !pageRegions.isEmpty else { return nil }

            return InteractiveRegionOverlayNSView(
                regions: pageRegions,
                selectedRegion: selectedRegion,
                page: page
            )
        }

        // MARK: - Click Handling

        @objc func handleClick(_ recognizer: NSClickGestureRecognizer) {
            guard let pdfView = pdfView else { return }
            let location = recognizer.location(in: pdfView)

            if let region = findRegion(at: location) {
                onRegionTap(region)
            }
        }

        @objc func handleDoubleClick(_ recognizer: NSClickGestureRecognizer) {
            guard let pdfView = pdfView else { return }
            let location = recognizer.location(in: pdfView)

            if let region = findRegion(at: location) {
                onRegionDoubleTap(region)
            }
        }

        private func findRegion(at point: CGPoint) -> DetectedTextRegion? {
            guard let pdfView = pdfView,
                  let document = pdfView.document else { return nil }

            // Find which page was clicked
            guard let clickedPage = pdfView.page(for: point, nearest: true) else { return nil }
            let pageIndex = document.index(for: clickedPage)

            // Convert click point to page coordinates (PDF uses bottom-left origin)
            let pagePoint = pdfView.convert(point, to: clickedPage)
            let pageBounds = clickedPage.bounds(for: .mediaBox)

            // Normalize to 0-1 range (same coordinate system as Vision)
            let normalizedX = pagePoint.x / pageBounds.width
            let normalizedY = pagePoint.y / pageBounds.height

            let normalizedPoint = CGPoint(x: normalizedX, y: normalizedY)

            return regions.first { region in
                region.pageIndex == pageIndex &&
                region.boundingBox.contains(point: normalizedPoint)
            }
        }
    }
}

// MARK: - Interactive Region Overlay NSView

/// NSView overlay for PDF pages that draws detected text regions
/// Used by PDFPageOverlayViewProvider for correct coordinate handling
private class InteractiveRegionOverlayNSView: NSView {
    let regions: [DetectedTextRegion]
    let selectedRegion: DetectedTextRegion?
    let page: PDFPage

    init(regions: [DetectedTextRegion], selectedRegion: DetectedTextRegion?, page: PDFPage) {
        self.regions = regions
        self.selectedRegion = selectedRegion
        self.page = page
        super.init(frame: .zero)
        self.wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let pageBounds = page.bounds(for: .mediaBox)

        for region in regions {
            // Convert normalized Vision coordinates to view coordinates
            // Vision: origin at bottom-left, Y increases upward (0-1 range)
            // NSView overlay: matches page coordinate system (bottom-left origin)
            // But we need to flip Y because the overlay is rendered with top-left origin in practice
            let viewRect = convertToViewCoordinates(region.boundingBox, pageBounds: pageBounds)

            let isSelected = selectedRegion?.id == region.id

            // Draw fill
            let fillColor: NSColor
            let strokeColor: NSColor

            if let fieldType = region.mappedFieldType {
                fillColor = colorForFieldType(fieldType).withAlphaComponent(0.3)
                strokeColor = colorForFieldType(fieldType)
            } else {
                fillColor = NSColor.gray.withAlphaComponent(0.2)
                strokeColor = isSelected ? NSColor.controlAccentColor : NSColor.gray
            }

            context.setFillColor(fillColor.cgColor)
            context.fill(viewRect)

            context.setStrokeColor(strokeColor.cgColor)
            context.setLineWidth(isSelected ? 2 : 1)
            context.stroke(viewRect)

            // Draw field label if mapped
            if let fieldType = region.mappedFieldType {
                let label = fieldType.displayName
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                    .foregroundColor: NSColor.white,
                    .backgroundColor: strokeColor
                ]
                let labelSize = label.size(withAttributes: attrs)
                let labelRect = CGRect(
                    x: viewRect.minX,
                    y: viewRect.maxY - labelSize.height - 2,
                    width: labelSize.width + 4,
                    height: labelSize.height
                )
                strokeColor.setFill()
                context.fill(labelRect)
                label.draw(at: CGPoint(x: labelRect.minX + 2, y: labelRect.minY), withAttributes: attrs)
            }
        }
    }

    /// Convert normalized Vision coordinates to view coordinates
    /// Vision uses bottom-left origin (Y=0 at bottom, Y=1 at top)
    /// The overlay view coordinate system needs Y flipped for correct rendering
    private func convertToViewCoordinates(_ box: NormalizedRegion, pageBounds: CGRect) -> CGRect {
        // Guard against invalid bounds
        guard pageBounds.width > 0, pageBounds.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            return .zero
        }

        let scaleX = bounds.width / pageBounds.width
        let scaleY = bounds.height / pageBounds.height

        // Vision Y=0 is bottom, Y=1 is top
        // Overlay view: Y=0 is top (after PDFKit transformation), Y=height is bottom
        // So we need to flip: viewY = height - (visionY * height) - boxHeight
        let flippedY = pageBounds.height - (box.y * pageBounds.height) - (box.height * pageBounds.height)

        return CGRect(
            x: box.x * pageBounds.width * scaleX,
            y: flippedY * scaleY,
            width: box.width * pageBounds.width * scaleX,
            height: box.height * pageBounds.height * scaleY
        )
    }
}

// MARK: - Image With Interactive Overlay

struct ImageWithInteractiveOverlay: View {
    let url: URL
    let regions: [DetectedTextRegion]
    let selectedRegion: DetectedTextRegion?
    let onRegionTap: (DetectedTextRegion) -> Void
    let onRegionDoubleTap: (DetectedTextRegion) -> Void

    @State private var image: NSImage?
    @State private var imageSize: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: geometry.size.width, maxHeight: geometry.size.height)
                    .background(
                        GeometryReader { imageGeometry in
                            Color.clear
                                .onAppear { imageSize = imageGeometry.size }
                                .onChange(of: imageGeometry.size) { _, newSize in
                                    imageSize = newSize
                                }
                        }
                    )
                    .overlay {
                        ForEach(regions) { region in
                            InteractiveRegionOverlay(
                                region: region,
                                imageSize: imageSize,
                                isSelected: selectedRegion?.id == region.id,
                                onTap: { onRegionTap(region) },
                                onDoubleTap: { onRegionDoubleTap(region) }
                            )
                        }
                    }
            } else {
                ProgressView()
            }
        }
        .onAppear {
            image = NSImage(contentsOf: url)
        }
    }
}

// MARK: - Interactive Region Overlay

struct InteractiveRegionOverlay: View {
    let region: DetectedTextRegion
    let imageSize: CGSize
    let isSelected: Bool
    let onTap: () -> Void
    let onDoubleTap: () -> Void

    var body: some View {
        let rect = convertToViewCoordinates(region.boundingBox, imageSize: imageSize)

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(fillColor.opacity(0.3))
                .frame(width: rect.width, height: rect.height)

            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(strokeColor, lineWidth: isSelected ? 2 : 1)
                .frame(width: rect.width, height: rect.height)

            if let fieldType = region.mappedFieldType {
                Text(fieldType.displayName)
                    .font(.system(size: 8))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(fillColor)
                    .foregroundColor(.white)
                    .cornerRadius(2)
                    .offset(y: -14)
            }
        }
        .position(x: rect.midX, y: rect.midY)
        .onTapGesture(count: 2) {
            onDoubleTap()
        }
        .onTapGesture(count: 1) {
            onTap()
        }
        .draggable(DetectedTextRegionTransfer(id: region.id, text: region.text))
    }

    private var fillColor: Color {
        if let fieldType = region.mappedFieldType {
            return Color(nsColor: colorForFieldType(fieldType))
        }
        return Color.gray
    }

    private var strokeColor: Color {
        if let fieldType = region.mappedFieldType {
            return Color(nsColor: colorForFieldType(fieldType))
        }
        return isSelected ? Color.accentColor : Color.gray
    }

    private func convertToViewCoordinates(_ box: NormalizedRegion, imageSize: CGSize) -> CGRect {
        let x = box.x * imageSize.width
        let y = (1 - box.y - box.height) * imageSize.height
        let width = box.width * imageSize.width
        let height = box.height * imageSize.height
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - Inline Field Sidebar

struct InlineFieldSidebar: View {
    @ObservedObject var viewModel: SchemaEditorViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Field Mappings")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.fieldMappings.count) mapped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            // Field list
            List {
                Section("Required") {
                    ForEach(InvoiceFieldType.allCases.filter { $0.isRequired }) { fieldType in
                        InlineFieldDropTarget(
                            fieldType: fieldType,
                            mapping: viewModel.fieldMappings[fieldType],
                            viewModel: viewModel
                        )
                    }
                }

                Section("Header Fields") {
                    ForEach(InvoiceFieldType.allCases.filter { !$0.isRequired && !$0.isLineItemField }) { fieldType in
                        InlineFieldDropTarget(
                            fieldType: fieldType,
                            mapping: viewModel.fieldMappings[fieldType],
                            viewModel: viewModel
                        )
                    }
                }

                Section("Line Items") {
                    ForEach(InvoiceFieldType.allCases.filter { $0.isLineItemField }) { fieldType in
                        InlineFieldDropTarget(
                            fieldType: fieldType,
                            mapping: viewModel.fieldMappings[fieldType],
                            viewModel: viewModel
                        )
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            // Selected region info
            if let selected = viewModel.selectedRegion {
                SelectedRegionInfo(region: selected, viewModel: viewModel)
            }
        }
    }
}

// MARK: - Inline Field Drop Target

struct InlineFieldDropTarget: View {
    let fieldType: InvoiceFieldType
    let mapping: DetectedTextRegion?
    @ObservedObject var viewModel: SchemaEditorViewModel

    @State private var isTargeted = false

    var body: some View {
        HStack {
            Circle()
                .fill(Color(nsColor: colorForFieldType(fieldType)))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(fieldType.displayName)
                    .font(.subheadline)
                    .fontWeight(mapping != nil ? .medium : .regular)

                if let mapping = mapping {
                    Text(mapping.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if mapping != nil {
                Button {
                    viewModel.clearMapping(for: fieldType)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(backgroundColor)
        )
        .dropDestination(for: DetectedTextRegionTransfer.self) { items, _ in
            guard let item = items.first,
                  let region = viewModel.detectedRegions.first(where: { $0.id == item.id }) else {
                return false
            }
            viewModel.mapRegion(region, to: fieldType)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }

    private var backgroundColor: Color {
        if isTargeted {
            return Color.accentColor.opacity(0.2)
        } else if mapping != nil {
            return Color(nsColor: colorForFieldType(fieldType)).opacity(0.1)
        }
        return Color.clear
    }
}

// MARK: - Selected Region Info

struct SelectedRegionInfo: View {
    let region: DetectedTextRegion
    @ObservedObject var viewModel: SchemaEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Selected Region")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(region.text)
                .font(.subheadline)
                .lineLimit(3)

            if let classification = viewModel.classificationResults[region.id] {
                HStack {
                    Label(classification.fieldType.displayName, systemImage: "sparkles")
                        .font(.caption)
                    Text("\(Int(classification.confidence * 100))%")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack {
                Text("Confidence: \(Int(region.confidence * 100))%")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                if let mapped = region.mappedFieldType {
                    Spacer()
                    Text("→ \(mapped.displayName)")
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: colorForFieldType(mapped)))
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Field Type Picker Sheet

struct FieldTypePickerSheet: View {
    let region: DetectedTextRegion
    let onSelect: (InvoiceFieldType) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Assign Field Type")
                .font(.headline)

            Text(region.text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.horizontal)

            Divider()

            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(InvoiceFieldType.allCases) { fieldType in
                        Button {
                            onSelect(fieldType)
                        } label: {
                            HStack {
                                Circle()
                                    .fill(Color(nsColor: colorForFieldType(fieldType)))
                                    .frame(width: 8, height: 8)
                                Text(fieldType.displayName)
                                    .font(.subheadline)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .frame(maxHeight: 300)

            Divider()

            HStack {
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.bottom)
        }
        .frame(width: 350, height: 450)
    }
}

// MARK: - Preview

#Preview {
    InlineSchemaEditorView(
        document: RFFDocument(
            title: "Test Invoice",
            requestingOrganization: "Test Org",
            amount: 100,
            dueDate: Date()
        ),
        isEditing: .constant(true)
    )
    .frame(width: 1000, height: 700)
}
