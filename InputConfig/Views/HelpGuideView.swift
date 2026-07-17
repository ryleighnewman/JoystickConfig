import SwiftUI

/// Help Guide window. A sidebar of categorized tutorials on the left,
/// the selected guide rendered on the right. Add new guides via
/// `HelpGuideLibrary.all` in HelpGuides.swift.
struct HelpGuideView: View {
    @State private var selectedGuideID: String? = HelpGuideLibrary.all.first?.id

    private var guidesByCategory: [(category: String, guides: [HelpGuide])] {
        let grouped = Dictionary(grouping: HelpGuideLibrary.all, by: \.category)
        return grouped
            .map { (category: $0.key, guides: $0.value) }
            .sorted { $0.category < $1.category }
    }

    private var selectedGuide: HelpGuide? {
        HelpGuideLibrary.all.first { $0.id == selectedGuideID }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedGuideID) {
                ForEach(guidesByCategory, id: \.category) { group in
                    Section(group.category) {
                        ForEach(group.guides) { guide in
                            Text(guide.title)
                                .tag(guide.id as String?)
                        }
                    }
                }
            }
            .navigationTitle("Help Guides")
            .frame(minWidth: 240)
        } detail: {
            Group {
                if let guide = selectedGuide {
                    guideDetail(guide)
                } else {
                    ContentUnavailableView("Select a guide",
                                            systemImage: "book.closed",
                                            description: Text("Choose a topic from the sidebar to read."))
                }
            }
            // Content dissolves into the window vibrancy under the transparent
            // titlebar, matching the main window (spec section 3).
            .headerFade()
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .frame(minWidth: 820, minHeight: 540)
    }

    @ViewBuilder
    private func guideDetail(_ guide: HelpGuide) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                // Centered, calm header: small-caps category, big title,
                // secondary summary. Reads like an Apple settings page.
                VStack(spacing: 6) {
                    Text(guide.category.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.8)
                    Text(guide.title)
                        .font(.largeTitle.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text(guide.summary)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .padding(.bottom, 10)

                ForEach(guide.sections, id: \.heading) { section in
                    sectionView(section)
                }

                Spacer(minLength: 32)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(guide.title)
    }

    /// Each guide section is one quiet glass card. Steps are plain
    /// Apple-style numbered lines - no badges, no accent ink, no inner
    /// panels - so the content is the loudest thing on the page.
    @ViewBuilder
    private func sectionView(_ section: HelpSection) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(section.heading)
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            if !section.body.isEmpty {
                Text(section.body)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !section.steps.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(section.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1).")
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 22, alignment: .trailing)
                            Text(step)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.cardPad + 2)
        .liquidGlass(in: RoundedRectangle(cornerRadius: Metrics.sectionRadius, style: .continuous))
    }
}

/// Standalone window controller helper so the Help Guides view can be shown
/// from anywhere via NSWindow rather than a Scene.
@MainActor
final class HelpGuideWindowController {
    static let shared = HelpGuideWindowController()
    private var window: NSWindow?

    private init() {}

    func show() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: HelpGuideView()
            .background(VisualEffectBackground().ignoresSafeArea())
            .reduceMotionFriendly())
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = "InputConfig Help"
        newWindow.setContentSize(NSSize(width: 880, height: 580))
        // .fullSizeContentView lets the behind-window blur reach under the
        // transparent titlebar; without it the titlebar shows straight through
        // to the desktop (the "completely transparent top bar" bug).
        newWindow.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        newWindow.titlebarAppearsTransparent = true
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
