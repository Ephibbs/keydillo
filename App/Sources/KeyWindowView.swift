import SwiftUI
import AppKit
import VaultCore

/// The window that collects a key: opened by the user ("Add key") or by an agent (request_secret).
struct KeyWindowView: View {
  @Environment(AppModel.self) private var model
  let windowID: String
  @State var request: KeyRequest
  @State private var secret = ""
  @State private var optionsOpen = false
  @State private var approval: DefaultApproval
  @State private var error: String?
  @State private var saved: ServiceConfig?
  @State private var busy = false
  @State private var promptCopied = false
  static let samplePrompt = "Add my Stripe key with keydillo"

  init(request: KeyRequest, windowID: String) {
    self.windowID = windowID
    _request = State(initialValue: request)
    _approval = State(initialValue: AppModel.shared.defaultApproval)
    // A manual add has nothing filled in yet, so start with the details open.
    _optionsOpen = State(initialValue: request.host.isEmpty)
  }

  var body: some View {
    Group {
      if let saved { SavedView(config: saved, fromAgent: request.fromAgent) { close() } }
      else { form }
    }
    .sheetCard()
  }

  var title: String {
    if request.fromAgent { return "\(requesterName) wants to use your \(request.displayName) key" }
    return request.displayName.isEmpty ? "Add a key" : "Add your \(request.displayName) key"
  }

  /// The agent-supplied page where this key is created. https only (also checked when the request arrived).
  var keyPage: URL? {
    guard let u = URL(string: request.keyPageURL), u.scheme == "https", u.host != nil, u.user == nil else { return nil }
    return u
  }

