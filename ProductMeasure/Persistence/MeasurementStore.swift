//
//  MeasurementStore.swift
//  ProductMeasure
//

import Foundation
import SwiftData

/// Manager for SwiftData persistence operations
@MainActor
class MeasurementStore: ObservableObject {
    private let modelContainer: ModelContainer
    private let modelContext: ModelContext

    init() {
        do {
            let schema = Schema([
                ProductMeasurement.self,
            ])
            let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            modelContainer = try ModelContainer(for: schema, configurations: [modelConfiguration])
            modelContext = modelContainer.mainContext
        } catch {
            fatalError("Could not initialize ModelContainer: \(error)")
        }
    }

    // MARK: - CRUD Operations

    func save(_ measurement: ProductMeasurement) {
        modelContext.insert(measurement)
        try? modelContext.save()
    }

    func delete(_ measurement: ProductMeasurement) {
        modelContext.delete(measurement)
        try? modelContext.save()
    }

    func fetchAll() -> [ProductMeasurement] {
        let descriptor = FetchDescriptor<ProductMeasurement>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )

        do {
            return try modelContext.fetch(descriptor)
        } catch {
            print("Failed to fetch measurements: \(error)")
            return []
        }
    }

    func fetch(limit: Int) -> [ProductMeasurement] {
        var descriptor = FetchDescriptor<ProductMeasurement>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit

        do {
            return try modelContext.fetch(descriptor)
        } catch {
            print("Failed to fetch measurements: \(error)")
            return []
        }
    }

    func deleteAll() {
        do {
            try modelContext.delete(model: ProductMeasurement.self)
            try modelContext.save()
        } catch {
            print("Failed to delete all measurements: \(error)")
        }
    }

    // MARK: - Statistics

    func count() -> Int {
        let descriptor = FetchDescriptor<ProductMeasurement>()
        do {
            return try modelContext.fetchCount(descriptor)
        } catch {
            return 0
        }
    }
}
