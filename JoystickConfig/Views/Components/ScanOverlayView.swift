import SwiftUI

/// Overlay shown while scanning for joystick input
struct ScanOverlayView: View {
    @ObservedObject var controllerService: GameControllerService
    let onInputDetected: (InputEvent) -> Void
    let onCancel: () -> Void

    @State private var timeRemaining: Int = 10
    @State private var detectedInput: InputEvent?
    @State private var timer: Timer?

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { /* prevent tap-through */ }

            // Content card
            VStack(spacing: 20) {
                // Timer
                Text("\(timeRemaining)")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Hold any button or move any axis on your Joystick")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                if let input = detectedInput {
                    Text("Detected: \(input.displayName)")
                        .font(.title3)
                        .bold()
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                }

                Text("Press ESC to cancel")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))

                Button("Cancel") {
                    cleanup()
                    onCancel()
                }
                .keyboardShortcut(.escape, modifiers: [])
                .buttonStyle(.bordered)
                .tint(.white)
            }
            .padding(40)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .shadow(radius: 20)
            )
        }
        .onAppear {
            startTimer()
            controllerService.startScanning { event in
                detectedInput = event
                // Brief delay to show the detected input before closing
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    cleanup()
                    onInputDetected(event)
                }
            }
        }
        .onDisappear {
            cleanup()
        }
    }

    private func startTimer() {
        timeRemaining = 10
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if timeRemaining > 0 {
                timeRemaining -= 1
            } else {
                cleanup()
                onCancel()
            }
        }
    }

    private func cleanup() {
        timer?.invalidate()
        timer = nil
        controllerService.stopScanning()
    }
}
