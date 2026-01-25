import Foundation
import SwiftData

/// Schema versioning for RFF data model migrations

/// V1 Schema - Initial version
enum RFFSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [RFFDocument.self, LineItem.self]
    }
}

/// V2 Schema - Added multi-currency support
/// - Added `currency` field to RFFDocument (defaults to .usd)
enum RFFSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [RFFDocument.self, LineItem.self]
    }
}

/// Migration plan for handling schema upgrades
enum RFFMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [RFFSchemaV1.self, RFFSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2]
    }

    /// Lightweight migration from V1 to V2
    /// The `currency` field has a default value, so SwiftData can handle this automatically
    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: RFFSchemaV1.self,
        toVersion: RFFSchemaV2.self
    )
}
