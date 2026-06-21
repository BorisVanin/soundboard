import SwiftUI

/// The system-audio ("Mac") lane (middle): the system-output picker + one gain fader
/// and mute. The picker sets the macOS default output (choose "Soundboard System" to
/// route system audio through Soundboard, captured via the capture ring). The fader +
/// mute control the selected output device's volume; both are disabled when that device
/// has no software volume control.
struct MacLane: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Mac").font(.callout).foregroundStyle(.secondary)
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
                .help("Sets your system output. Choose “Soundboard System” to route Mac audio through Soundboard.")
            }
            Divider()
            Spacer(minLength: 0)

            HStack(alignment: .center, spacing: 20) {
                Spacer(minLength: 0)
                VolumeStrip(model: model, title: "Mac", systemImage: "desktopcomputer",
                            levelLine: model.macLevel, muteLine: model.macMute,
                            enabled: model.macSupportsVolume,
                            meterKeyPath: \.macMeter)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}
