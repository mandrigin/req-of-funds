import SwiftUI
import PDFKit

/// Inline schema editor embedded in the Library document preview
/// Allows visual field mapping directly on the document without switching views
struct InlineSchemaEditorView: View {
    @Bindable var document: RFFDocument
    @StateObject private var viewModel = SchemaEditorViewModel()
    @Binding var isEditing: Bool

    /// Callback when schema is saved and extraction requested
    var onSchemaSavedAndExtract: ((InvoiceSchema) -> Void)?

    @State private var showingSaveSheet = false
    @State private var showingFieldPicker = false
    @State private var selectedRegionForPicker: DetectedTextRegion?

    // Extraction state
    @State private var isExtractingWithSchema = false
    @State private var extractionResult: SchemaExtractionResultWithValues?
    @State private var showingExtractionResult = false
    @State private var extractionError: String?
    @State private var showingExtractionError = false

    private let schemaExtractionService = SchemaExtractionService.shared

    var body: some View {
        HSplitView {
            // Left: Document with schema overlay
            VStack(spacing: 0) {
                // Toolbar
                InlineSchemaToolbar(
                    viewModel: viewModel,
                    document: document,
                    isEditing: $isEditing,
                    isExtractingWithSchema: isExtractingWithSchema,
                    onAutoMap: { viewModel.autoMapFields() },
                    onSave: { showingSaveSheet = true },
                    onSaveAndExtract: { saveAndExtract() },
                    onExtractNow: { extractWithCurrentSchema() }
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
            SaveSchemaSheetWithExtract(
                viewModel: viewModel,
                onSaved: { schema in
                    // Update document's schema
                    document.schemaId = schema.id
                    document.updatedAt = Date()
                },
                onSavedAndExtract: { schema in
                    document.schemaId = schema.id
                    document.updatedAt = Date()
                    Task {
                        await extractWithSchema(schema)
                    }
                }
            )
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
        .sheet(isPresented: $showingExtractionResult) {
            if let result = extractionResult {
                InlineExtractionResultSheet(
                    result: result,
                    document: document,
                    onApply: { result in
                        Task {
                            await schemaExtractionService.applyToDocument(result, document: document)
                            showingExtractionResult = false
                            isEditing = false  // Exit editor after applying
                        }
                    },
                    onDismiss: { showingExtractionResult = false }
                )
            }
        }
        .alert("Extraction Error", isPresented: $showingExtractionError) {
            Button("OK") { }
        } message: {
            Text(extractionError ?? "Unknown error")
        }
        .overlay {
            if viewModel.isLoading || isExtractingWithSchema {
                ZStack {
                    Color.black.opacity(0.3)
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text(isExtractingWithSchema ? "Extracting fields..." : "Analyzing document...")
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

        // If document has an assigned schema, select it
        if let schemaId = document.schemaId {
            let schema = await SchemaStore.shared.schema(id: schemaId)
            viewModel.selectedSchema = schema
        }

        await viewModel.processDocument(at: url)
    }

    private func handleRegionTap(_ region: DetectedTextRegion) {
        viewModel.selectedRegion = region
    }

    private func handleRegionDoubleTap(_ region: DetectedTextRegion) {
        selectedRegionForPicker = region
        showingFieldPicker = true
    }

    /// Save schema and immediately run extraction
    private func saveAndExtract() {
        Task {
            do {
                let schema = try await viewModel.saveAsNewSchema()
                document.schemaId = schema.id
                document.updatedAt = Date()
                await extractWithSchema(schema)
            } catch {
                extractionError = error.localizedDescription
                showingExtractionError = true
            }
        }
    }

    /// Extract using the currently selected schema
    private func extractWithCurrentSchema() {
        guard let schema = viewModel.selectedSchema else {
            extractionError = "No schema selected"
            showingExtractionError = true
            return
        }

        // Update document's schema
        document.schemaId = schema.id
        document.updatedAt = Date()

        Task {
            await extractWithSchema(schema)
        }
    }

    /// Run extraction with a specific schema
    private func extractWithSchema(_ schema: InvoiceSchema) async {
        guard let path = document.documentPath else {
            await MainActor.run {
                extractionError = "Document has no associated file"
                showingExtractionError = true
            }
            return
        }

        await MainActor.run {
            isExtractingWithSchema = true
        }

        do {
            let result = try await schemaExtractionService.extractWithSchema(
                schema,
                documentURL: URL(fileURLWithPath: path)
            )
            await MainActor.run {
                extractionResult = result
                showingExtractionResult = true
                isExtractingWithSchema = false
            }
        } catch {
            await MainActor.run {
                extractionError = error.localizedDescription
                showingExtractionError = true
                isExtractingWithSchema = false
            }
        }
    }
}

// MARK: - Inline Schema Toolbar

struct InlineSchemaToolbar: View {
    @ObservedObject var viewModel: SchemaEditorViewModel
    let document: RFFDocument
    @Binding var isEditing: Bool
    let isExtractingWithSchema: Bool
    let onAutoMap: () -> Void
    let onSave: () -> Void
    let onSaveAndExtract: () -> Void
    let onExtractNow: () -> Void

    /// Whether we have an existing schema selected (vs creating new)
    private var hasExistingSchema: Bool {
        viewModel.selectedSchema != nil
    }

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
            .help("Select a schema to apply or create a new one")

            Divider()
                .frame(height: 20)

            Button {
                onAutoMap()
            } label: {
                Label("Auto-Map", systemImage: "wand.and.stars")
            }
            .help("Automatically map detected text to fields")

            // Save/Extract buttons
            if hasExistingSchema {
                // Using existing schema - can extract directly
                Button {
                    onExtractNow()
                } label: {
                    if isExtractingWithSchema {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Re-analyze", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isExtractingWithSchema)
                .help("Extract fields using this schema")
            } else {
                // Creating new schema - save first
                Button {
                    onSave()
                } label: {
                    Label("Save Schema", systemImage: "square.and.arrow.down")
                }
                .disabled(viewModel.fieldMappings.isEmpty)
                .help("Save current mappings as a schema")

                Button {
                    onSaveAndExtract()
                } label: {
                    if isExtractingWithSchema {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Save & Extract", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(viewModel.fieldMappings.isEmpty || isExtractingWithSchema)
                .buttonStyle(.borderedProminent)
                .help("Save schema and extract field values")
            }

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
            .help("Finish editing and close the schema editor")
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

        // Add overlay for regions
        context.coordinator.pdfView = pdfView
        context.coordinator.updateOverlays()

        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if pdfView.document != document {
            pdfView.document = document
        }
        context.coordinator.regions = regions
        context.coordinator.selectedRegion = selectedRegion
        context.coordinator.updateOverlays()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            regions: regions,
            selectedRegion: selectedRegion,
            onRegionTap: onRegionTap,
            onRegionDoubleTap: onRegionDoubleTap
        )
    }

    class Coordinator: NSObject {
        var pdfView: PDFView?
        var regions: [DetectedTextRegion]
        var selectedRegion: DetectedTextRegion?
        let onRegionTap: (DetectedTextRegion) -> Void
        let onRegionDoubleTap: (DetectedTextRegion) -> Void
        var overlayViews: [NSView] = []

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

        func updateOverlays() {
            // Remove existing overlays
            overlayViews.forEach { $0.removeFromSuperview() }
            overlayViews.removeAll()

            guard let pdfView = pdfView,
                  let document = pdfView.document else { return }

            for region in regions {
                guard region.pageIndex < document.pageCount,
                      let page = document.page(at: region.pageIndex) else { continue }

                let pageBounds = page.bounds(for: .mediaBox)
                let pdfRect = CGRect(
                    x: region.boundingBox.x * pageBounds.width,
                    y: region.boundingBox.y * pageBounds.height,
                    width: region.boundingBox.width * pageBounds.width,
                    height: region.boundingBox.height * pageBounds.height
                )

                // Convert to view coordinates
                let viewRect = pdfView.convert(pdfRect, from: page)

                // Create overlay view
                let overlay = RegionOverlayView(frame: viewRect)
                overlay.region = region
                overlay.isSelected = selectedRegion?.id == region.id
                overlay.wantsLayer = true

                pdfView.documentView?.addSubview(overlay)
                overlayViews.append(overlay)
            }
        }

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
                  let document = pdfView.document,
                  let currentPage = pdfView.currentPage else { return nil }

            let pageIndex = document.index(for: currentPage)

            let pagePoint = pdfView.convert(point, to: currentPage)
            let pageBounds = currentPage.bounds(for: .mediaBox)

            let normalizedPoint = CGPoint(
                x: pagePoint.x / pageBounds.width,
                y: pagePoint.y / pageBounds.height
            )

            return regions.first { region in
                region.pageIndex == pageIndex &&
                region.boundingBox.contains(point: normalizedPoint)
            }
        }
    }
}

// MARK: - Region Overlay View (NSView)

class RegionOverlayView: NSView {
    var region: DetectedTextRegion?
    var isSelected: Bool = false {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let region = region else { return }

        let fillColor: NSColor
        let strokeColor: NSColor

        if let fieldType = region.mappedFieldType {
            fillColor = colorForFieldType(fieldType).withAlphaComponent(0.3)
            strokeColor = colorForFieldType(fieldType)
        } else {
            fillColor = NSColor.gray.withAlphaComponent(0.2)
            strokeColor = isSelected ? NSColor.controlAccentColor : NSColor.gray
        }

        fillColor.setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2)
        path.fill()

        strokeColor.setStroke()
        path.lineWidth = isSelected ? 2 : 1
        path.stroke()

        // Draw field label if mapped
        if let fieldType = region.mappedFieldType {
            let labelRect = CGRect(x: 2, y: bounds.height - 14, width: bounds.width - 4, height: 12)
            let label = fieldType.displayName
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor.white,
                .backgroundColor: strokeColor
            ]
            label.draw(in: labelRect, withAttributes: attrs)
        }
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

// MARK: - Save Schema Sheet with Extract Option

/// Sheet for saving schema with option to immediately extract
struct SaveSchemaSheetWithExtract: View {
    @ObservedObject var viewModel: SchemaEditorViewModel
    @Environment(\.dismiss) private var dismiss
    let onSaved: (InvoiceSchema) -> Void
    let onSavedAndExtract: (InvoiceSchema) -> Void

    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("Save Schema")
                .font(.headline)

            Form {
                TextField("Schema Name", text: $viewModel.newSchemaName)

                Section("Mapped Fields (\(viewModel.fieldMappings.count))") {
                    ForEach(Array(viewModel.fieldMappings.keys), id: \.self) { fieldType in
                        if let mapping = viewModel.fieldMappings[fieldType] {
                            HStack {
                                Circle()
                                    .fill(Color(nsColor: colorForFieldType(fieldType)))
                                    .frame(width: 8, height: 8)
                                Text(fieldType.displayName)
                                Spacer()
                                Text(mapping.text)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .font(.caption)
                        }
                    }
                }
            }

            if let error = errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    saveSchema(andExtract: false)
                }
                .disabled(viewModel.newSchemaName.isEmpty || isSaving)

                Button("Save & Extract") {
                    saveSchema(andExtract: true)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.newSchemaName.isEmpty || isSaving)
            }
        }
        .padding()
        .frame(width: 400, height: 400)
    }

    private func saveSchema(andExtract: Bool) {
        isSaving = true
        errorMessage = nil

        Task {
            do {
                let schema = try await viewModel.saveAsNewSchema()
                await MainActor.run {
                    if andExtract {
                        onSavedAndExtract(schema)
                    } else {
                        onSaved(schema)
                    }
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
            await MainActor.run {
                isSaving = false
            }
        }
    }
}

// MARK: - Inline Extraction Result Sheet

/// Sheet showing extraction results in inline editor context
struct InlineExtractionResultSheet: View {
    let result: SchemaExtractionResultWithValues
    let document: RFFDocument
    let onApply: (SchemaExtractionResultWithValues) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Extraction Complete")
                        .font(.headline)
                    Text("Schema: \(result.schemaName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                InlineConfidenceBadge(confidence: result.overallConfidence)
            }
            .padding()

            Divider()

            // Extracted fields list
            List {
                Section("Extracted Fields (\(result.extractedFields.count))") {
                    ForEach(result.extractedFields) { field in
                        HStack {
                            Circle()
                                .fill(Color(nsColor: colorForFieldType(field.fieldType)))
                                .frame(width: 10, height: 10)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(field.fieldType.displayName)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text(field.value)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }

                            Spacer()

                            Text("\(Int(field.confidence * 100))%")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(confidenceColor(field.confidence).opacity(0.2), in: Capsule())
                        }
                        .padding(.vertical, 4)
                    }
                }

                if !result.warnings.isEmpty {
                    Section("Warnings") {
                        ForEach(result.warnings, id: \.self) { warning in
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(warning)
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)

            Divider()

            // Footer with actions
            HStack {
                Text("Apply these values to update the document?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Apply Values") {
                    onApply(result)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 450, height: 500)
    }

    private func confidenceColor(_ confidence: Double) -> Color {
        if confidence >= 0.8 {
            return .green
        } else if confidence >= 0.5 {
            return .orange
        } else {
            return .red
        }
    }
}

/// Confidence badge for inline editor
struct InlineConfidenceBadge: View {
    let confidence: Double

    var body: some View {
        Text("\(Int(confidence * 100))% confidence")
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(confidenceColor.opacity(0.2), in: Capsule())
            .foregroundStyle(confidenceColor)
    }

    private var confidenceColor: Color {
        if confidence >= 0.8 {
            return .green
        } else if confidence >= 0.5 {
            return .orange
        } else {
            return .red
        }
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
