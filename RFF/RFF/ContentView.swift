import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var documents: [RFFDocument]

    var body: some View {
        NavigationSplitView {
            List {
                ForEach(documents) { document in
                    NavigationLink {
                        DocumentDetailView(document: document)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(document.title)
                                .font(.headline)
                            Text(document.requestingOrganization)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete(perform: deleteDocuments)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 250)
            .toolbar {
                ToolbarItem {
                    Button(action: addDocument) {
                        Label("Add Document", systemImage: "plus")
                    }
                }
            }
        } detail: {
            Text("Select a document")
        }
    }

    private func addDocument() {
        withAnimation {
            let newDocument = RFFDocument(
                title: "New Document",
                requestingOrganization: "Organization",
                amount: Decimal(0),
                dueDate: Date().addingTimeInterval(7 * 24 * 60 * 60)
            )
            modelContext.insert(newDocument)
        }
    }

    private func deleteDocuments(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(documents[index])
            }
        }
    }
}

struct DocumentDetailView: View {
    let document: RFFDocument

    var body: some View {
        Form {
            Section("Document Info") {
                LabeledContent("Title", value: document.title)
                LabeledContent("Organization", value: document.requestingOrganization)
                LabeledContent("Amount", value: document.amount, format: .currency(code: "USD"))
                LabeledContent("Due Date", value: document.dueDate, format: .dateTime)
                LabeledContent("Status", value: document.status.rawValue.capitalized)
            }

            if let extractedText = document.extractedText, !extractedText.isEmpty {
                Section("Extracted Text") {
                    Text(extractedText)
                        .font(.body)
                }
            }

            Section("Line Items") {
                if document.lineItems.isEmpty {
                    Text("No line items")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(document.lineItems) { item in
                        HStack {
                            Text(item.itemDescription)
                            Spacer()
                            Text(item.total, format: .currency(code: "USD"))
                        }
                    }
                }
            }
        }
        .padding()
        .navigationTitle(document.title)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: RFFDocument.self, inMemory: true)
}
