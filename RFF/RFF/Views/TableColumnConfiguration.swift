import SwiftUI
import AppKit

/// Identifiers for table columns that can be shown/hidden
enum LibraryColumn: String, CaseIterable, Identifiable {
    case recipient = "Recipient"
    case from = "From"
    case amount = "Amount"
    case currency = "Currency"
    case dueDate = "Due Date"
    case status = "Status"

    var id: String { rawValue }

    /// Whether this column can be hidden
    var canHide: Bool {
        true
    }
}

/// Manages column visibility preferences for the Library table
class LibraryColumnConfiguration: ObservableObject {
    static let shared = LibraryColumnConfiguration()

    private let visibilityKey = "libraryColumnVisibility"

    /// Set of hidden column identifiers
    @Published var hiddenColumns: Set<String> {
        didSet {
            saveToUserDefaults()
        }
    }

    private init() {
        if let saved = UserDefaults.standard.array(forKey: visibilityKey) as? [String] {
            hiddenColumns = Set(saved)
        } else {
            hiddenColumns = []
        }
    }

    private func saveToUserDefaults() {
        UserDefaults.standard.set(Array(hiddenColumns), forKey: visibilityKey)
    }

    func isVisible(_ column: LibraryColumn) -> Bool {
        !hiddenColumns.contains(column.rawValue)
    }

    func toggle(_ column: LibraryColumn) {
        if hiddenColumns.contains(column.rawValue) {
            hiddenColumns.remove(column.rawValue)
        } else {
            hiddenColumns.insert(column.rawValue)
        }
    }

    func setVisible(_ column: LibraryColumn, visible: Bool) {
        if visible {
            hiddenColumns.remove(column.rawValue)
        } else {
            hiddenColumns.insert(column.rawValue)
        }
    }
}

/// View modifier that adds a column visibility context menu to NSTableView headers
/// and syncs column visibility with LibraryColumnConfiguration
struct TableColumnVisibilityModifier: NSViewRepresentable {
    @ObservedObject var configuration: LibraryColumnConfiguration

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Use async to let SwiftUI Table finish setup
        DispatchQueue.main.async {
            self.setupTableView(from: nsView)
        }
    }

    private func setupTableView(from view: NSView) {
        guard let window = view.window,
              let tableView = findTableView(in: window.contentView) else {
            return
        }

        // Create and set the header context menu
        let menu = createColumnMenu(for: tableView)
        tableView.headerView?.menu = menu

        // Apply current visibility settings
        applyColumnVisibility(to: tableView)
    }

    private func createColumnMenu(for tableView: NSTableView) -> NSMenu {
        let menu = NSMenu(title: "Columns")

        for column in LibraryColumn.allCases {
            let item = NSMenuItem(
                title: column.rawValue,
                action: #selector(ColumnMenuHandler.toggleColumn(_:)),
                keyEquivalent: ""
            )
            item.representedObject = ColumnToggleInfo(
                columnId: column.rawValue,
                tableView: tableView,
                configuration: configuration
            )
            item.state = configuration.isVisible(column) ? .on : .off
            item.isEnabled = column.canHide
            item.target = ColumnMenuHandler.shared
            menu.addItem(item)
        }

        return menu
    }

    private func applyColumnVisibility(to tableView: NSTableView) {
        for tableColumn in tableView.tableColumns {
            let columnTitle = tableColumn.title
            if let column = LibraryColumn(rawValue: columnTitle) {
                tableColumn.isHidden = !configuration.isVisible(column)
            }
        }
    }

    private func findTableView(in view: NSView?) -> NSTableView? {
        guard let view = view else { return nil }

        if let tableView = view as? NSTableView {
            return tableView
        }

        for subview in view.subviews {
            if let found = findTableView(in: subview) {
                return found
            }
        }

        return nil
    }
}

/// Info passed to menu handler for column toggle
private class ColumnToggleInfo {
    let columnId: String
    weak var tableView: NSTableView?
    let configuration: LibraryColumnConfiguration

    init(columnId: String, tableView: NSTableView, configuration: LibraryColumnConfiguration) {
        self.columnId = columnId
        self.tableView = tableView
        self.configuration = configuration
    }
}

/// Singleton handler for column menu actions
private class ColumnMenuHandler: NSObject {
    static let shared = ColumnMenuHandler()

    @objc func toggleColumn(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? ColumnToggleInfo,
              let column = LibraryColumn(rawValue: info.columnId),
              column.canHide else { return }

        // Toggle in configuration
        info.configuration.toggle(column)

        // Update menu item state
        sender.state = info.configuration.isVisible(column) ? .on : .off

        // Update table column visibility
        if let tableView = info.tableView {
            for tableColumn in tableView.tableColumns {
                if tableColumn.title == info.columnId {
                    tableColumn.isHidden = !info.configuration.isVisible(column)
                    break
                }
            }
        }
    }
}

/// View modifier extension for easy use
extension View {
    func tableColumnVisibility(configuration: LibraryColumnConfiguration) -> some View {
        self.background(
            TableColumnVisibilityModifier(configuration: configuration)
                .frame(width: 1, height: 1)
        )
    }
}