  @ViewBuilder func keyPageLink(_ page: URL) -> some View {
    let related = HostCheck.keyPageRelated(page, service: request.service, apiHost: request.host)
    let shown = page.host ?? ""   // the domain is what matters; the full address is in the tooltip
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Image(systemName: related ? "key" : "exclamationmark.triangle").font(.system(size: 11, weight: .semibold))
          .foregroundStyle(related ? Theme.secondary : Theme.danger)
        Text("Don't have one? Create it at").foregroundStyle(Theme.tertiary)
        Link(destination: page) {
          HStack(spacing: 2) {
            Text(shown).lineLimit(1).truncationMode(.middle)
            Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
          }
          .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).underline()
        }
        .help(page.absoluteString)
      }
      .font(.system(size: 13))
      if !related {
        Text("This page isn't on \(HostCheck.site(request.host)). Check the address before you sign in there.")
          .font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  var requesterName: String {
    let r = request.requester ?? "An agent"
    return r.prefix(1).uppercased() + r.dropFirst()
  }

  var form: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.system(size: 20, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
        Text("Your key is encrypted. \(request.fromAgent ? requesterName : "AI tools") never \(request.fromAgent ? "sees" : "see") it.")
          .font(.system(size: 14)).foregroundStyle(Theme.secondary)
      }

      if !request.fromAgent && request.service.isEmpty {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: "sparkles").font(.system(size: 13)).foregroundStyle(Theme.tertiary).padding(.top, 1)
          VStack(alignment: .leading, spacing: 6) {
            Text("Easier: ask Claude to add it for you. It fills in the settings; you just paste the key.")
              .font(.system(size: 13)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
              Text("\u{201C}\(Self.samplePrompt)\u{201D}").font(.system(size: 12)).foregroundStyle(Theme.secondary)
              Button(promptCopied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(Self.samplePrompt, forType: .string); promptCopied = true
              }
              .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
            }
          }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
      }

      VStack(alignment: .leading, spacing: 8) {
        FilledField(placeholder: "Paste your key", text: $secret, secure: true, height: 44, emphasized: true)
          .accessibilityLabel("\(request.displayName) API key")
        if !request.host.isEmpty {
          HStack(spacing: 6) {
            let verdict = HostCheck.verdict(service: request.service, name: request.displayName, host: request.host)
            Image(systemName: verdict == .known ? "checkmark" : verdict == .mismatch ? "exclamationmark.triangle" : "info.circle")
              .font(.system(size: 11, weight: .bold))
              .foregroundStyle(verdict == .known ? Theme.success : verdict == .mismatch ? Theme.danger : Theme.secondary)
            Text("Only ever sent to").foregroundStyle(Theme.tertiary)
            Text(request.host).font(.system(size: 13, weight: .semibold, design: .monospaced))
          }
          .font(.system(size: 13))
          if let warning = HostCheck.warning(service: request.service, name: request.displayName, host: request.host) {
            Text(warning).font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
          }
        }
        if request.fromAgent, let page = keyPage { keyPageLink(page) }
      }

      if let old = model.service(named: request.service), old.project == request.project,
         old.upstreamHost.lowercased() != request.host.lowercased(), !request.host.isEmpty {
        Text("This replaces \(old.displayName)'s address: \(old.upstreamHost) → \(request.host). Only save if you expected that.")
          .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
      }

      Collapsible(title: "Options", isOpen: $optionsOpen) { options }

      if !model.storageSecure {
        Text(AppModel.insecureMessage).font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
      }

      if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }

      HStack(spacing: 8) {
        Spacer()
        Button(request.fromAgent ? "Decline" : "Cancel") { close() }.buttonStyle(SecondaryButtonStyle())
        Button("Save with Touch ID") { Task { await save() } }
          .buttonStyle(PrimaryButtonStyle())
          .keyboardShortcut(.defaultAction)
          .disabled(busy || secret.isEmpty)
      }
      .padding(.top, 4)
    }
  }

  var options: some View {
    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
      if !request.fromAgent && request.service.isEmpty {
        row("Name") { FilledField(placeholder: "ElevenLabs", text: $request.displayName, height: 32) }
        row("Host") { FilledField(placeholder: "api.example.com", text: $request.host, monospaced: true, height: 32) }
      }
      row("Project") {
        Picker("", selection: $request.project) {
          ForEach(Array(Set(model.projects + [request.project])).sorted(), id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
      }
      row("Header") { FilledField(placeholder: "Authorization", text: $request.header, monospaced: true, height: 32) }
      row("Prefix") { FilledField(placeholder: "Bearer (optional)", text: $request.prefix, monospaced: true, height: 32) }
      row("Env name") { FilledField(placeholder: "EXAMPLE_API_KEY", text: $request.envVarName, monospaced: true, height: 32) }
      row("Key page") { FilledField(placeholder: "https://… where you manage this key", text: $request.keyPageURL, height: 32) }
      if let r = request.requester {
        row("Asked by") {
          Text("\(r)\(request.cwd.map { " in " + ($0 as NSString).abbreviatingWithTildeInPath } ?? "")")
            .font(.system(size: 13)).foregroundStyle(Theme.tertiary)
        }
      }
    }
    .font(.system(size: 13))
  }

  func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
    GridRow {
      Text(label).foregroundStyle(Theme.secondary).frame(width: 90, alignment: .leading)
      content()
    }
  }

  func save() async {
    busy = true; defer { busy = false }
    var name = request.service.isEmpty
      ? request.displayName.lowercased().replacingOccurrences(of: " ", with: "-").filter { $0.isLetter || $0.isNumber || $0 == "-" }
      : request.service
    // Another project already has a key under this name: give this one its own address instead of replacing it.
    if let existing = model.service(named: name), existing.project != request.project {
      let base = name + "-" + request.project.lowercased().filter { $0.isLetter || $0.isNumber }
      var candidate = base; var i = 2
      while let other = model.service(named: candidate), other.project != request.project { candidate = "\(base)-\(i)"; i += 1 }
      name = candidate
    }
    var cfg = ServiceConfig(name: name, displayName: request.displayName.isEmpty ? name.capitalized : request.displayName,
                            project: request.project, upstreamHost: request.host.trimmingCharacters(in: .whitespaces),
                            authHeader: request.header.trimmingCharacters(in: .whitespaces), authPrefix: request.prefix,
                            envVarName: request.envVarName.isEmpty ? nil : request.envVarName, approval: approval.mode)
    cfg.keyPageURL = request.keyPageURL.isEmpty ? nil : request.keyPageURL
    if let conv = ImportScanner.convention(for: name) {
      cfg.sdkBasePath = conv.path.isEmpty ? nil : conv.path
      cfg.baseURLEnvName = conv.env
    }
    cfg.folder = request.cwd ?? model.service(named: name)?.folder
    do {
      if try await model.save(cfg, secret: secret) {
        secret = ""
        error = nil
        withAnimation(.easeInOut(duration: 0.15)) { saved = cfg }
        model.finishKeyRequest(request.id, saved: cfg)
      }
    } catch {
      self.error = error.localizedDescription
    }
  }

  func close() { WindowManager.shared.close(windowID) }
}

struct SavedView: View {
  @Environment(AppModel.self) private var model
  let config: ServiceConfig
  let fromAgent: Bool
  var done: () -> Void
  @State private var receivedOpen = false
  @State private var settingsOpen = false

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Image(systemName: "checkmark").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.onPrimary)
        .frame(width: 40, height: 40).background(Circle().fill(Theme.primary))
      VStack(alignment: .leading, spacing: 6) {
        Text("Saved").font(.system(size: 20, weight: .semibold))
        Text("\(fromAgent ? "Claude" : "AI tools") can use \(config.displayName) now. \(config.approval.label.replacingOccurrences(of: "Touch ID", with: "You'll approve with Touch ID")).")
          .font(.system(size: 14)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
      }
      VStack(alignment: .leading, spacing: 10) {
        Collapsible(title: fromAgent ? "What Claude received" : "Use it in a project", isOpen: $receivedOpen) {
          let s = model.summary(config)
          Text(s.placeholderEnvLines.joined(separator: "\n"))
            .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
        }
        Collapsible(title: "Settings", isOpen: $settingsOpen) {
          Toggle("Open keydillo when you log in", isOn: Binding(get: { model.openAtLogin }, set: { model.openAtLogin = $0 }))
            .toggleStyle(.switch).font(.system(size: 13))
        }
      }
      HStack { Spacer(); Button("Done", action: done).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction) }
    }
  }
}

