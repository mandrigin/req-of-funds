import SwiftUI
import PDFKit

/// A detected text region that can be mapped to a field
struct DetectedTextRegion: Identifiable, Equatable {
    let id: UUID
    let text: String
    let boundingBox: NormalizedRegion
    let pageIndex: Int
    let confidence: Float
    var mappedFieldType: InvoiceFieldType?

    init(from observation: TextObservation, pageIndex: Int = 0) {
        self.id = observation.id
        self.text = observation.text
        self.boundingBox = NormalizedRegion(cgRect: observation.boundingBox)
        self.pageIndex = pageIndex
        self.confidence = observation.confidence
        self.mappedFieldType = nil
    }
}

/// View model for the schema editor
@MainActor
class SchemaEditorViewModel: ObservableObject {
    /// The document being analyzed
    @Published var documentURL: URL?

    /// Initial URL to load on appear (set via initializer)
    var initialURL: URL?

    /// Detected text regions from OCR
    @Published var detectedRegions: [DetectedTextRegion] = []

    /// Currently selected schema template
    @Published var selectedSchema: InvoiceSchema?

    /// Available schemas
    @Published var availableSchemas: [InvoiceSchema] = []

    /// Field mappings being edited
    @Published var fieldMappings: [InvoiceFieldType: DetectedTextRegion] = [:]

    /// Currently selected region
    @Published var selectedRegion: DetectedTextRegion?

    /// Currently highlighted field type (for drop target)
    @Published var highlightedFieldType: InvoiceFieldType?

    /// Loading state
    @Published var isLoading = false

    /// Error message
    @Published var errorMessage: String?

    /// New schema name (for saving)
    @Published var newSchemaName = ""

    /// Auto-classified results
    @Published var classificationResults: [UUID: FieldClassificationResult] = [:]

    private let ocrService = DocumentOCRService()
    private let fieldClassifier = FieldClassifier.shared

    /// Load schemas from store
    func loadSchemas() async {
        let store = SchemaStore.shared
        try? await store.loadSchemas()
        availableSchemas = await store.allSchemas()

        // Select generic schema by default
        if selectedSchema == nil {
            selectedSchema = availableSchemas.first
        }
    }

