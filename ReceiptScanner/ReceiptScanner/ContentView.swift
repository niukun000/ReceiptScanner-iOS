import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            NavigationStack {
                ScanView()
            }
            .tabItem {
                Label("Scan", systemImage: "doc.text.viewfinder")
            }
            
            NavigationStack {
                HistoryView()
            }
            .tabItem {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
        }
    }
}
