import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Look

enum Theme {
    static let ink = Color(red: 0.030, green: 0.036, blue: 0.072)
    static let indigo = Color(red: 0.36, green: 0.44, blue: 1.00)
    static let violet = Color(red: 0.62, green: 0.42, blue: 0.98)
    static let gold = Color(red: 1.00, green: 0.80, blue: 0.45)
    static let accent = LinearGradient(colors: [indigo, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let warm = LinearGradient(colors: [Color(red: 0.66, green: 0.73, blue: 1.0), gold], startPoint: .leading, endPoint: .trailing)
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.78)
}

extension ToolbarItemPlacement {
    static var leadingBar: ToolbarItemPlacement {
        #if os(iOS)
        return .topBarLeading
        #else
        return .navigation
        #endif
    }
    static var trailingBar: ToolbarItemPlacement {
        #if os(iOS)
        return .topBarTrailing
        #else
        return .primaryAction
        #endif
    }
}

extension View {
    /// Transparent, compact top bar on both platforms.
    @ViewBuilder func cleanTopBar() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
        #else
        self.toolbarBackground(.hidden, for: .windowToolbar)
        #endif
    }
}

/// Slowly drifting coloured light behind everything, taken from the app icon's palette.
struct AuroraBackground: View {
    var intensity: Double = 1
    @State private var drift = false

    var body: some View {
        ZStack {
            Theme.ink
            Circle().fill(Theme.indigo)
                .frame(width: 420, height: 420)
                .blur(radius: 130)
                .offset(x: drift ? -130 : 90, y: drift ? -300 : -150)
            Circle().fill(Theme.violet)
                .frame(width: 340, height: 340)
                .blur(radius: 130)
                .offset(x: drift ? 150 : -60, y: drift ? 80 : 260)
            Circle().fill(Theme.gold.opacity(0.55))
                .frame(width: 260, height: 260)
                .blur(radius: 120)
                .offset(x: drift ? -70 : 130, y: drift ? 380 : 170)
        }
        .opacity(intensity)
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 11).repeatForever(autoreverses: true)) { drift = true }
        }
        .accessibilityHidden(true)
    }
}

/// Buttons sink slightly under the finger.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(Theme.snappy, value: configuration.isPressed)
    }
}

/// A light band that sweeps across a view every few seconds.
struct Shine: ViewModifier {
    var active: Bool = true
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { g in
                LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: g.size.width * 0.35)
                    .rotationEffect(.degrees(18))
                    .offset(x: phase * g.size.width * 1.4)
                    .opacity(active ? 1 : 0)
            }
            .mask(content)
            .allowsHitTesting(false)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).delay(0.6).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }
}

extension View {
    func shine(_ active: Bool = true) -> some View { modifier(Shine(active: active)) }

    /// Frosted card with a hairline edge.
    func glassCard(cornerRadius: CGFloat = 26) -> some View {
        background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.04)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
    }
}

/// Segmented control with a sliding highlight.
struct PillPicker<Value: Hashable>: View {
    struct Option {
        let value: Value
        let title: String
        var symbol: String? = nil
    }

