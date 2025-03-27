import SwiftUI

struct TraditionalCross: View {
    // Configurable parameters
    let width: CGFloat
    let color: Color
    let shadowColor: Color
    
    // Computed properties for maintaining proportions
    private var height: CGFloat { width * (8/5) }
    private var thickness: CGFloat { width / 5 }
    private var horizontalPosition: CGFloat { height * 0.2 }
    
    // Initializer with default values
    init(
        width: CGFloat = 200, 
        color: Color = .white, 
        shadowColor: Color = .white.opacity(0.2)
    ) {
        self.width = width
        self.color = color
        self.shadowColor = shadowColor
    }
    
    var body: some View {
        ZStack {
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
    }
}