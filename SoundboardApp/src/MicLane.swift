import SwiftUI

/// The microphone input lane (left): device picker, gain fader + mute, and a
/// per-channel checklist for the selected mic. Drives `MixEngine` via `micLevel`
/// / `micMute`; the picker is the `micOnOff` line for MIDI assignment.
struct MicLane: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Mic").font(.callout).foregroundStyle(.secondary)
                // The mic On/Off line has no fader, so its assign chip floats over
                // the picker (the picker goes inert while assigning).
                Picker("Microphone", selection: Binding(
                    get: { model.selectedMonitorMicUID ?? "" },
                    set: { model.selectMonitorMic($0.isEmpty ? nil : $0) }
                )) {
                    Text("None").tag("")
                    ForEach(model.availableInputs) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .labelsHidden()
                .disabled(model.assigning)
                .overlay { if model.assigning { AssignLabel(model: model, line: model.micOnOff) } }
            }
            Divider()
            Spacer(minLength: 0)

            HStack(alignment: .center, spacing: 20) {
                Spacer(minLength: 0)
                VolumeStrip(model: model, title: "Mic", systemImage: "mic.fill",
                            levelLine: model.micLevel, muteLine: model.micMute,
                            enabled: model.selectedMonitorMicUID != nil,
                            meterKeyPath: \.micMeter)
                channelChecklist.disabled(model.assigning).opacity(model.assigning ? 0.4 : 1)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        // Flexible width: the three lanes share the window evenly (centered content),
        // so they spread out as the window widens.
        .frame(maxWidth: .infinity)
    }

    /// Checkboxes for each channel of the selected mic.
    private var channelChecklist: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Channels").font(.caption.bold()).foregroundStyle(.secondary)
            if model.selectedMonitorMicUID == nil {
                Text("—").font(.caption2).foregroundStyle(.tertiary)
            } else if model.selectedMicChannelCount == 0 {
                Text("No channels").font(.caption2).foregroundStyle(.tertiary)
            } else {
                ForEach(0..<model.selectedMicChannelCount, id: \.self) { channel in
                    Toggle("Ch \(channel + 1)", isOn: Binding(
                        get: { model.isChannelEnabled(channel) },
                        set: { model.setChannel(channel, enabled: $0) }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
        }
        .frame(width: 90, alignment: .leading)
    }
}
