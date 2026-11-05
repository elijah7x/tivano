import SwiftUI

struct ChimeraMarkImage: View {
    var body: some View {
        Image("chimera-mark")
            .resizable()
            .renderingMode(.template)
            .aspectRatio(contentMode: .fit)
    }
}
