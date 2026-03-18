//
//  SnapMeasureApp.swift
//  SnapMeasure
//
//  iOS 17+ 3D object measurement app using ARKit + LiDAR
//

import SwiftUI
import SwiftData

@main
struct SnapMeasureApp: App {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

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
                .fullScreenCover(isPresented: Binding(
                    get: { !hasCompletedOnboarding },
                    set: { if !$0 { hasCompletedOnboarding = true } }
                )) {
                    OnboardingView()
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
