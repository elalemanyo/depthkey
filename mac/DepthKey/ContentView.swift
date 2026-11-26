import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings

    var body: some View {
        HStack(spacing: 0) {
            preview
            Divider()
            sidebar.frame(width: 320).clipped()
        }
        .frame(minWidth: 900, minHeight: 520)
    }

    private var preview: some View {
        ZStack {
            Color.black
            PreviewView(sink: model.preview)
            if let error = model.cameraError {
                VStack(spacing: 12) {
                    Text(error).font(.headline)
                    Button("Open Camera Privacy Settings") { model.openCameraPrivacySettings() }
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else if !model.modelReady {
                VStack(spacing: 10) {
                    if let progress = model.modelProgress {
                        ProgressView(value: progress).frame(width: 220)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(model.modelStatus).font(.callout)
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .overlay(alignment: .bottomLeading) {
            if model.modelReady {
                StatsBadge(stats: model.stats).padding(10)
            }
        }
    }

    private var sidebar: some View {
        Form {
            Section("Camera") {
                Picker("Camera", selection: $settings.cameraID) {
                    ForEach(model.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
                if let warning = model.effectsWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Background") {
                Picker("Background", selection: $settings.mode) {
                    ForEach(BackgroundMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch settings.mode {
                case .blur:
                    SliderRow(title: "Strength", value: $settings.blur, range: 4...60, step: 1) {
                        String(format: "%.0f", $0)
                    }
                case .color:
                    ColorPicker("Color", selection: colorBinding, supportsOpacity: false)
                    Text("Key it out in OBS with a Chroma Key filter.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                case .image:
                    LabeledContent("Image") {
                        HStack {
                            Text(settings.imagePath.isEmpty ? "None" : URL(fileURLWithPath: settings.imagePath).lastPathComponent)
                                .foregroundStyle(.secondary).lineLimit(1)
                            Button("Choose…") { model.chooseBackgroundImage() }
                        }
                    }
                case .depth:
                    Text("Red is near, dark blue is far (0.3 to 6 m).").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                case .off:
                    Text("The camera as is.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                SliderRow(title: "Distance", value: $settings.cutoff, range: 0.3...4, step: 0.01) {
                    String(format: "%.2f m", $0)
                }
                .disabled(settings.followFace)
                SliderRow(title: "Softness", value: $settings.softness, range: 0.01...0.6, step: 0.01) {
                    String(format: "%.0f cm", $0 * 100)
                }
                LabeledContent("Auto") {
                    Button("Measure now") { model.autoCutoff() }
                        .help("Depth of your face + 40 cm (the middle of the frame without a face)")
                }
                Toggle("Measure on start", isOn: $settings.autoCutoffOnStart)
                Toggle("Follow my face", isOn: $settings.followFace)
                    .help("Measure again twice a second, so the cut-off moves with you")
            } header: {
                Text("Cut-off")
            } footer: {
                if let measured = model.measuredFrom {
                    Text(measured).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Model", selection: $settings.variant) {
                    ForEach(ModelVariant.allCases) { Text($0.label).tag($0) }
                }
                Picker("Input", selection: $settings.modelSize) {
                    ForEach(ModelSize.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Keep video and mask in sync", isOn: $settings.syncMask)
            } header: {
                Text("Model")
            } footer: {
                Text("Base and larger inputs give sharper edges but run slower. In sync, the video runs at the model's speed; otherwise it stays smooth and the mask can trail fast moves slightly.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Section("Virtual camera") {
                if model.virtualCameraConnected {
                    Label("Sending to OBS Virtual Camera (\(model.virtualCameraSize))", systemImage: "video.fill")
                        .foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Pick “OBS Virtual Camera” in Zoom, Meet, Slack or OBS. Don't start OBS's own virtual camera at the same time.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("OBS Virtual Camera not found", systemImage: "video.slash")
                        .foregroundStyle(.orange)
                    Text("Install OBS 30 or later, open it, click Start Virtual Camera once (allow the extension if asked), then Stop.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                Toggle("Mirror preview", isOn: $settings.mirrorPreview)
                Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
            } header: {
                Text("General")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let note = model.loginNote {
                        Text(note).foregroundStyle(.orange)
                    }
                    Text("Closing the window keeps DepthKey running in the menu bar. Quit from there or with ⌘Q.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private struct StatsBadge: View {
        @ObservedObject var stats: Stats
        var body: some View {
            Text(String(format: "%.0f fps · model %.0f ms", stats.fps, stats.modelMs))
                .monospacedDigit()
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
        }
    }

    /// A slider on one row with its name and value. Rounds to `step` itself: `Slider(step:)` would
    /// draw a tick mark per step.
    private struct SliderRow: View {
        let title: String
        @Binding var value: Double
        let range: ClosedRange<Double>
        let step: Double
        let format: (Double) -> String

        var body: some View {
            LabeledContent(title) {
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { value }, set: { value = ($0 / step).rounded() * step }), in: range)
                        .labelsHidden()
                    Text(format(value))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }
            }
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { let c = settings.rgb; return Color(.sRGB, red: c.r, green: c.g, blue: c.b) },
            set: { color in
                guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
                settings.setColor(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
            })
    }
}
