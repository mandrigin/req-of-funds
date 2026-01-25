import Foundation
import SwiftData

/// Schema versioning for RFF data model migrations
enum RFFSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [RFFDocument.self, LineItem.self]
    }
}

/// Migration plan for handling schema upgrades
enum RFFMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [RFFSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        // No migrations yet - this is V1
        // Future migrations will be added here as:
        // .lightweight(fromVersion: RFFSchemaV1.self, toVersion: RFFSchemaV2.self)
        // or
        // .custom(fromVersion: RFFSchemaV1.self, toVersion: RFFSchemaV2.self) { context in ... }
        []
    }
}
