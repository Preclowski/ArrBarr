import SwiftUI

/// The person card the chat shows for a name query, and above a filmography.
///
/// Deliberately minimal — headshot, name, department, life dates. No bio, no
/// links, no credits: this is a signpost to `PersonView`, which already renders
/// all of that properly, and a chat bubble is the wrong place to duplicate it.
/// Full width rather than a poster-sized tile, because a person is the *subject*
/// of the answer here, not one of a dozen options in a rail.
struct ChatPersonCardView: View {
    let person: ChatPerson

    @State private var hovering = false

    var body: some View {
        Button {
            PersonRequest.post(person.ref)
        } label: {
            HStack(spacing: 10) {
                RemotePoster(
                    url: person.profileURL,
                    apiKey: nil,
                    tier: .card,
                    size: CGSize(width: 44, height: 44),
                    cornerRadius: 22,
                    fallbackSymbol: "person.fill"
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name)
                        .scaledFont(size: 13, weight: .semibold)
                        .lineLimit(1)
                    if let subtitle {
                        Text(verbatim: subtitle)
                            .scaledFont(size: 11)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .scaledFont(size: 10, weight: .semibold)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(hovering ? 0.10 : 0.06),
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.card))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// "Acting · 1966" — department and life dates, whichever of them TMDB
    /// actually knows. Search rows carry no dates, so this is often just the
    /// department, and that is fine.
    private var subtitle: String? {
        let bits = [person.knownForDepartment?.localizedDepartment, person.lifespan].compactMap { $0 }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }
}

private extension String {
    /// TMDB departments arrive as fixed English tokens ("Acting", "Directing").
    /// Map the handful that actually show up; anything else passes through
    /// verbatim rather than being dropped.
    var localizedDepartment: String {
        switch self {
        case "Acting":     return String(localized: "person.department.acting", bundle: .module)
        case "Directing":  return String(localized: "person.department.directing", bundle: .module)
        case "Writing":    return String(localized: "person.department.writing", bundle: .module)
        case "Production": return String(localized: "person.department.production", bundle: .module)
        case "Sound":      return String(localized: "person.department.sound", bundle: .module)
        case "Camera":     return String(localized: "person.department.camera", bundle: .module)
        default:           return self
        }
    }
}
