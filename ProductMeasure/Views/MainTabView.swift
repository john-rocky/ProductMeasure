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
                    Label("Measure", systemImage: "ruler")
                }
                .tag(0)

            HistoryListView()
                .tabItem {
                    Label("History", systemImage: "clock")
                }
                .tag(1)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(2)
        }
    }
}

#Preview {
    MainTabView()
}
