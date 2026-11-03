import SwiftUI
import TepfaCore

/// Download-only update sheet for unsigned builds.
struct UpdateAvailableView: View {
    let item: Appcast.Item
    @Environment(UpdateManager.self) private var updates

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Tepfasonic \(item.shortVersion) is available", systemImage: "arrow.down.circle.fill")
                .font(.title3.weight(.semibold))
            Text("You have \(UpdateManager.currentShortVersion). This build cannot update itself, so the new version is downloaded with your browser; drag it into Applications to replace this copy.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            if let notes = releaseNotes {
                ScrollView {
                    Text(notes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 220)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            } else if let link = item.releaseNotesURL {
                Link("Release notes", destination: link)
            }
            HStack {
                Button("Skip This Version") { updates.skip(item) }
                Spacer()
                Button("Later") { updates.availableUpdate = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Download") { updates.download(item) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(item.downloadURL == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var releaseNotes: AttributedString? {
        guard let html = item.releaseNotesHTML, let data = html.data(using: .utf8) else { return nil }
        guard let attributed = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil) else { return nil }
        var result = AttributedString(attributed)
        result.foregroundColor = nil
        result.font = nil
        return result
    }
}
