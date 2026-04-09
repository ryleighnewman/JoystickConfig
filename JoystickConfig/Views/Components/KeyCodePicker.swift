import SwiftUI

/// Picker for selecting a keyboard key by HID usage code, grouped by category
struct KeyCodePicker: View {
    @SwiftUI.Binding var selectedCode: Int

    var body: some View {
        Picker("", selection: $selectedCode) {
            ForEach(KeyCodeMap.groups, id: \.self) { group in
                Section(header: Text(group)) {
                    ForEach(KeyCodeMap.keysByGroup[group] ?? []) { key in
                        Text(key.name).tag(key.code)
                    }
                }
            }
        }
        .labelsHidden()
        .controlSize(.small)
    }
}
