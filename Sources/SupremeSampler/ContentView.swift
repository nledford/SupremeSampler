import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.stack")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("SupremeSampler")
                .font(.title2)
                .bold()
            Text("Scaffold placeholder — rule builder and script preview go here.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 480, minHeight: 320)
        .padding()
    }
}

#Preview {
    ContentView()
}
