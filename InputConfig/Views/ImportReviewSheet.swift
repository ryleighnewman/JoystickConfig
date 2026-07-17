import SwiftUI

/// Pre-import review sheet. Opens when the user picks files in the
/// importer, before anything lands in the sidebar. Each row shows:
///   - the source filename
///   - the parsed preset name in an editable TextField (so the user
///     can rename a generically-named "New Preset" before it joins
///     their list)
///   - or, for files that failed to parse, the specific error message
///     so the user understands what's broken instead of silently
///     losing the file.
///
/// The user clicks "Import" to commit everything importable; "Cancel"
/// to drop the whole batch. Each row has an individual Skip toggle so
/// they can pick and choose.
struct ImportReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var presetStore: PresetStore

    /// Local mutable copy of the store's review queue so the user can
    /// rename entries / toggle skip without immediately mutating the
    /// shared @Published source. Committed back on "Import".
    @State private var rows: [PresetStore.ImportPreview] = []
    /// Per-row "skip this one" toggles. Keyed by ImportPreview.id.
    @State private var skipped: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(rows.indices, id: \.self) { idx in
                        rowView(at: idx)
                    }
                }
                .padding(18)
            }
            Divider()
            footer
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
        }
        .frame(width: 580, height: 460)
        .onAppear { rows = presetStore.importReviewQueue }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Review imports")
                    .font(.title3.weight(.semibold))
                Text("\(importableCount) ready · \(brokenCount) broken")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var importableCount: Int { rows.filter { $0.isImportable }.count }
    private var brokenCount: Int { rows.filter { !$0.isImportable }.count }

    @ViewBuilder
    private func rowView(at idx: Int) -> some View {
        let row = rows[idx]
        let isSkipped = skipped.contains(row.id)
        let isBroken = !row.isImportable

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: isBroken
                      ? "exclamationmark.triangle.fill"
                      : (isSkipped ? "minus.circle"
                                    : "checkmark.circle.fill"))
                    .foregroundStyle(isBroken ? .orange
                                              : (isSkipped ? .secondary : .green))
                Text(row.filename)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if !isBroken {
                    Toggle("Skip", isOn: Binding(
                        get: { isSkipped },
                        set: { newValue in
                            if newValue { skipped.insert(row.id) }
                            else { skipped.remove(row.id) }
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("Skip this file in the import batch")
                }
            }

            if isBroken {
                Text(row.errorMessage ?? "Unknown error")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.orange.opacity(0.10))
                    )
            } else {
                HStack(spacing: 6) {
                    Text("Name:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Preset name", text: Binding(
                        get: { rows[idx].nameDraft },
                        set: { rows[idx].nameDraft = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .disabled(isSkipped)
                }
                if let tag = row.preset?.tag, !tag.isEmpty {
                    Text(tag)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isBroken
                      ? Color.orange.opacity(0.06)
                      : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isBroken
                        ? Color.orange.opacity(0.3)
                        : Color.secondary.opacity(0.18),
                        lineWidth: 1)
        )
        .opacity(isSkipped ? 0.55 : 1)
    }

    /// Number of rows the user will actually import on confirm: parsed
    /// preset minus skipped ones. Pulled out to a plain Int property
    /// so the SwiftUI type-checker doesn't have to unify a chain of
    /// Set / filter / map / ternary expressions inside the footer.
    private var willImportCount: Int {
        var count = 0
        for row in rows where row.isImportable && !skipped.contains(row.id) {
            count += 1
        }
        return count
    }

    private var footerStatusText: String {
        if willImportCount == 0 { return "Nothing to import" }
        let suffix = willImportCount == 1 ? "" : "s"
        return "Will import \(willImportCount) preset\(suffix)"
    }

    private var footer: some View {
        HStack {
            Button("Cancel") {
                presetStore.cancelImportReview()
                dismiss()
            }
            .buttonStyle(.solidSecondary)
            .keyboardShortcut(.cancelAction)
            Spacer()
            Text(footerStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(action: confirm) {
                Text("Import")
            }
            .buttonStyle(.solid)
            .keyboardShortcut(.defaultAction)
            .disabled(willImportCount == 0)
        }
    }

    private func confirm() {
        let toCommit = rows.filter { $0.isImportable && !skipped.contains($0.id) }
        // Capture the first imported preset's ID before commit clears
        // it so we can fire the scroll-and-flash hint after dismiss.
        let firstID = toCommit.first?.preset?.id
        _ = presetStore.commitImportPreviews(toCommit)
        AccessibilityNotification.Announcement("Imported \(toCommit.count) preset\(toCommit.count == 1 ? "" : "s")").post()
        dismiss()
        // After the sheet dismisses, ask the sidebar to scroll the
        // newly imported preset into view and flash it green. Uses
        // the same notification + flashingPresetID mechanic the
        // FeatureDemo "jump to preset" flow already uses.
        if let id = firstID {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NotificationCenter.default.post(
                    name: .inputConfigImportedPreset,
                    object: id)
            }
        }
    }
}

extension Notification.Name {
    /// Fired by ImportReviewSheet after a successful import so
    /// ContentView can scroll-and-flash the new sidebar row.
    static let inputConfigImportedPreset =
        Notification.Name("InputConfig.ImportedPreset")
}
