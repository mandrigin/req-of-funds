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

/// V3 Schema - Added schema association
/// - Added `schemaId` field to RFFDocument for tracking which extraction schema is used
enum RFFSchemaV3: VersionedSchema {
    static var versionIdentifier = Schema.Version(3, 0, 0)

    static var models: [any PersistentModel.Type] {
        [RFFDocument.self, LineItem.self]
    }
}

/// Migration plan for handling schema upgrades
enum RFFMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [RFFSchemaV1.self, RFFSchemaV2.self, RFFSchemaV3.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3]
    }

    /// Lightweight migration from V1 to V2
    /// The `currency` field has a default value, so SwiftData can handle this automatically
    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: RFFSchemaV1.self,
        toVersion: RFFSchemaV2.self
    )

    /// Lightweight migration from V2 to V3
    /// The `schemaId` field is optional (nil by default), so SwiftData handles this automatically
    static let migrateV2toV3 = MigrationStage.lightweight(
        fromVersion: RFFSchemaV2.self,
        toVersion: RFFSchemaV3.self
    )
}
