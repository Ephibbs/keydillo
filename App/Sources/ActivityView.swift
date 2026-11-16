import SwiftUI
import VaultCore

struct ActivityView: View {
  @Environment(AppModel.self) private var model
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Activity").font(.system(size: 22, weight: .semibold)).padding(.top, 34)
      if model.events.isEmpty {
        Text("Requests through keydillo show up here.").font(.system(size: 13)).foregroundStyle(Theme.secondary)
      }
      ScrollView {
        VStack(spacing: 0) {
          ForEach(model.events) { e in
            HStack(spacing: 12) {
              Text(e.date, format: .dateTime.hour().minute().second()).foregroundStyle(Theme.secondary).frame(width: 74, alignment: .leading)
              Text(sentence(e)).lineLimit(1).truncationMode(.middle)
              Spacer()
              Text(e.outcome == .sent ? "\(e.status)" : e.outcome.rawValue.capitalized)
                .foregroundStyle(e.outcome == .sent ? Theme.text : Theme.danger)
            }
            .font(.system(size: 13)).frame(height: 36)
            Divider().overlay(Theme.hairline)
          }
        }
      }
    }
    .padding(.horizontal, 26)
  }

  func sentence(_ e: ActivityEvent) -> String {
    let svc = model.service(named: e.service)?.displayName ?? e.service
    let base = "\(e.process) → \(svc): \(e.method) \(e.path)"
    return e.note.map { "\(base) · \($0)" } ?? base
  }
}
