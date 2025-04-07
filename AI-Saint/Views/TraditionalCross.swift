import SwiftUI

struct TraditionalCross: View {
    // Configurable parameters
    let width: CGFloat
    let color: Color
    let shadowColor: Color
    var isAnimating: Bool = false
    
    // Computed properties for maintaining proportions
    private var height: CGFloat { width * (8/5) }
    private var thickness: CGFloat { width / 5 }
    private var horizontalPosition: CGFloat { height * 0.2 }
    
    // Animation state
    @State private var glowIntensity: CGFloat = 0.0
    
    // Initializer with default values
    init(
        width: CGFloat = 200, 
        color: Color = .white, 
        shadowColor: Color = .white.opacity(0.2),
        isAnimating: Bool = false
    ) {
        self.width = width
        self.color = color
        self.shadowColor = shadowColor
        self.isAnimating = isAnimating
    }
    
    var body: some View {
        ZStack {
            // Glow effect
            if isAnimating {
                ZStack {
                    // Vertical beam glow
                    Rectangle()
                        .fill(color)
                        .frame(width: thickness * (1 + glowIntensity * 0.8), height: height * (1 + glowIntensity * 0.3))
                        .blur(radius: 15 * glowIntensity)
                        .opacity(0.7 * glowIntensity)
                    
                    // Horizontal beam glow
                    Rectangle()
                        .fill(color)
                        .frame(width: width * (1 + glowIntensity * 0.3), height: thickness * (1 + glowIntensity * 0.8))
                        .offset(y: -height/2 + horizontalPosition + thickness/2)
                        .blur(radius: 15 * glowIntensity)
                        .opacity(0.7 * glowIntensity)
                }
            }
            
            // Vertical beam
            Rectangle()
                .fill(color)
                .frame(width: thickness, height: height)
            
            // Horizontal beam
            Rectangle()
                .fill(color)
                .frame(width: width, height: thickness)
                .offset(y: -height/2 + horizontalPosition + thickness/2)
        }
        .frame(width: width, height: height)
        .shadow(color: shadowColor, radius: 4)
        .compositingGroup() // For better shadow rendering
        .onAppear {
            if isAnimating {
                withAnimation(Animation.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                    glowIntensity = 1.0
                }
            }
        }
    }
}

// MARK: - Preview
#Preview {
    VStack(spacing: 30) {
        TraditionalCross(width: 120, color: .yellow, shadowColor: .yellow.opacity(0.3), isAnimating: true)
        
        TraditionalCross(width: 120, color: .red, shadowColor: .red.opacity(0.3))
        
        TraditionalCross(width: 60, color: .blue, shadowColor: .blue.opacity(0.3))
    }
    .padding()
    .background(Color.black)
}