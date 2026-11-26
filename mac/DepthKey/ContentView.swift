import SwiftUI

struct ContentView: View {
    static let sidebarWidth: CGFloat = 380
    static let sidebarPadding: CGFloat = 14
    static var contentWidth: CGFloat { sidebarWidth - 2 * sidebarPadding }

    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings

    var body: some View {
        HStack(spacing: 0) {
            preview
            Divider()
            sidebar.frame(width: Self.sidebarWidth)
        }
        .frame(minWidth: 980, minHeight: 520)
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

    // A plain scroll view of sections: a grouped Form sized itself from its content and could end up
    // wider than the sidebar, clipped on both sides.
    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Panel("Camera") {
                    Row("Camera") {
                        Picker("Camera", selection: $settings.cameraID) {
                            ForEach(model.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 200)
                    }
                } footer: {
                    if let warning = model.effectsWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }

                Panel("Background") {
                    ModePicker(selection: $settings.mode).padding(6)
                    backgroundOptions
                } footer: {
                    backgroundFooter
                }

                Panel("Cut-off") {
                    SliderRow(title: "Distance", value: $settings.cutoff, range: 0.3...4, step: 0.01) {
                        String(format: "%.2f m", $0)
                    }
                    .disabled(settings.followFace)
                    Divider()
                    SliderRow(title: "Softness", value: $settings.softness, range: 0.01...0.6, step: 0.01) {
                        String(format: "%.0f cm", $0 * 100)
                    }
                    Divider()
                    Row("Auto") {
                        Button("Measure now") { model.autoCutoff() }
                            .help("Depth of your face + 40 cm (the middle of the frame without a face)")
                    }
                    Divider()
                    SwitchRow("Measure on start", isOn: $settings.autoCutoffOnStart)
                    Divider()
                    SwitchRow("Follow my face", isOn: $settings.followFace)
                        .help("Measure again twice a second, so the cut-off moves with you")
                } footer: {
                    if let measured = model.measuredFrom { Text(measured) }
                }

                Panel("Model") {
                    Row("Model") {
                        Picker("Model", selection: $settings.variant) {
                            ForEach(ModelVariant.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    Divider()
                    Row("Input") {
                        Picker("Input", selection: $settings.modelSize) {
                            ForEach(ModelSize.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    Divider()
                    SwitchRow("Keep video and mask in sync", isOn: $settings.syncMask)
                } footer: {
                    Text("Base and larger inputs give sharper edges but run slower. In sync, the video runs at the model's speed; otherwise it stays smooth and the mask can trail fast moves slightly.")
                }

                Panel("Virtual camera") {
                    Row {
                        if model.virtualCameraConnected {
                            Label("Sending to OBS Virtual Camera (\(model.virtualCameraSize))", systemImage: "video.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("OBS Virtual Camera not found", systemImage: "video.slash")
                                .foregroundStyle(.orange)
                        }
                    }
                } footer: {
                    Text(model.virtualCameraConnected
                         ? "Pick “OBS Virtual Camera” in Zoom, Meet, Slack or OBS. Don't start OBS's own virtual camera at the same time."
                         : "Install OBS 30 or later, open it, click Start Virtual Camera once (allow the extension if asked), then Stop.")
                }

                Panel("General") {
                    SwitchRow("Mirror preview", isOn: $settings.mirrorPreview)
                    Divider()
                    SwitchRow("Open at login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                } footer: {
                    if let note = model.loginNote { Text(note).foregroundStyle(.orange) }
                    Text("Closing the window keeps DepthKey running in the menu bar. Quit from there or with ⌘Q.")
                }
            }
            // An explicit width: a scroll view doesn't hold its content to its own width, so the
            // widest row would otherwise push every panel past the right edge.
            .frame(width: Self.contentWidth, alignment: .leading)
            .padding(.horizontal, Self.sidebarPadding)
            .padding(.vertical, 16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var backgroundOptions: some View {
        switch settings.mode {
        case .blur:
            Divider()
            SliderRow(title: "Strength", value: $settings.blur, range: 4...60, step: 1) { String(format: "%.0f", $0) }
        case .color:
            Divider()
            Row("Color") { ColorPicker("Color", selection: colorBinding, supportsOpacity: false).labelsHidden() }
        case .image:
            Divider()
            Row("Image") {
                Text(settings.imagePath.isEmpty ? "None" : URL(fileURLWithPath: settings.imagePath).lastPathComponent)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Button("Choose…") { model.chooseBackgroundImage() }
            }
        case .video:
            Divider()
            VideoSourceRow(model: model, settings: settings)
        case .depth, .off:
            EmptyView()
        }
    }

    @ViewBuilder private var backgroundFooter: some View {
        switch settings.mode {
        case .color: Text("Key it out in OBS with a Chroma Key filter.")
        case .video:
            if let status = model.videoStatus {
                Text(status).foregroundStyle(model.videoStatusIsError ? .orange : .secondary)
            }
            Text("A file, a link (YouTube, Vimeo, …, .mp4, .m3u8) or a live stream (rtsp://, rtmp://, srt://). Loops without sound.")
        case .depth: Text("Red is near, dark blue is far (0.3 to 6 m).")
        case .off: Text("The camera as is.")
        default: EmptyView()
        }
    }

    /// Equal-width segments: a stretched `.segmented` picker keeps each segment at its natural
    /// width and spreads the leftover space unevenly.
    private struct ModePicker: View {
        @Binding var selection: BackgroundMode

        var body: some View {
            HStack(spacing: 2) {
                ForEach(BackgroundMode.allCases) { mode in
                    let selected = mode == selection
                    Button { selection = mode } label: {
                        Text(mode.label)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : Color.clear))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    /// Edits the video source as text, applied on Return, so a half-typed link isn't loaded.
    private struct VideoSourceRow: View {
        @ObservedObject var model: AppModel
        @ObservedObject var settings: Settings
        @State private var text = ""

        var body: some View {
            HStack(spacing: 8) {
                TextField("File, link or stream", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { settings.videoPath = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                Button("Choose…") { model.chooseBackgroundVideo() }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .onAppear { text = settings.videoPath }
            .onChange(of: settings.videoPath) { _, path in text = path }
        }
    }

    /// A titled group of rows on a rounded background, with an optional caption under it.
    private struct Panel<Content: View, Footer: View>: View {
        let title: String
        @ViewBuilder let content: Content
        @ViewBuilder let footer: Footer

        init(_ title: String, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer = { EmptyView() }) {
            self.title = title
            self.content = content()
            self.footer = footer()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline).padding(.leading, 2)
                // A fixed width, so no row can widen its group past the sidebar.
                VStack(spacing: 0) { content }
                    .frame(width: ContentView.contentWidth)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.07)))
                VStack(alignment: .leading, spacing: 4) { footer }
                    .frame(width: ContentView.contentWidth - 4, alignment: .leading)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }

    /// A label on the left and controls on the right.
    private struct Row<Trailing: View>: View {
        let title: String?
        @ViewBuilder let trailing: Trailing

        init(_ title: String? = nil, @ViewBuilder trailing: () -> Trailing) {
            self.title = title
            self.trailing = trailing()
        }

        var body: some View {
            HStack(spacing: 8) {
                if let title {
                    Text(title)
                    Spacer(minLength: 8)
                }
                trailing
                if title == nil { Spacer(minLength: 0) }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 34)
        }
    }

    private struct SwitchRow: View {
        let title: String
        @Binding var isOn: Bool
        init(_ title: String, isOn: Binding<Bool>) {
            self.title = title
            _isOn = isOn
        }
        var body: some View {
            Row(title) { Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small) }
        }
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
            Row(title) {
                Slider(value: Binding(get: { value }, set: { value = ($0 / step).rounded() * step }), in: range)
                    .labelsHidden()
                    .frame(maxWidth: 150)
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
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
