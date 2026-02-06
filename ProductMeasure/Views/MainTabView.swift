//
//  MainTabView.swift
//  ProductMeasure
//

import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            ARMeasurementView()
                .tabItem {
                    Label("Measure", systemImage: "viewfinder")
                }
                .tag(0)

            HistoryListView()
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .tag(1)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(2)
        }
        .tint(PMTheme.cyan)
    }
}

#Preview {
    MainTabView()
}
