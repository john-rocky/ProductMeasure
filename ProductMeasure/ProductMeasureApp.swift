//
//  ProductMeasureApp.swift
//  ProductMeasure
//
//  iOS 17+ 3D object measurement app using ARKit + LiDAR
//

import SwiftUI
import SwiftData

@main
struct ProductMeasureApp: App {

    init() {
        LabelReaderService.warmup()
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            ProductMeasurement.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .preferredColorScheme(.dark)
                .tint(PMTheme.cyan)
        }
        .modelContainer(sharedModelContainer)
    }
}
