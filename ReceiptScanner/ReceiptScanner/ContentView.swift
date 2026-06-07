import SwiftUI

enum Route: Hashable {
    case scan
    case history
}

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

struct MenuButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right")
            }
            .font(.headline).padding().background(Color(.secondarySystemBackground)).cornerRadius(12)
        }
    }
}
