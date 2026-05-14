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
            if let guide = selectedGuide {
                guideDetail(guide)
            } else {
                ContentUnavailableView("Select a guide",
                                        systemImage: "book.closed",
                                        description: Text("Choose a topic from the sidebar to read."))
            }
        }
        .frame(minWidth: 820, minHeight: 540)
    }

    @ViewBuilder
    private func guideDetail(_ guide: HelpGuide) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(guide.category.uppercased())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .tracking(0.8)
                    Text(guide.title)
                        .font(.largeTitle)
                        .fontWeight(.semibold)
                    Text(guide.summary)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .padding(.bottom, 4)

                Divider()

                ForEach(guide.sections, id: \.heading) { section in
                    sectionView(section)
                }

                Spacer(minLength: 32)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .navigationTitle(guide.title)
    }

    @ViewBuilder
    private func sectionView(_ section: HelpSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.heading)
                .font(.title3)
                .fontWeight(.semibold)

            if !section.body.isEmpty {
                Text(section.body)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !section.steps.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(section.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 10) {
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
                .padding(.leading, 4)
            }
        }
        .padding(.bottom, 6)
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
        let hosting = NSHostingController(rootView: HelpGuideView())
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = "JoystickConfig Help"
        newWindow.setContentSize(NSSize(width: 880, height: 580))
        newWindow.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
