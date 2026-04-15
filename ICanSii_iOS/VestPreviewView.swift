import SwiftUI

struct VestPreviewView: View {
    @ObservedObject var transport: PreviewTransport
    @State private var showBack: Bool = false

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("TactSuit X40 Preview")
                    .font(.title2.weight(.bold))
                Text(showBack ? "Back" : "Front")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Toggle("Show Back", isOn: $showBack)
                .toggleStyle(.switch)
                .padding(.horizontal)

            faceGrid(isBack: showBack)
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.black.opacity(0.78))
                )

            legend
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [Color(red: 0.04, green: 0.06, blue: 0.08), Color(red: 0.14, green: 0.16, blue: 0.19)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .foregroundStyle(.white)
    }

    private func faceGrid(isBack: Bool) -> some View {
        VStack(spacing: 8) {
            ForEach(0..<VestLayout.rowsPerFace, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(0..<VestLayout.colsPerFace, id: \.self) { col in
                        cellView(isBack: isBack, row: row, col: col)
                    }
                }
            }
        }
    }

    private func cellView(isBack: Bool, row: Int, col: Int) -> some View {
        let id = VestLayout.cellID(isBack: isBack, row: row, column: col)
        let intensity = min(max(transport.state.cells[id] ?? 0, 0), 1)

        return RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(color(for: intensity))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
            .frame(width: 42, height: 28)
            .animation(.easeOut(duration: 0.12), value: intensity)
    }

    private func color(for intensity: Float) -> Color {
        // Hue: 0 (red) to ~0.16 (yellow)
        let hue = 0.16 * Double(max(0, min(1, intensity)))
        let brightness = 0.25 + 0.75 * Double(max(0, min(1, intensity)))
        return Color(hue: hue, saturation: 1.0, brightness: brightness)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            Text("Low")
                .font(.caption)
                .foregroundStyle(.secondary)
            LinearGradient(
                colors: [.red, .yellow],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 140, height: 8)
            .clipShape(Capsule())
            Text("High")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
