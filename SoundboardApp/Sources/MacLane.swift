import SwiftUI

/// The system-audio ("Mac") input lane (right): a source picker + one gain fader
/// and mute, mirroring the Mic lane. Driven by `MixEngine`'s global process tap
/// (`MacSoundLane`), which runs independently of the mic — so its live meter shows
/// system-audio activity whether or not a mic is selected.
struct MacLane: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Mac").font(.callout).foregroundStyle(.secondary)
                // Selects which output device's audio the Mac lane records. Read-only:
                // it never changes the system's default output device.
                Picker("Mac", selection: Binding(
                    get: { model.macSourceUID ?? "" },
                    set: { if !$0.isEmpty { model.setMacSource($0) } }
                )) {
                    ForEach(model.availableOutputs) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .labelsHidden()
                .disabled(model.assigning)
                .help("Which output device's audio to record. This doesn't change your system output.")
            }
            Divider()
            Spacer(minLength: 0)

            HStack(alignment: .center, spacing: 20) {
                Spacer(minLength: 0)
                VolumeStrip(model: model, title: "Mac", systemImage: "desktopcomputer",
                            levelLine: model.macLevel, muteLine: model.macMute,
                            meterKeyPath: \.macMeter)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}