    let options: [Option]
    @Binding var selection: Value
    var compact = false
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                let selected = option.value == selection
                Button {
                    withAnimation(Theme.snappy) { selection = option.value }
                } label: {
                    HStack(spacing: 6) {
                        if let s = option.symbol { Image(systemName: s).font(.caption.weight(.bold)) }
                        Text(option.title)
                    }
                    .font((compact ? Font.footnote : Font.subheadline).weight(.semibold))
                    .foregroundStyle(selected ? Color.white : Color.white.opacity(0.55))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, compact ? 7 : 10)
                    .background {
                        if selected {
                            Capsule()
                                .fill(Theme.accent)
                                .shadow(color: Theme.indigo.opacity(0.5), radius: 8, y: 3)
                                .matchedGeometryEffect(id: "highlight", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .sensoryFeedback(.selection, trigger: selection)
    }
}

// MARK: - Root

struct ContentView: View {
    @StateObject private var state = AppState()
    @State private var pickerItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showFiles = false
    @State private var zoomPercent = 0.0
    @State private var exitPrompt: ExitPrompt?
    /// iPhone only: the controls tuck away so the finished image gets the screen.
    @State private var controlsCollapsed = false
    /// Batch on iPhone and iPad: photos picked from the library.
    @State private var showBatchPicker = false
    @State private var batchPicks: [PhotosPickerItem] = []

    enum ExitPrompt { case running, unsaved }

    #if os(macOS)
    static let exportTitle = "Save as"
    static let saveTitle = "Save…"
    #else
    static let exportTitle = "Share as"
    static let saveTitle = "Save to Photos"
    #endif

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground(intensity: state.source == nil && state.batch == nil ? 1 : 0.35)
                    .animation(.easeInOut(duration: 0.8), value: state.source == nil)
                    .animation(.easeInOut(duration: 0.8), value: state.batch == nil)

                if state.batch != nil {
                    BatchView(state: state, onAdd: addToBatch, onExit: { exitPrompt = .running })
                        .transition(.opacity)
                } else if state.source == nil {
                    HomeView(showPhotoPicker: $showPhotoPicker, showFiles: $showFiles,
                             onPaste: { Task { await state.pasteImage() } }, onBatch: addToBatch)
                        .transition(.asymmetric(insertion: .opacity,
                                                removal: .opacity.combined(with: .scale(scale: 0.94))))
                } else {
                    editor
                        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 1.04)),
                                                removal: .opacity))
                }

                if state.isLoading {
                    LoadingBadge().transition(.opacity.combined(with: .scale))
                }

                if let toast = state.toast {
                    VStack {
                        Label(toast, systemImage: state.toastIcon)
                            .font(.subheadline.weight(.semibold))
                            .symbolRenderingMode(.multicolor)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .glassCard(cornerRadius: 22)
                            .padding(.top, 8)
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(Theme.spring, value: state.source == nil)
            .animation(Theme.spring, value: state.batch == nil)
            .animation(Theme.spring, value: state.isLoading)
            .animation(Theme.spring, value: state.toast)
            .photosPicker(isPresented: $showBatchPicker, selection: $batchPicks,
                          maxSelectionCount: 40, matching: .images)
            .onChange(of: batchPicks) { _, picks in
                guard !picks.isEmpty else { return }
                state.addBatch(photos: picks)
                batchPicks = []
            }
            .navigationTitle("")
            .cleanTopBar()
            .toolbar { toolbarContent }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, !state.isRunning else { return false }
                // Several images dropped at once (or anything dropped on the batch list) make a batch.
                if state.batch != nil || (urls.count > 1 && state.source == nil) {
                    state.addBatch(files: urls)
                } else {
                    Task { await state.load(fileURL: url) }
                }
                return true
            }
            .alert(exitPrompt == .running ? "Stop and exit?" : "Exit without saving?",
                   isPresented: Binding(get: { exitPrompt != nil }, set: { if !$0 { exitPrompt = nil } }),
                   presenting: exitPrompt) { prompt in
                if prompt == .unsaved {
                    #if os(macOS)
                    Button("Save & Exit") { state.share(.png) { state.goHome() } }
                    #else
                    Button("Save to Photos & Exit") { state.saveToPhotos { state.goHome() } }
                    #endif
                }
                Button(prompt == .running ? "Stop and Exit" : "Exit Without Saving", role: .destructive) {
                    state.goHome()
                }
                Button("Cancel", role: .cancel) {}
            } message: { prompt in
                Text(prompt == .running
                     ? "The upscale in progress will be stopped and you'll go back to the start."
                     : "Your upscaled image hasn't been saved. If you exit now, it's gone.")
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image]) { result in
                if case .success(let url) = result {
                    Task { await state.load(fileURL: url) }
                }
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItem, matching: .images)
        .preferredColorScheme(.dark)
        .fontDesign(.rounded)
        .tint(Theme.indigo)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                await state.load(item: item)
                // Clear the selection so the same photo can be picked again.
                pickerItem = nil
            }
        }
        #if os(iOS)
        .sheet(item: $state.shareItem) { item in
            ShareSheet(items: [item.url]) { completed in
                if completed { state.markSaved() }
            }
            .presentationDetents([.medium, .large])
        }
        #endif
        .sensoryFeedback(.success, trigger: state.completedRuns)
        .alert("Something went wrong", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
    }

    // MARK: editor

    #if os(iOS)
    static let canCollapse = UIDevice.current.userInterfaceIdiom == .phone
    #else
    static let canCollapse = false
    #endif

    private var editor: some View {
        GeometryReader { geo in
            // Wide windows (Mac, iPad landscape) put the controls beside the image.
            let wide = geo.size.width > 760
            let layout = wide ? AnyLayout(HStackLayout(alignment: .center, spacing: 0))
                              : AnyLayout(VStackLayout(spacing: 0))
            layout {
                ZStack {
                    CompareCanvas(before: state.source?.cgImage, after: state.result, mode: state.viewMode,
                                  split: $state.split, onZoomChange: { zoomPercent = $0 })
                        .ignoresSafeArea(edges: .horizontal)
                    if state.isRunning {
                        ScanOverlay().transition(.opacity)
                    }
                    canvasLabels
                }
                .animation(.easeInOut(duration: 0.35), value: state.isRunning)

                ZStack {
                    if state.isRunning {
                        RunCard(state: state, onStartOver: { exitPrompt = .running })
                            .transition(.move(edge: wide ? .trailing : .bottom).combined(with: .opacity))
                    } else {
                        ControlsPanel(state: state, collapsible: Self.canCollapse && !wide,
                                      collapsed: $controlsCollapsed)
                            .transition(.move(edge: wide ? .trailing : .bottom).combined(with: .opacity))
                    }
                }
                .animation(Theme.spring, value: state.isRunning)
                // Tuck the controls away when an upscale finishes, and bring them back for a new photo.
                .onChange(of: state.completedRuns) { _, _ in
                    guard Self.canCollapse else { return }
                    withAnimation(Theme.spring) { controlsCollapsed = true }
                }
                .onChange(of: state.result == nil) { _, cleared in
                    if cleared { withAnimation(Theme.spring) { controlsCollapsed = false } }
                }
                .frame(width: wide ? 380 : nil)
                .padding(wide ? EdgeInsets(top: 12, leading: 4, bottom: 16, trailing: 16)
                              : EdgeInsets(top: 0, leading: 12, bottom: 6, trailing: 12))
            }
        }
    }

    private var canvasLabels: some View {
        VStack {
            if state.result != nil && !state.isRunning {
                HStack {
                    if state.viewMode != .after {
                        tag("BEFORE").transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    Spacer()
                    if state.viewMode != .before {
                        tag("AFTER · \(state.resultLabel.uppercased())", highlighted: true)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
            }
            Spacer()
            if let s = state.source, !state.isRunning {
                Text(infoText(s))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .contentTransition(.numericText())
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
        .animation(Theme.spring, value: state.viewMode)
        .animation(Theme.spring, value: state.result != nil)
        .animation(.easeOut(duration: 0.2), value: zoomPercent)
        .allowsHitTesting(false)
    }

    private func infoText(_ s: SourceImage) -> String {
        var parts: [String] = []
        if let r = state.result {
            parts.append("\(s.width)×\(s.height) → \(r.width)×\(r.height)")
            if let d = state.lastDuration { parts.append(String(format: "%.1f s", d)) }
        } else {
            parts.append("\(s.width) × \(s.height)")
        }
        if zoomPercent > 0 { parts.append("\(Int(zoomPercent.rounded()))%") }
        return parts.joined(separator: "  ·  ")
    }

    private func tag(_ text: String, highlighted: Bool = false) -> some View {
        Text(text)
            .font(.caption2.weight(.heavy))
            .tracking(0.6)
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background {
                if highlighted {
                    Capsule().fill(Theme.accent.opacity(0.85))
                } else {
                    Capsule().fill(.ultraThinMaterial)
                }
            }
    }

    /// Batch: choose more images (Finder on the Mac, the photo library on iPhone and iPad).
    private func addToBatch() {
        #if os(macOS)
        state.pickBatchFiles()
        #else
        showBatchPicker = true
        #endif
    }

    /// Asks before leaving when that would stop a run or discard an unsaved result.
    private func requestExit() {
        if state.isRunning {
            exitPrompt = .running
        } else if state.result != nil && !state.isSaved {
            exitPrompt = .unsaved
        } else {
            state.goHome()
        }
    }

    // MARK: toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .leadingBar) {
            if state.source != nil || state.batch != nil {
                Button { requestExit() } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel(state.batch != nil ? "Close batch" : "Close image")
            }
        }
        #if os(iOS)
        ToolbarItem(placement: .principal) {
            if state.source != nil || state.batch != nil {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Theme.accent)
                    Text("Texel").font(.headline)
                }
            }
        }
        #endif
        ToolbarItem(placement: .trailingBar) {
            if state.source != nil {
                Menu {
                    #if os(macOS)
                    Button { showFiles = true } label: { Label("Open Image…", systemImage: "folder") }
                        .keyboardShortcut("o")
                    Button { showPhotoPicker = true } label: {
                        Label("Choose from Photos Library", systemImage: "photo.on.rectangle")
                    }
                    #else
                    Button { showPhotoPicker = true } label: {
                        Label("Choose from Photos", systemImage: "photo.on.rectangle")
                    }
                    Button { showFiles = true } label: { Label("Browse Files", systemImage: "folder") }
                        .keyboardShortcut("o")
                    #endif
                    Button { Task { await state.pasteImage() } } label: {
                        Label("Paste Image", systemImage: "doc.on.clipboard")
                    }
                    .keyboardShortcut("v")
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(state.isRunning)
            }
        }
        ToolbarItem(placement: .trailingBar) {
            if state.source != nil {
                // iPhone: tap saves to Photos. Mac: click opens a Save dialog (Downloads by default).
                // Touch and hold, or click the arrow, for other formats.
                Menu {
                    Section(Self.exportTitle) {
                        Button("PNG · lossless") { state.share(.png) }
                        Button("HEIC · small") { state.share(.heic) }
                        Button("JPEG") { state.share(.jpeg) }
                    }
                    #if os(macOS)
                    Button { state.saveToPhotos() } label: {
                        Label("Add to Photos Library", systemImage: "photo.on.rectangle")
                    }
                    #endif
                    Button { state.copyResult() } label: {
                        Label("Copy Image", systemImage: "doc.on.doc")
                    }
                    .keyboardShortcut("c")
                } label: {
                    if state.isExporting {
                        ProgressView()
                    } else {
                        Image(systemName: state.isSaved ? "checkmark.circle.fill" : "square.and.arrow.down")
                            .contentTransition(.symbolEffect(.replace))
                            .foregroundStyle(state.isSaved ? Color.green : Color.primary)
                    }
                } primaryAction: {
                    #if os(macOS)
                    state.share(.png)
                    #else
                    state.saveToPhotos()
                    #endif
                }
                .keyboardShortcut("s")
                .accessibilityLabel(state.isSaved ? "Saved" : Self.saveTitle)
                .disabled(state.result == nil || state.isRunning || state.isExporting)
            }
        }
    }
}

// MARK: - Home

struct HomeView: View {
    @Binding var showPhotoPicker: Bool
    @Binding var showFiles: Bool
    var onPaste: () -> Void = {}
    var onBatch: () -> Void = {}
    @State private var appeared = false
    @State private var floating = false
    @State private var glow = false
    @State private var showAbout = false

    // On the Mac, the main button opens Finder; on iPhone, the photo library.
    #if os(macOS)
    static let primaryTitle = "Open an Image…"
    static let primaryIcon = "folder"
    static let primaryShortcut = KeyboardShortcut("o")
    static let secondaryTitle = "Choose from Photos Library"
    static let secondaryIcon = "photo.on.rectangle"
    private func primaryAction() { showFiles = true }
    private func secondaryAction() { showPhotoPicker = true }
    #else
    static let primaryTitle = "Choose a Photo"
    static let primaryIcon = "photo.on.rectangle.angled"
    static let primaryShortcut = KeyboardShortcut("p")
    static let secondaryTitle = "Browse Files"
    static let secondaryIcon = "folder"
    private func primaryAction() { showPhotoPicker = true }
    private func secondaryAction() { showFiles = true }
    #endif

    private let features: [(String, String)] = [
        ("cpu", "On-device AI"),
        ("arrow.up.left.and.arrow.down.right", "Up to 8×"),
        ("lock.fill", "Private"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)

            ZStack {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 170, height: 170)
                    .blur(radius: 50)
                    .opacity(glow ? 0.85 : 0.45)
                    .scaleEffect(glow ? 1.08 : 0.92)
                Image("AppLogo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 124, height: 124)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.5), radius: 26, y: 16)
                    .offset(y: floating ? -7 : 7)
                    .rotation3DEffect(.degrees(floating ? 4 : -4), axis: (x: 1, y: 0, z: 0))
            }
            .accessibilityHidden(true)
            .scaleEffect(appeared ? 1 : 0.6)
            .opacity(appeared ? 1 : 0)
            .animation(.spring(response: 0.7, dampingFraction: 0.65), value: appeared)

            VStack(spacing: 12) {
                Text("Texel")
                    .font(.system(size: 46, weight: .heavy, design: .rounded))
                    .stagger(appeared, 1)
                Text("Small photo in.\nStunning detail out.")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.warm)
                    .multilineTextAlignment(.center)
                    .stagger(appeared, 2)
            }
            .padding(.top, 30)

            HStack(spacing: 8) {
                ForEach(features.indices, id: \.self) { i in
                    Label(features[i].1, systemImage: features[i].0)
                        .font(.caption.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                        .stagger(appeared, 3 + i)
                }
            }
            .padding(.top, 22)

            Spacer()

            VStack(spacing: 12) {
                Button {
                    primaryAction()
                } label: {
                    Label(Self.primaryTitle, systemImage: Self.primaryIcon)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(Capsule().fill(Theme.accent))
                        .shine()
                        .shadow(color: Theme.indigo.opacity(0.55), radius: 18, y: 8)
                }
                .buttonStyle(PressableStyle())
                .keyboardShortcut(Self.primaryShortcut)
                .stagger(appeared, 6)

                Button {
                    secondaryAction()
                } label: {
                    Label(Self.secondaryTitle, systemImage: Self.secondaryIcon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Capsule().fill(.ultraThinMaterial))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(PressableStyle())
                .stagger(appeared, 7)

                HStack(spacing: 10) {
                    smallButton("Paste", symbol: "doc.on.clipboard", action: onPaste)
                        .keyboardShortcut("v")
                    smallButton("Batch", symbol: "photo.stack", action: onBatch)
                        .keyboardShortcut("b")
                }
                .stagger(appeared, 8)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 26)
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) {
            Button {
                showAbout = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(12)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About Texel")
            .padding(.trailing, 8)
        }
        .sheet(isPresented: $showAbout) {
            AboutView()
        }
        .onAppear {
            appeared = true
            withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) { floating = true }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { glow = true }
        }
        .onDisappear { appeared = false }
    }

    private func smallButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Capsule().fill(Color.white.opacity(0.07)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}

private struct Stagger: ViewModifier {
    let shown: Bool
    let index: Int

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 22)
            .blur(radius: shown ? 0 : 6)
            .animation(.spring(response: 0.6, dampingFraction: 0.82).delay(0.08 * Double(index)), value: shown)
    }
}

