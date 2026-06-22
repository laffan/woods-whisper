import SwiftUI

/// A thin horizontal audio level bar (0...1). Shared by the iOS and watchOS record screens.
public struct LevelMeter: View {
    private let level: Float

    public init(level: Float) {
        self.level = level
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.red).frame(width: geo.size.width * CGFloat(level))
            }
        }
        .frame(height: 6)
        .padding(.horizontal)
    }
}
