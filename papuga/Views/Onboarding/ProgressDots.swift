import SwiftUI

struct ProgressDots: View {
    let total: Int
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<total, id: \.self) { index in
                Circle()
                    .fill(index < current ? Color("BrandAccent") : Color.gray.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
    }
}