extension View {
    /// Fades and lifts the view in, a little after the one before it.
    fileprivate func stagger(_ shown: Bool, _ index: Int) -> some View { modifier(Stagger(shown: shown, index: index)) }
}

// MARK: - About

/// Version, privacy statement and the open-source licence for the AI models.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(v) (\(b))"
    }

    private var licence: String {
        guard let url = Bundle.main.url(forResource: "LICENSE-Real-ESRGAN", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Real-ESRGAN © 2021 Xintao Wang. BSD 3-Clause License."
        }
        return text
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 16) {
                    Image("AppLogo")
                        .resizable()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Texel").font(.title2.weight(.bold))
                        Text(version).font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }

                section("Privacy", "Texel upscales your images entirely on this device. It doesn't collect, upload or share any data, and has no accounts, ads or tracking.")
                section("How it works", "AI mode uses Real-ESRGAN neural networks running on the Neural Engine and GPU through Core ML. Enhance redraws faces with GFPGAN and fixes colour and light with Apple's automatic adjustments. Classic mode uses GPU shaders: edge-directed upscaling (AMD FidelityFX Super Resolution 1), detail refinement and contrast-adaptive sharpening.")

                VStack(alignment: .leading, spacing: 8) {
                    Text("Acknowledgements").font(.headline)
                    Text("The AI models are converted from Real-ESRGAN (github.com/xinntao/Real-ESRGAN) and are used under the BSD 3-Clause License:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(licence)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
                    Text("Face restoration uses GFPGAN v1.4 by Xintao Wang et al. (github.com/TencentARC/GFPGAN), used under the Apache License 2.0. The full licence is included in the app.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 420, idealWidth: 520, minHeight: 480, idealHeight: 640)
        .background(Theme.ink.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Controls

struct ControlsPanel: View {
    @ObservedObject var state: AppState
    /// iPhone: show a pill that tucks the controls away with a swipe down.
    var collapsible = false
    var collapsed: Binding<Bool> = .constant(false)
    /// Batch mode: the same controls, applied to every image in the batch.
    var batch = false
    @Namespace private var chips
    @GestureState private var drag: CGFloat = 0
    @State private var tab: AdjustTab = .finish
    @State private var showCustomSize = false
    @State private var customSize = ""

    /// Common screen sizes for "Fit to" (name, long side in pixels).
    private static let fitChoices: [(String, Int)] = [
        ("Full HD", 1920), ("2K", 2560), ("4K", 3840), ("5K", 5120), ("8K", 7680),
    ]

    enum AdjustTab: Hashable { case finish, enhance }

    private var isCollapsed: Bool { collapsible && collapsed.wrappedValue }

    var body: some View {
        VStack(spacing: 14) {
            if collapsible {
                grabber
            }

            if state.result != nil {
                PillPicker(options: [
                    .init(value: ViewMode.split, title: "Split", symbol: "rectangle.split.2x1"),
                    .init(value: ViewMode.before, title: "Before"),
                    .init(value: ViewMode.after, title: "After"),
                ], selection: $state.viewMode, compact: true)
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if isCollapsed {
                collapsedSummary
                    .transition(.opacity)
            }

            if !isCollapsed {
                fullControls
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, collapsible ? 6 : 16)
        .padding(.bottom, 16)
        .glassCard()
        // Follow the finger a little while dragging, with resistance, so the pill feels attached.
        .offset(y: dragOffset)
        .animation(Theme.spring, value: state.result != nil)
        .animation(Theme.spring, value: isCollapsed)
        .sensoryFeedback(.impact(weight: .light), trigger: isCollapsed)
        .alert("Custom size", isPresented: $showCustomSize) {
            TextField("Long side in pixels", text: $customSize)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Button("Set") {
                if let px = Int(customSize.trimmingCharacters(in: .whitespaces)), px >= 16 {
                    state.fit(longSide: min(px, AIUpscaler.maxSide))
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("How many pixels should the longer side of the result be? Texel can enlarge up to 8×.")
        }
    }

    /// Dims the manual settings while Auto Fix is choosing them for each batch image.
    private var autoOwnsSettings: Bool { batch && state.batchAuto }

    /// "Fit to": aim for a size in pixels instead of a plain 2×, 4×…
    private var fitMenu: some View {
        Menu {
            Section("Fit the long side to") {
                ForEach(Self.fitChoices.indices, id: \.self) { i in
                    let choice = Self.fitChoices[i]
                    Button {
                        state.fit(longSide: choice.1)
                    } label: {
                        if state.fitTarget == choice.1 {
                            Label("\(choice.0) · \(String(choice.1)) px", systemImage: "checkmark")
                        } else {
                            Text("\(choice.0) · \(String(choice.1)) px")
                        }
                    }
                }
            }
            Button("Custom Size…") {
                customSize = state.fitTarget.map { String($0) } ?? ""
                showCustomSize = true
            }
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.footnote.weight(.bold))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .foregroundStyle(state.fitTarget != nil ? Color.white : Color.white.opacity(0.6))
        .frame(width: 36, height: 36)
        .background(
            Circle().fill(state.fitTarget != nil ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.07)))
        )
        .accessibilityLabel("Fit to a size")
        .help("Fit to a size: 4K, custom…")
    }

    private var dragOffset: CGFloat {
        guard collapsible, drag != 0 else { return 0 }
        if drag > 0 { return isCollapsed ? drag * 0.12 : drag * 0.45 }
        return drag * (isCollapsed ? 0.3 : 0.08)
    }

    private func setCollapsed(_ value: Bool) {
        guard collapsed.wrappedValue != value else { return }
        withAnimation(Theme.spring) { collapsed.wrappedValue = value }
    }

    /// The pill. Swipe down to hide the controls, up (or tap) to bring them back.
    private var grabber: some View {
        Capsule()
            .fill(.white.opacity(drag != 0 ? 0.55 : 0.32))
            .frame(width: drag != 0 ? 44 : 38, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .padding(.bottom, isCollapsed && state.result == nil ? 0 : -4)
            .frame(height: 22)
            .contentShape(Rectangle())
            .animation(Theme.snappy, value: drag != 0)
            .gesture(
                DragGesture(minimumDistance: 3)
                    .updating($drag) { v, s, _ in s = v.translation.height }
                    .onEnded { v in
                        let dy = v.predictedEndTranslation.height
                        if dy > 40 { setCollapsed(true) } else if dy < -40 { setCollapsed(false) }
                    }
            )
            .onTapGesture { setCollapsed(!collapsed.wrappedValue) }
            .accessibilityElement()
            .accessibilityLabel(isCollapsed ? "Show controls" : "Hide controls")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { setCollapsed(!collapsed.wrappedValue) }
    }

    /// One line in place of the controls when they're hidden and there's no result yet.
    private var collapsedSummary: some View {
        Button { setCollapsed(false) } label: {
            HStack(spacing: 8) {
                Image(systemName: state.useAI ? "sparkles" : "cpu")
                    .foregroundStyle(Theme.violet)
                Text(state.useAI ? "AI · \(state.aiModel.shortTitle)" : "Classic · \(state.preset.rawValue)")
                Text("·").foregroundStyle(.secondary)
                Text(state.scale == 1 ? "Enhance" : scaleText(state.scale))
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var fullControls: some View {
        VStack(spacing: 14) {
            if batch {
                BatchAutoToggle(state: state)
            } else {
                AutoFixButton(state: state)
            }

            row("Size") {
                HStack(spacing: 6) {
                    // No pill is lit while "Fit to" is choosing the size.
                    PillPicker(options: [
                        .init(value: 1.0, title: "1×"),
                        .init(value: 2.0, title: "2×"),
                        .init(value: 3.0, title: "3×"),
                        .init(value: 4.0, title: "4×"),
                        .init(value: 6.0, title: "6×"),
                        .init(value: 8.0, title: "8×"),
                    ], selection: Binding(get: { state.fitTarget == nil ? state.scale : -1 },
                                          set: { state.setScale($0) }))
                    .opacity(autoOwnsSettings ? 0.35 : 1)
                    .allowsHitTesting(!autoOwnsSettings)
                    fitMenu
                }
            }

            manualSettings
                .opacity(autoOwnsSettings ? 0.35 : 1)
                .allowsHitTesting(!autoOwnsSettings)

            statusLine

            if batch {
                BatchStartButton(state: state)
            } else {
                UpscaleButton(state: state)
            }
        }
    }

    /// Mode, model and the Finish / Enhance sliders.
    private var manualSettings: some View {
        VStack(spacing: 14) {
            row("Mode") {
                PillPicker(options: [
                    .init(value: true, title: "AI", symbol: "sparkles"),
                    .init(value: false, title: "Classic", symbol: "cpu"),
                ], selection: $state.useAI)
            }

            if state.useAI {
                HStack(spacing: 8) {
                    ForEach(AIModel.allCases, id: \.self) { m in
                        ModelChip(model: m, selected: state.aiModel == m, namespace: chips) {
                            withAnimation(Theme.snappy) { state.aiModel = m }
                        }
                    }
                }
                .sensoryFeedback(.selection, trigger: state.aiModel)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }

            PillPicker(options: [
                .init(value: AdjustTab.finish, title: state.useAI ? "Finish" : "Quality", symbol: "slider.horizontal.3"),
                .init(value: AdjustTab.enhance, title: "Enhance", symbol: "wand.and.stars"),
            ], selection: $tab, compact: true)

            Group {
                switch tab {
                case .finish:
                    if state.useAI {
                        VStack(spacing: 12) {
                            sliderRow("AI", value: $state.aiStrength, tint: .teal)
                            sliderRow("Detail", value: $state.detail, tint: Theme.violet)
                            sliderRow("Smooth", value: $state.smooth, tint: Theme.indigo)
                            sliderRow("Sharp", value: $state.sharpen, tint: Theme.gold)
                        }
                        .transition(.opacity)
                    } else {
                        PillPicker(options: [
                            .init(value: Preset.fast, title: "Fast"),
                            .init(value: Preset.balanced, title: "Balanced"),
                            .init(value: Preset.best, title: "Best"),
                        ], selection: $state.preset, compact: true)
                        .transition(.opacity)
                    }
                case .enhance:
                    VStack(spacing: 12) {
                        toggleRow("Faces", symbol: "face.smiling", isOn: $state.restoreFaces,
                                  value: $state.faceStrength, tint: Theme.violet)
                        toggleRow("Colour", symbol: "camera.filters", isOn: $state.autoEnhance,
                                  value: $state.enhanceAmount, tint: Theme.gold)
                    }
                    .transition(.opacity)
                }
            }
            .animation(Theme.spring, value: state.useAI)
            .animation(Theme.snappy, value: tab)
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            content()
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, tint: Color) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .frame(width: 54, alignment: .leading)
            Slider(value: value, in: 0...1) { editing in
                // Re-finish the existing result when the finger lifts; no need to run the AI again.
                if !editing { state.applyDetail() }
            }
            .tint(tint)
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .font(.footnote.monospacedDigit().weight(.semibold))
                .contentTransition(.numericText(value: value.wrappedValue))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
                .animation(.snappy, value: value.wrappedValue)
                .overlay(alignment: .trailing) {
                    if state.isBlending {
                        ProgressView().controlSize(.mini).offset(x: 16)
                    }
                }
        }
    }

    /// An on/off pill plus a strength slider (Enhance).
    private func toggleRow(_ title: String, symbol: String, isOn: Binding<Bool>,
                           value: Binding<Double>, tint: Color) -> some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(Theme.snappy) { isOn.wrappedValue.toggle() }
                state.applyDetail()
            } label: {
                Label(title, systemImage: symbol)
                    .font(.subheadline.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(isOn.wrappedValue ? Color.white : Color.white.opacity(0.55))
                    .frame(width: 94, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(
                        Capsule().fill(isOn.wrappedValue ? AnyShapeStyle(tint.opacity(0.35)) : AnyShapeStyle(Color.white.opacity(0.06)))
                    )
                    .overlay(Capsule().strokeBorder(isOn.wrappedValue ? tint : Color.white.opacity(0.12), lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
            .sensoryFeedback(.selection, trigger: isOn.wrappedValue)
            .accessibilityValue(isOn.wrappedValue ? "On" : "Off")

            Slider(value: value, in: 0...1) { editing in
                if !editing { state.applyDetail() }
            }
            .tint(tint)
            .disabled(!isOn.wrappedValue)
            .opacity(isOn.wrappedValue ? 1 : 0.35)

            Text(isOn.wrappedValue ? "\(Int((value.wrappedValue * 100).rounded()))%" : "Off")
                .font(.footnote.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
                .overlay(alignment: .trailing) {
                    if state.isBlending {
                        ProgressView().controlSize(.mini).offset(x: 16)
                    }
                }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if batch, let blocker = state.batchBlocker {
            Label(blocker, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
        } else if autoOwnsSettings {
            Text("Auto Fix looks at each image and picks the model and sliders for it. It keeps the size, or doubles small images, unless you pick a Fit to size.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
        } else if let blocker = state.blocker {
            Label(blocker, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
        } else if let summary = state.autoSummary, tab == .finish {
            Label(summary, systemImage: "wand.and.stars")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.gold)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
        } else if state.scale == 1 && tab == .finish {
            Text("1× keeps the size and rebuilds the image: the AI redraws it at 4× detail, then shrinks it back, removing blur, noise and compression.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
        } else if tab == .enhance {
            Text("Faces redraws blurry faces with a face AI. Colour fixes light and colour and adds clarity to texture like trees and fabric.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
        } else {
            Text(state.useAI ? state.aiModel.summary : state.preset.summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(state.useAI ? state.aiModel.rawValue : state.preset.rawValue)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: state.aiModel)
        }
    }
}

/// Auto Fix: analyses the image, picks every setting to suit it, and runs.
struct AutoFixButton: View {
    @ObservedObject var state: AppState

    var body: some View {
        let busy = state.isAnalyzing || state.isRunning
        Button { state.autoFix() } label: {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.gold)
                    .symbolEffect(.bounce, value: state.isAnalyzing)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto Fix")
                        .font(.subheadline.weight(.bold))
                    Text(state.isAnalyzing ? "Looking for blur, noise, faces and lighting…"
                                           : "Finds what's wrong and fixes it, keeping the look")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if state.isAnalyzing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.right").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.gold.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.gold.opacity(0.55), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(busy && !state.isAnalyzing ? 0.45 : 1)
        }
        .buttonStyle(PressableStyle())
        .disabled(busy)
        .keyboardShortcut("a", modifiers: [.command, .shift])
        .sensoryFeedback(.impact(weight: .light), trigger: state.isAnalyzing) { _, now in now }
    }
}

struct UpscaleButton: View {
    @ObservedObject var state: AppState

    var body: some View {
        let disabled = state.isRunning || state.blocker != nil
        Button {
            state.run()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.headline)
                    .symbolEffect(.pulse, options: .repeating, isActive: !disabled)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.scale == 1 ? "Enhance with AI" : state.useAI ? "Upscale with AI" : "Upscale")
                        .font(.headline)
                    if let size = state.outputSize {
                        Text(state.scale == 1 ? "Same size · \(size.0) × \(size.1) px" : "→ \(size.0) × \(size.1) px")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .opacity(0.8)
                            .contentTransition(.numericText())
                    }
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.headline)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Capsule().fill(Theme.accent))
            .shine(!disabled)
            .shadow(color: Theme.indigo.opacity(disabled ? 0 : 0.5), radius: 16, y: 8)
            .opacity(disabled ? 0.45 : 1)
            .animation(Theme.snappy, value: state.scale)
        }
        .buttonStyle(PressableStyle())
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(disabled)
        .sensoryFeedback(.impact(weight: .medium), trigger: state.isRunning) { _, running in running }
    }
}

struct ModelChip: View {
    let model: AIModel
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    private var icon: String {
        switch model {
        case .photo: return "camera.aperture"
        case .general: return "hare.fill"
        case .anime: return "paintpalette.fill"
        }
    }

    private var tag: String {
        switch model {
        case .photo: return "BEST"
        case .general: return "FAST"
        case .anime: return "ART"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .symbolEffect(.bounce, value: selected)
                Text(model.shortTitle).font(.subheadline.weight(.bold))
                Text(tag)
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.8)
                    .opacity(0.7)
            }
            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.6))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                    if selected {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Theme.accent.opacity(0.35))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(Theme.accent, lineWidth: 1.5)
                            )
                            .matchedGeometryEffect(id: "chip", in: namespace)
                    }
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Running

/// A bright band sweeping over the photo while it's being processed.
struct ScanOverlay: View {
    @State private var sweep = false

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Color.black.opacity(0.28)
                LinearGradient(colors: [.clear, Theme.indigo.opacity(0.45), .white.opacity(0.75), Theme.violet.opacity(0.45), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 120)
                    .blendMode(.plusLighter)
                    .offset(x: sweep ? g.size.width + 60 : -180)
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: false)) { sweep = true }
        }
    }
}

struct RunCard: View {
    @ObservedObject var state: AppState
    var onStartOver: () -> Void
    @State private var spin = false

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.1), lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: CGFloat(max(0.02, state.progress)))
                        .stroke(AngularGradient(colors: [Theme.indigo, Theme.violet, Theme.gold, Theme.indigo], center: .center),
                                style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.4), value: state.progress)
                    Circle()
                        .trim(from: 0, to: 0.12)
                        .stroke(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .padding(-7)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                    Text("\(Int((state.progress * 100).rounded()))%")
                        .font(.subheadline.monospacedDigit().weight(.bold))
                        .contentTransition(.numericText(value: state.progress))
                        .animation(.snappy, value: state.progress)
                }
                .frame(width: 64, height: 64)

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.headline)
                    Text(state.stage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: state.stage)
                    TimelineView(.periodic(from: state.startedAt, by: 0.1)) { ctx in
                        Text(RunCard.timeText(elapsed: ctx.date.timeIntervalSince(state.startedAt),
                                              progress: state.progress))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button {
                    state.cancel()
                } label: {
                    Label("Cancel", systemImage: "stop.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(PressableStyle())
                Button {
                    onStartOver()
                } label: {
                    Label("Start Over", systemImage: "house.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(PressableStyle())
            }
            .foregroundStyle(.white)

            Text("Keep Texel open until it finishes.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(18)
        .glassCard()
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { spin = true }
        }
    }

    private var title: String {
        if state.batch != nil { return "Upscaling the batch" }
        if !state.useAI { return "Upscaling" }
        return state.scale == 1 ? "Enhancing with AI" : "Upscaling with AI"
    }

    /// "12.4 s · about 40 s left": the estimate appears once there's enough progress to judge by.
    static func timeText(elapsed: TimeInterval, progress: Double) -> String {
        let e = max(0, elapsed)
        var text = e < 60 ? String(format: "%.1f s", e) : clock(e)
        if progress > 0.04, progress < 0.995, e > 3 {
            let left = e / progress * (1 - progress)
            let about: String
            if left < 10 {
                about = "\(max(1, Int(left.rounded(.up)))) s"
            } else if left < 60 {
                about = "\(Int((left / 5).rounded(.up)) * 5) s"
            } else {
                about = clock((left / 15).rounded(.up) * 15) + " min"
            }
            text += " · about \(about) left"
        }
        return text
    }

    private static func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

// MARK: - Batch

/// Several images at once: the list sits where the photo would be, with the usual controls beside it.
struct BatchView: View {
    @ObservedObject var state: AppState
    var onAdd: () -> Void
    var onExit: () -> Void

    var body: some View {
        GeometryReader { geo in
            if geo.size.width > 760 {
                HStack(alignment: .center, spacing: 0) {
                    ScrollView {
                        list.padding(EdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 10))
                    }
                    side(edge: .trailing)
                        .frame(width: 380)
                        .padding(EdgeInsets(top: 12, leading: 4, bottom: 16, trailing: 16))
                }
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        list
                        side(edge: .bottom)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
            }
        }
    }

    private func side(edge: Edge) -> some View {
        ZStack {
            if state.isRunning {
                RunCard(state: state, onStartOver: onExit)
                    .transition(.move(edge: edge).combined(with: .opacity))
            } else {
                ControlsPanel(state: state, batch: true)
                    .transition(.move(edge: edge).combined(with: .opacity))
            }
        }
        .animation(Theme.spring, value: state.isRunning)
    }

    private var list: some View {
        let items = state.batch ?? []
        return VStack(spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Batch").font(.title2.weight(.bold))
                    Text(summary(items))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onAdd) {
                    Label("Add", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                .disabled(state.isRunning)
                .opacity(state.isRunning ? 0.4 : 1)
            }
            .padding(.bottom, 2)

            if items.isEmpty {
                Text("Add some images to get going.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            }
            ForEach(items) { item in
                row(item)
            }
            #if os(macOS)
            destination
            #endif
        }
    }

    private func summary(_ items: [BatchItem]) -> String {
        let done = items.filter { $0.isDone }.count
        let total = items.count == 1 ? "1 image" : "\(items.count) images"
        return done > 0 ? "\(done) of \(total) done" : total
    }

    private func row(_ item: BatchItem) -> some View {
        HStack(spacing: 12) {
            statusIcon(item.status)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(statusText(item.status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if !state.isRunning {
                Button {
                    withAnimation(Theme.snappy) { state.removeBatchItem(item.id) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(item.name)")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(item.status == .running ? 0.4 : 0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func statusIcon(_ status: BatchItem.Status) -> some View {
        switch status {
        case .waiting:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private func statusText(_ status: BatchItem.Status) -> String {
        switch status {
        case .waiting: return "Waiting"
        case .running: return "Working on it…"
        case .done(let savedAs): return savedAs
        case .failed(let why): return why
        }
    }

    #if os(macOS)
    /// Where the results go and in which format.
    private var destination: some View {
        let folder = state.batchOutputFolder
        return VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text("Saves to \(folder.deletingLastPathComponent().lastPathComponent) › \(folder.lastPathComponent)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button("Show") { state.showBatchFolder() }
                Button("Change…") { state.chooseBatchFolder() }
                    .disabled(state.isRunning)
            }
            .font(.footnote)
            PillPicker(options: [
                .init(value: ExportFormat.png, title: "PNG"),
                .init(value: ExportFormat.jpeg, title: "JPEG"),
                .init(value: ExportFormat.heic, title: "HEIC"),
            ], selection: $state.batchFormat, compact: true)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.06)))
        .padding(.top, 4)
    }
    #endif
}

/// Batch: let Auto Fix choose the settings for each image.
struct BatchAutoToggle: View {
    @ObservedObject var state: AppState

    var body: some View {
        Button {
            withAnimation(Theme.snappy) { state.batchAuto.toggle() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.gold)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto Fix each image")
                        .font(.subheadline.weight(.bold))
                    Text(state.batchAuto ? "On: Texel picks the settings for each one"
                                         : "Off: every image gets the settings below")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: state.batchAuto ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(state.batchAuto ? Theme.gold : Color.white.opacity(0.4))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.gold.opacity(state.batchAuto ? 0.18 : 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.gold.opacity(state.batchAuto ? 0.7 : 0.3), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .sensoryFeedback(.selection, trigger: state.batchAuto)
        .accessibilityValue(state.batchAuto ? "On" : "Off")
    }
}

/// Batch: starts (or continues) upscaling everything that isn't done yet.
struct BatchStartButton: View {
    @ObservedObject var state: AppState

    var body: some View {
        let items = state.batch ?? []
        let left = items.filter { !$0.isDone }.count
        let disabled = state.isRunning || left == 0 || state.batchBlocker != nil
        Button {
            state.runBatch()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title(left: left, total: items.count))
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption2.weight(.semibold))
                        .opacity(0.8)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.headline)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Capsule().fill(Theme.accent))
            .shine(!disabled)
            .shadow(color: Theme.indigo.opacity(disabled ? 0 : 0.5), radius: 16, y: 8)
            .opacity(disabled ? 0.45 : 1)
        }
        .buttonStyle(PressableStyle())
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(disabled)
        .sensoryFeedback(.impact(weight: .medium), trigger: state.isRunning) { _, running in running }
    }

    private func title(left: Int, total: Int) -> String {
        if total == 0 { return "Add images to start" }
        if left == 0 { return "All done" }
        return left == 1 ? "Upscale 1 Image" : "Upscale \(left) Images"
    }

    private var subtitle: String {
        var parts: [String] = []
        if let fit = state.fitTarget {
            parts.append("Long side → \(String(fit)) px")
        } else if state.batchAuto {
            parts.append("Size picked per image")
        } else {
            parts.append(state.scale == 1 ? "Same size" : "\(scaleText(state.scale)) each")
        }
        #if os(macOS)
        parts.append("\(state.batchFormat.rawValue) → \(state.batchOutputFolder.lastPathComponent)")
        #else
        parts.append("Saves to Photos")
        #endif
        return parts.joined(separator: " · ")
    }
}

struct LoadingBadge: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large).tint(.white)
            Text("Opening photo…")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .glassCard(cornerRadius: 22)
    }
}

// MARK: - Share sheet

#if os(iOS)
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: (Bool) -> Void = { _ in }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        let done = onComplete
        controller.completionWithItemsHandler = { _, completed, _, _ in done(completed) }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
