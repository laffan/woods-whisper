import SwiftUI

/// A thin horizontal audio level bar (0...1). Shared by the iOS and watchOS record screens.
/// Draws in the environment tint color, so callers set the mood with `.tint(...)`.
public struct LevelMeter: View {
    private let level: Float

    public init(level: Float) {
        self.level = level
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.tint).frame(width: geo.size.width * CGFloat(level))
            }
        }
        .frame(height: 4)
        .padding(.horizontal)
        .animation(.linear(duration: 0.08), value: level)
    }
}