    /// Process a document with OCR
    func processDocument(at url: URL) async {
        isLoading = true
        errorMessage = nil
        documentURL = url

        do {
            let result = try await ocrService.processDocument(at: url)

            // Convert observations to detected regions
            var regions: [DetectedTextRegion] = []
            for (pageIndex, page) in result.pages.enumerated() {
                for observation in page.observations {
                    regions.append(DetectedTextRegion(from: observation, pageIndex: pageIndex))
                }
            }
            detectedRegions = regions

            // Run field classification
            await classifyRegions()

            // Auto-map fields based on classification
            autoMapFields()

        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Run field classification on detected regions
    func classifyRegions() async {
        guard !detectedRegions.isEmpty else { return }

        let observations = detectedRegions.map { region in
            TextObservation(
                text: region.text,
                confidence: region.confidence,
                boundingBox: region.boundingBox.cgRect
            )
        }

        let results: [FieldClassificationResult]
        if let schema = selectedSchema {
            results = await fieldClassifier.classifyWithSchema(observations, schema: schema)
        } else {
            results = await fieldClassifier.classifyObservations(observations)
        }

        // Index results by their text for matching
        for result in results {
            if let region = detectedRegions.first(where: { $0.text == result.text }) {
                classificationResults[region.id] = result
            }
        }
    }

    /// Auto-map fields based on classification results
    func autoMapFields() {
        fieldMappings.removeAll()

        // Sort results by confidence and assign to fields
        var assignedRegions: Set<UUID> = []

        for fieldType in InvoiceFieldType.allCases {
            // Find best unassigned region for this field type
            let candidates = classificationResults
                .filter { !assignedRegions.contains($0.key) }
                .filter { $0.value.fieldType == fieldType }
                .sorted { $0.value.confidence > $1.value.confidence }

            if let best = candidates.first,
               let region = detectedRegions.first(where: { $0.id == best.key }) {
                var mappedRegion = region
                mappedRegion.mappedFieldType = fieldType
                fieldMappings[fieldType] = mappedRegion
                assignedRegions.insert(region.id)

                // Update the region in the list
                if let index = detectedRegions.firstIndex(where: { $0.id == region.id }) {
                    detectedRegions[index].mappedFieldType = fieldType
                }
            }
        }
    }

    /// Map a region to a field type
    func mapRegion(_ region: DetectedTextRegion, to fieldType: InvoiceFieldType) {
        // Remove any existing mapping for this field type
        if let existingRegion = fieldMappings[fieldType] {
            if let index = detectedRegions.firstIndex(where: { $0.id == existingRegion.id }) {
                detectedRegions[index].mappedFieldType = nil
            }
        }

        // Remove any existing mapping for this region
        for (type, mappedRegion) in fieldMappings {
            if mappedRegion.id == region.id {
                fieldMappings.removeValue(forKey: type)
            }
        }

        // Add new mapping
        var mappedRegion = region
        mappedRegion.mappedFieldType = fieldType
        fieldMappings[fieldType] = mappedRegion

        if let index = detectedRegions.firstIndex(where: { $0.id == region.id }) {
            detectedRegions[index].mappedFieldType = fieldType
        }
    }

    /// Clear mapping for a field type
    func clearMapping(for fieldType: InvoiceFieldType) {
        if let region = fieldMappings[fieldType] {
            if let index = detectedRegions.firstIndex(where: { $0.id == region.id }) {
                detectedRegions[index].mappedFieldType = nil
            }
        }
        fieldMappings.removeValue(forKey: fieldType)
    }

    /// Save current mappings as a new schema
    func saveAsNewSchema() async throws -> InvoiceSchema {
        guard !newSchemaName.isEmpty else {
            throw SchemaStoreError.invalidSchema("Schema name is required")
        }

        let mappings = fieldMappings.map { (fieldType, region) in
            FieldMapping(
                fieldType: fieldType,
                region: region.boundingBox,
                pattern: nil,
                labelHint: nil,
                confidence: Double(region.confidence)
            )
        }

        let schema = try await SchemaStore.shared.createSchema(
            name: newSchemaName,
            vendorIdentifier: nil,
            description: "Created from document analysis",
            fieldMappings: mappings
        )

        availableSchemas = await SchemaStore.shared.allSchemas()
        selectedSchema = schema
        return schema
    }
}

// MARK: - Schema Editor View

/// Main schema editor interface
struct SchemaEditorView: View {
    @StateObject private var viewModel: SchemaEditorViewModel
    @State private var showingSaveSheet = false
    @State private var showingFilePicker = false
    @Environment(\.dismiss) private var dismiss

    /// Initialize with an optional document URL to load immediately
    init(documentURL: URL? = nil) {
        let vm = SchemaEditorViewModel()
        vm.initialURL = documentURL
        _viewModel = StateObject(wrappedValue: vm)
    }

    var body: some View {
        NavigationSplitView {
            // Sidebar with field list
            FieldListSidebar(viewModel: viewModel)
                .frame(minWidth: 250, idealWidth: 280)
        } detail: {
            // Main content with document preview
            HSplitView {
                // Document preview with overlay
                DocumentWithOverlay(viewModel: viewModel)
                    .frame(minWidth: 400)

                // Detected regions list
                DetectedRegionsList(viewModel: viewModel)
                    .frame(minWidth: 200, idealWidth: 250)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // Schema selector
                Picker("Schema", selection: $viewModel.selectedSchema) {
                    Text("Select Schema").tag(nil as InvoiceSchema?)
                    Divider()
                    ForEach(viewModel.availableSchemas) { schema in
                        Text(schema.name).tag(schema as InvoiceSchema?)
                    }
                }
                .frame(width: 200)
                .onChange(of: viewModel.selectedSchema) { _, _ in
                    Task {
                        await viewModel.classifyRegions()
                        viewModel.autoMapFields()
                    }
                }

                Button {
                    showingFilePicker = true
                } label: {
                    Label("Open Document", systemImage: "doc.badge.plus")
                }
                .help("Open a PDF or image document to create a schema from")

                Button {
                    viewModel.autoMapFields()
                } label: {
                    Label("Auto-Map", systemImage: "wand.and.stars")
                }
                .help("Automatically map detected text regions to schema fields")

                Button {
                    showingSaveSheet = true
                } label: {
                    Label("Save Schema", systemImage: "square.and.arrow.down")
                }
                .disabled(viewModel.fieldMappings.isEmpty)
                .help("Save the current field mappings as a reusable schema")
            }
        }
        .sheet(isPresented: $showingSaveSheet) {
            SaveSchemaSheet(viewModel: viewModel)
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.pdf, .png, .jpeg, .tiff],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                let hasAccess = url.startAccessingSecurityScopedResource()
                Task {
                    await viewModel.processDocument(at: url)
                    if hasAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
            }
        }
        .task {
            await viewModel.loadSchemas()
            // Load initial document if provided
            if let url = viewModel.initialURL {
                await viewModel.processDocument(at: url)
            }
        }
        .overlay {
            if viewModel.isLoading {
                ProgressView("Processing document...")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

// MARK: - Field List Sidebar

struct FieldListSidebar: View {
    @ObservedObject var viewModel: SchemaEditorViewModel

    var body: some View {
        List {
            Section("Required Fields") {
                ForEach(InvoiceFieldType.allCases.filter { $0.isRequired }) { fieldType in
                    FieldDropTarget(
                        fieldType: fieldType,
                        mapping: viewModel.fieldMappings[fieldType],
                        isHighlighted: viewModel.highlightedFieldType == fieldType,
                        onDrop: { region in
                            viewModel.mapRegion(region, to: fieldType)
                        },
                        onClear: {
                            viewModel.clearMapping(for: fieldType)
                        }
                    )
                }
            }

            Section("Header Fields") {
                ForEach(InvoiceFieldType.allCases.filter { !$0.isRequired && !$0.isLineItemField }) { fieldType in
                    FieldDropTarget(
                        fieldType: fieldType,
                        mapping: viewModel.fieldMappings[fieldType],
                        isHighlighted: viewModel.highlightedFieldType == fieldType,
                        onDrop: { region in
                            viewModel.mapRegion(region, to: fieldType)
                        },
                        onClear: {
                            viewModel.clearMapping(for: fieldType)
                        }
                    )
                }
            }

            Section("Line Item Fields") {
                ForEach(InvoiceFieldType.allCases.filter { $0.isLineItemField }) { fieldType in
                    FieldDropTarget(
                        fieldType: fieldType,
                        mapping: viewModel.fieldMappings[fieldType],
                        isHighlighted: viewModel.highlightedFieldType == fieldType,
                        onDrop: { region in
                            viewModel.mapRegion(region, to: fieldType)
                        },
                        onClear: {
                            viewModel.clearMapping(for: fieldType)
                        }
                    )
                }
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Field Drop Target

struct FieldDropTarget: View {
    let fieldType: InvoiceFieldType
    let mapping: DetectedTextRegion?
    let isHighlighted: Bool
    let onDrop: (DetectedTextRegion) -> Void
    let onClear: () -> Void

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
                    onClear()
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
                .fill(isHighlighted ? Color.accentColor.opacity(0.2) : (mapping != nil ? Color(nsColor: colorForFieldType(fieldType)).opacity(0.1) : Color.clear))
        )
        .dropDestination(for: DetectedTextRegionTransfer.self) { items, _ in
            guard let item = items.first else { return false }
            if let region = findRegion(for: item) {
                onDrop(region)
                return true
            }
            return false
        }
    }

    private func findRegion(for transfer: DetectedTextRegionTransfer) -> DetectedTextRegion? {
        // This would need access to the view model - we'll use a notification approach
        NotificationCenter.default.post(
            name: .findRegionForDrop,
            object: nil,
            userInfo: ["id": transfer.id, "fieldType": fieldType]
        )
        return nil
    }
}

extension Notification.Name {
    static let findRegionForDrop = Notification.Name("findRegionForDrop")
}

// MARK: - Document With Overlay

struct DocumentWithOverlay: View {
    @ObservedObject var viewModel: SchemaEditorViewModel

    var body: some View {
        Group {
            if let url = viewModel.documentURL {
                DocumentPreviewWithSchema(
                    url: url,
                    regions: viewModel.detectedRegions,
                    selectedRegion: $viewModel.selectedRegion,
                    onRegionTap: { region in
                        viewModel.selectedRegion = region
                    }
                )
            } else {
                ContentUnavailableView(
                    "No Document",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Use the toolbar button to open a document, or open Schema Editor from a Library document's detail view")
                )
            }
        }
    }
}

// MARK: - Document Preview With Schema Overlay

struct DocumentPreviewWithSchema: View {
    let url: URL
    let regions: [DetectedTextRegion]
    @Binding var selectedRegion: DetectedTextRegion?
    let onRegionTap: (DetectedTextRegion) -> Void

    @State private var pdfDocument: PDFDocument?

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    if url.pathExtension.lowercased() == "pdf" {
                        PDFViewer(
                            document: pdfDocument,
                            highlights: regions.map { region in
                                HighlightRegion(
                                    pageIndex: region.pageIndex,
                                    bounds: convertToPDFCoordinates(region.boundingBox, pageIndex: region.pageIndex),
                                    color: region.mappedFieldType.map { colorForFieldType($0).withAlphaComponent(0.4) } ?? NSColor.gray.withAlphaComponent(0.2),
                                    label: region.mappedFieldType?.displayName
                                )
                            }
                        )
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                    } else {
                        ImageWithSchemaOverlay(
                            url: url,
                            regions: regions,
                            selectedRegion: selectedRegion,
                            onRegionTap: onRegionTap
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

    private func convertToPDFCoordinates(_ box: NormalizedRegion, pageIndex: Int) -> CGRect {
        guard let pdf = pdfDocument,
              pageIndex < pdf.pageCount,
              let page = pdf.page(at: pageIndex) else {
            return box.cgRect
        }

        let pageBounds = page.bounds(for: .mediaBox)
        return CGRect(
            x: box.x * pageBounds.width,
            y: box.y * pageBounds.height,
            width: box.width * pageBounds.width,
            height: box.height * pageBounds.height
        )
    }
}

// MARK: - Image With Schema Overlay

struct ImageWithSchemaOverlay: View {
    let url: URL
    let regions: [DetectedTextRegion]
    let selectedRegion: DetectedTextRegion?
    let onRegionTap: (DetectedTextRegion) -> Void

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
                            SchemaRegionOverlay(
                                region: region,
                                imageSize: imageSize,
                                isSelected: selectedRegion?.id == region.id
                            )
                            .onTapGesture {
                                onRegionTap(region)
                            }
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

// MARK: - Schema Region Overlay

struct SchemaRegionOverlay: View {
    let region: DetectedTextRegion
    let imageSize: CGSize
    let isSelected: Bool

    var body: some View {
        let rect = convertToViewCoordinates(region.boundingBox, imageSize: imageSize)

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(fillColor.opacity(0.3))
                .frame(width: rect.width, height: rect.height)

            if isSelected || region.mappedFieldType != nil {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(strokeColor, lineWidth: isSelected ? 2 : 1)
                    .frame(width: rect.width, height: rect.height)
            }

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
        // Vision coordinates: origin at bottom-left, normalized 0-1
        // SwiftUI coordinates: origin at top-left
        let x = box.x * imageSize.width
        let y = (1 - box.y - box.height) * imageSize.height
        let width = box.width * imageSize.width
        let height = box.height * imageSize.height
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - Detected Regions List

struct DetectedRegionsList: View {
    @ObservedObject var viewModel: SchemaEditorViewModel

    var body: some View {
        List(selection: Binding(
            get: { viewModel.selectedRegion?.id },
            set: { id in
                viewModel.selectedRegion = viewModel.detectedRegions.first { $0.id == id }
            }
        )) {
            Section("Detected Text (\(viewModel.detectedRegions.count))") {
                ForEach(viewModel.detectedRegions) { region in
                    DetectedRegionRow(
                        region: region,
                        classification: viewModel.classificationResults[region.id]
                    )
                    .tag(region.id)
                    .draggable(DetectedTextRegionTransfer(id: region.id, text: region.text))
                }
            }
        }
        .listStyle(.plain)
    }
}

struct DetectedRegionRow: View {
    let region: DetectedTextRegion
    let classification: FieldClassificationResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(region.text)
                .font(.subheadline)
                .lineLimit(2)

            HStack(spacing: 8) {
                if let mapped = region.mappedFieldType {
                    Label(mapped.displayName, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: colorForFieldType(mapped)))
                } else if let classification = classification {
                    Label(classification.fieldType.displayName, systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("\(Int(classification.confidence * 100))%")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Text("\(Int(region.confidence * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Save Schema Sheet

struct SaveSchemaSheet: View {
    @ObservedObject var viewModel: SchemaEditorViewModel
    @Environment(\.dismiss) private var dismiss
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
                    saveSchema()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.newSchemaName.isEmpty || isSaving)
            }
        }
        .padding()
        .frame(width: 400, height: 400)
    }

    private func saveSchema() {
        isSaving = true
        errorMessage = nil

        Task {
            do {
                _ = try await viewModel.saveAsNewSchema()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}

// MARK: - Transfer Type for Drag and Drop

struct DetectedTextRegionTransfer: Codable, Transferable {
    let id: UUID
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

// MARK: - Color Helpers

func colorForFieldType(_ fieldType: InvoiceFieldType) -> NSColor {
    switch fieldType {
    case .invoiceNumber:
        return .systemPurple
    case .invoiceDate, .dueDate:
        return .systemBlue
    case .vendor, .vendorAddress:
        return .systemOrange
    case .customerName, .customerAddress:
        return .systemTeal
    case .subtotal, .tax, .total, .currency:
        return .systemGreen
    case .paymentTerms, .poNumber:
        return .systemIndigo
    case .lineItemDescription, .lineItemQuantity, .lineItemUnitPrice, .lineItemTotal:
        return .systemBrown
    }
}

// MARK: - Preview

#Preview {
    SchemaEditorView()
        .frame(width: 1200, height: 800)
}
