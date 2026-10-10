import NukeUI
import SwiftUI

enum SeriesGrid {
    static let columns = [GridItem(.adaptive(minimum: 110, maximum: 170), spacing: 12)]
}

/// A cover with the title under it, as in Mihon's comfortable grid.
struct SeriesGridItem: View {
    let title: String
    let coverURL: URL?
    var inLibrary = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SeriesCover(url: coverURL)
                .opacity(inLibrary ? 0.45 : 1)
                .overlay(alignment: .topLeading) {
                    if inLibrary {
                        Text("In library")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.tint, in: .rect(cornerRadius: 4))
                            // Light text on the dark tint, dark text on dark mode's light tint.
                            .foregroundStyle(Color(uiColor: .systemBackground))
                            .padding(6)
                    }
                }
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(inLibrary ? Text("\(title), in library") : Text(title))
    }
}

struct SeriesCover: View {
    let url: URL?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                LazyImage(request: url.map { ImageRequest(url: $0, processors: [.resize(width: 340)]) }) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
                    } else if state.error != nil {
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    }
                }
            }
            .clipShape(.rect(cornerRadius: 8))
    }
}