/// Warns when an agent-supplied host doesn't match a service's known domain.
enum HostCheck {
  static let known: [String: [String]] = [
    "elevenlabs": ["elevenlabs.io"], "openai": ["openai.com"], "anthropic": ["anthropic.com"],
    "stripe": ["stripe.com"], "github": ["github.com"], "resend": ["resend.com"], "posthog": ["posthog.com"],
    "revenuecat": ["revenuecat.com"], "supabase": ["supabase.co", "supabase.com"], "google": ["googleapis.com"],
    "gemini": ["googleapis.com"], "replicate": ["replicate.com"], "mistral": ["mistral.ai"], "groq": ["groq.com"],
    "cloudflare": ["cloudflare.com"], "vercel": ["vercel.com"], "twilio": ["twilio.com"], "sendgrid": ["sendgrid.com"],
    "deepgram": ["deepgram.com"], "cohere": ["cohere.com", "cohere.ai"], "perplexity": ["perplexity.ai"],
  ]
  static let names: [String: String] = [
    "elevenlabs": "ElevenLabs", "openai": "OpenAI", "anthropic": "Anthropic", "stripe": "Stripe", "github": "GitHub",
    "resend": "Resend", "posthog": "PostHog", "revenuecat": "RevenueCat", "supabase": "Supabase", "gemini": "Gemini",
    "replicate": "Replicate", "mistral": "Mistral", "groq": "Groq", "cloudflare": "Cloudflare", "vercel": "Vercel",
    "twilio": "Twilio", "sendgrid": "SendGrid", "deepgram": "Deepgram", "cohere": "Cohere", "perplexity": "Perplexity",
  ]
  static func displayName(_ service: String) -> String { names[service.lowercased()] ?? service.capitalized }

  static func domains(_ service: String) -> [String]? {
    known.first { service.lowercased().contains($0.key) }?.value
  }
  enum Verdict { case known, unknown, mismatch }

  /// known: the host is in the brand's own domains. mismatch: the service, name or host mentions a brand but the
  /// host isn't one of its domains. unknown: we don't know this service, so no green check.
  static func verdict(service: String, name: String, host: String) -> Verdict {
    let h = host.lowercased().split(separator: ":").first.map(String.init) ?? host.lowercased()
    let text = (service + " " + name + " " + h).lowercased().replacingOccurrences(of: " ", with: "")
    let brands = known.filter { text.contains($0.key) }
    guard !brands.isEmpty else { return .unknown }
    let inDomain = brands.contains { $0.value.contains { h == $0 || h.hasSuffix("." + $0) } }
    return inDomain ? .known : .mismatch
  }

  /// Sites where some providers' key pages live, beyond their API domain.
  static let extraKeyPageDomains: [String: [String]] = ["gemini": ["google.com"], "google": ["google.com"]]

  /// The last two labels of a host: api.example.com becomes example.com.
  static func site(_ host: String) -> String {
    let parts = host.lowercased().split(separator: ":").first.map { $0.split(separator: ".") } ?? []
    return parts.suffix(2).joined(separator: ".")
  }

  /// True when an agent-supplied key page is on the same site as the key's API host or the provider's known domains.
  /// Domains shared by many customers: a page there isn't the provider's just because it's on the same domain.
  static let sharedHosting = ["googleapis.com", "supabase.co", "amazonaws.com", "cloudfront.net", "vercel.app", "netlify.app",
                              "herokuapp.com", "github.io", "pages.dev", "workers.dev", "appspot.com", "web.app", "firebaseapp.com",
                              "azurewebsites.net", "onrender.com", "fly.dev", "railway.app"]

  static func keyPageRelated(_ page: URL, service: String, apiHost: String) -> Bool {
    guard let h = page.host?.lowercased() else { return false }
    let apiSite = site(apiHost)
    var allowed = (sharedHosting.contains(apiSite) ? [] : [apiSite]) + (domains(service) ?? []).filter { !sharedHosting.contains($0) }
    if let extra = extraKeyPageDomains.first(where: { service.lowercased().contains($0.key) })?.value { allowed += extra }
    return allowed.contains { !$0.isEmpty && (h == $0 || h.hasSuffix("." + $0)) }
  }

  static func isKnown(service: String, host: String) -> Bool {
    guard let d = domains(service) else { return true }
    let h = host.lowercased()
    return d.contains { h == $0 || h.hasSuffix("." + $0) }
  }
  static func warning(service: String, name: String, host: String) -> String? {
    guard verdict(service: service, name: name, host: host) == .mismatch else { return nil }
    let text = (service + " " + name).lowercased().replacingOccurrences(of: " ", with: "")
    let d = known.first { text.contains($0.key) || host.lowercased().contains($0.key) }?.value ?? []
    return "This isn't a usual \(name) address (\(d.joined(separator: ", "))). Only save if you trust it."
  }
}
