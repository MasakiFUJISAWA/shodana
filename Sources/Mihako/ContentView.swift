import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var browser: FileBrowserViewModel
    @State private var sidebarWidth: CGFloat = 300
    @State private var pasteboardShortcutMonitor: Any?
    @State private var hostingWindow: NSWindow?

    private let minimumSidebarWidth: CGFloat = 220
    private let preferredMaximumSidebarWidth: CGFloat = 560
    private let resizeHandleWidth: CGFloat = 8
    private let minimumFileBrowserWidth: CGFloat = 760
    private let minimumFileBrowserHeight: CGFloat = 520
    private let minimumWindowHeight: CGFloat = 580

    private var minimumWindowWidth: CGFloat {
        minimumSidebarWidth + resizeHandleWidth + minimumFileBrowserWidth
    }

    var body: some View {
        GeometryReader { proxy in
            let availableWidth = max(proxy.size.width, minimumWindowWidth)
            let availableHeight = max(proxy.size.height, minimumWindowHeight)
            let maximumSidebarWidth = sidebarMaximumWidth(for: availableWidth)
            let actualSidebarWidth = clampedSidebarWidth(maximumWidth: maximumSidebarWidth)

            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: actualSidebarWidth, alignment: .leading)
                    .frame(maxHeight: .infinity)
                    .clipped()

                SidebarResizeHandle(
                    width: sidebarWidthBinding(maximumWidth: maximumSidebarWidth),
                    minimumWidth: minimumSidebarWidth,
                    maximumWidth: maximumSidebarWidth
                )

                VStack(spacing: 0) {
                    BrowserToolbarView()
                    Divider()
                    BreadcrumbBar()
                    Divider()
                    FileActionBarView()
                    Divider()
                    FileListView()
                    Divider()
                    StatusBarView()
                }
                .frame(minWidth: minimumFileBrowserWidth, minHeight: minimumFileBrowserHeight)
                .layoutPriority(1)
            }
            .frame(width: availableWidth, height: availableHeight, alignment: .leading)
        }
        .frame(minWidth: minimumWindowWidth, minHeight: minimumWindowHeight, alignment: .leading)
        .background {
            WindowReader(window: $hostingWindow)
        }
        .onAppear {
            installPasteboardShortcutMonitor()
        }
        .onDisappear {
            removePasteboardShortcutMonitor()
        }
        .sheet(isPresented: $browser.isConnectServerDialogPresented) {
            ConnectServerSheet()
                .environmentObject(browser)
        }
        .sheet(isPresented: $browser.isExternalToolsSettingsPresented) {
            ExternalToolsSettingsSheet()
                .environmentObject(browser)
        }
        .sheet(item: $browser.renameRequest) { request in
            RenameSheet(
                request: request,
                onCommit: { newName in
                    browser.rename(url: request.url, to: newName)
                },
                onCancel: {
                    browser.cancelRename()
                }
            )
        }
        .alert(
            L10n.string("Action Failed"),
            isPresented: Binding(
                get: { browser.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        browser.clearError()
                    }
                }
            )
        ) {
            Button(L10n.string("OK")) {
                browser.clearError()
            }
        } message: {
            Text(browser.errorMessage ?? "")
        }
    }

    private func sidebarMaximumWidth(for availableWidth: CGFloat) -> CGFloat {
        let contentAwareMaximum = availableWidth - resizeHandleWidth - minimumFileBrowserWidth
        return max(minimumSidebarWidth, min(preferredMaximumSidebarWidth, contentAwareMaximum))
    }

    private func clampedSidebarWidth(maximumWidth: CGFloat) -> CGFloat {
        min(max(sidebarWidth, minimumSidebarWidth), maximumWidth)
    }

    private func sidebarWidthBinding(maximumWidth: CGFloat) -> Binding<CGFloat> {
        Binding(
            get: {
                clampedSidebarWidth(maximumWidth: maximumWidth)
            },
            set: { newValue in
                sidebarWidth = min(max(newValue, minimumSidebarWidth), maximumWidth)
            }
        )
    }

    private func installPasteboardShortcutMonitor() {
        guard pasteboardShortcutMonitor == nil else {
            return
        }

        pasteboardShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard shouldHandleFilePasteboardShortcut(event) else {
                return event
            }

            switch event.charactersIgnoringModifiers?.lowercased() {
            case "x":
                browser.cutSelection()
                return nil
            case "c":
                browser.copySelection()
                return nil
            case "v":
                browser.pasteIntoCurrentFolder()
                return nil
            default:
                return event
            }
        }
    }

    private func removePasteboardShortcutMonitor() {
        if let pasteboardShortcutMonitor {
            NSEvent.removeMonitor(pasteboardShortcutMonitor)
            self.pasteboardShortcutMonitor = nil
        }
    }

    private func shouldHandleFilePasteboardShortcut(_ event: NSEvent) -> Bool {
        guard hostingWindow == nil || hostingWindow === NSApp.keyWindow else {
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        guard flags.contains(.command),
              !flags.contains(.option),
              !flags.contains(.control),
              ["x", "c", "v"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "") else {
            return false
        }

        return !browser.isTextInputActive
    }
}

struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()

        DispatchQueue.main.async {
            window = view.window
        }

        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            window = view.window
        }
    }
}

struct SidebarResizeHandle: View {
    @Binding var width: CGFloat

    let minimumWidth: CGFloat
    let maximumWidth: CGFloat

    @State private var dragStartWidth: CGFloat?
    @State private var isHovering = false
    @State private var isCursorPushed = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)

            Rectangle()
                .fill(isHovering ? Color.accentColor.opacity(0.22) : Color.clear)
                .frame(width: 8)
        }
        .frame(width: 8)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStartWidth == nil {
                        dragStartWidth = width
                    }

                    let proposedWidth = (dragStartWidth ?? width) + value.translation.width
                    width = min(max(proposedWidth, minimumWidth), maximumWidth)
                }
                .onEnded { _ in
                    dragStartWidth = nil
                }
        )
        .onHover { hovering in
            isHovering = hovering

            if hovering, !isCursorPushed {
                NSCursor.resizeLeftRight.push()
                isCursorPushed = true
            } else if !hovering, isCursorPushed {
                NSCursor.pop()
                isCursorPushed = false
            }
        }
        .onDisappear {
            if isCursorPushed {
                NSCursor.pop()
                isCursorPushed = false
            }
        }
        .help(L10n.string("Resize sidebar"))
        .accessibilityLabel(L10n.string("Resize sidebar"))
    }
}

struct SidebarView: View {
    @EnvironmentObject private var browser: FileBrowserViewModel
    @State private var isFavoritesDropTargeted = false
    @State private var draggedLocationID: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(browser.sidebarSections) { section in
                    SidebarLocationsSection(
                        section: section,
                        acceptsFavoriteDrops: section.title == "Favorites",
                        isDropTargeted: section.title == "Favorites" ? $isFavoritesDropTargeted : .constant(false),
                        allowsLocationReordering: section.title == "Locations",
                        draggedLocationID: $draggedLocationID
                    )
                }

                SidebarNetworkSection()
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct SidebarLocationsSection: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    let section: SidebarSection
    let acceptsFavoriteDrops: Bool
    @Binding var isDropTargeted: Bool
    let allowsLocationReordering: Bool
    @Binding var draggedLocationID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(L10n.string(section.title))
                .font(.caption.weight(.semibold))
                .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 3)
                .contentShape(Rectangle())
                .modifier(
                    FavoriteDropTargetModifier(
                        isEnabled: acceptsFavoriteDrops,
                        isTargeted: $isDropTargeted
                    )
                )

            ForEach(section.locations) { location in
                SidebarLocationRow(location: location)
                    .modifier(
                        FavoriteDropTargetModifier(
                            isEnabled: acceptsFavoriteDrops,
                            isTargeted: $isDropTargeted
                        )
                    )
                    .modifier(
                        LocationReorderModifier(
                            isEnabled: allowsLocationReordering,
                            location: location,
                            draggedLocationID: $draggedLocationID
                        )
                    )
            }

            if allowsLocationReordering {
                Color.clear
                    .frame(height: 10)
                    .contentShape(Rectangle())
                    .onDrop(
                        of: [UTType.plainText.identifier],
                        delegate: LocationReorderEndDropDelegate(
                            browser: browser,
                            draggedLocationID: $draggedLocationID
                        )
                    )
            }
        }
        .padding(.bottom, 4)
        .background {
            if acceptsFavoriteDrops {
                FavoritesDropTargetView(isTargeted: $isDropTargeted)
                    .environmentObject(browser)
            }
        }
        .modifier(
            FavoriteDropTargetModifier(
                isEnabled: acceptsFavoriteDrops,
                isTargeted: $isDropTargeted
            )
        )
    }
}

struct LocationReorderModifier: ViewModifier {
    let isEnabled: Bool
    let location: SidebarLocation
    @Binding var draggedLocationID: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .onDrag {
                    draggedLocationID = location.id
                    return NSItemProvider(object: location.id as NSString)
                }
                .onDrop(
                    of: [UTType.plainText.identifier],
                    delegate: LocationReorderDropDelegate(
                        browser: browser,
                        location: location,
                        draggedLocationID: $draggedLocationID
                    )
                )
        } else {
            content
        }
    }

    @EnvironmentObject private var browser: FileBrowserViewModel
}

struct LocationReorderDropDelegate: DropDelegate {
    let browser: FileBrowserViewModel
    let location: SidebarLocation
    @Binding var draggedLocationID: String?

    func validateDrop(info: DropInfo) -> Bool {
        draggedLocationID != nil
    }

    func dropEntered(info: DropInfo) {
        guard let sourceID = draggedLocationID,
              sourceID != location.id else {
            return
        }

        browser.moveSidebarLocation(sourceID: sourceID, over: location.id)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedLocationID = nil
        return true
    }
}

struct LocationReorderEndDropDelegate: DropDelegate {
    let browser: FileBrowserViewModel
    @Binding var draggedLocationID: String?

    func validateDrop(info: DropInfo) -> Bool {
        draggedLocationID != nil
    }

    func dropEntered(info: DropInfo) {
        guard let sourceID = draggedLocationID else {
            return
        }

        browser.moveSidebarLocationToEnd(sourceID: sourceID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        if let sourceID = draggedLocationID {
            browser.moveSidebarLocationToEnd(sourceID: sourceID)
        }

        draggedLocationID = nil
        return true
    }
}

struct FavoriteDropTargetModifier: ViewModifier {
    @EnvironmentObject private var browser: FileBrowserViewModel

    let isEnabled: Bool
    @Binding var isTargeted: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.onDrop(
                of: [UTType.fileURL.identifier, UTType.url.identifier, UTType.plainText.identifier],
                isTargeted: $isTargeted
            ) { providers in
                browser.addFavoriteFolders(from: providers)
            }
        } else {
            content
        }
    }
}

struct SidebarNetworkSection: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(L10n.string("Network"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 3)

            Button {
                browser.promptConnectToServer()
            } label: {
                Label(L10n.string("Connect..."), systemImage: "network")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Button {
                browser.reloadLocations()
            } label: {
                Label(L10n.string("Reload Locations"), systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .help(L10n.string("Rescan cloud folders, mounted drives, and network volumes"))
        }
        .padding(.bottom, 4)
    }
}

struct SidebarLocationRow: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    let location: SidebarLocation

    var body: some View {
        Button {
            browser.open(location)
        } label: {
            Label {
                Text(L10n.string(location.title))
            } icon: {
                Image(systemName: location.systemImageName)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .contextMenu {
            LocationContextMenu(location: location)
        }
    }
}

struct BrowserToolbarView: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    var body: some View {
        HStack(spacing: 8) {
            ToolbarIconButton(systemImageName: "chevron.left", help: "Back") {
                browser.goBack()
            }
            .disabled(!browser.canGoBack)

            ToolbarIconButton(systemImageName: "chevron.right", help: "Forward") {
                browser.goForward()
            }
            .disabled(!browser.canGoForward)

            ToolbarIconButton(systemImageName: "arrow.up", help: "Up") {
                browser.goUp()
            }
            .disabled(!browser.canGoUp)

            ToolbarIconButton(systemImageName: "arrow.clockwise", help: "Reload") {
                browser.reload()
            }

            TextField(L10n.string("Path"), text: $browser.addressText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: NSFont.systemFontSize, design: .monospaced))
                .lineLimit(1)
                .onSubmit {
                    browser.submitAddress()
                }
                .help(L10n.string("Path"))
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .layoutPriority(1)

            Button {
                browser.submitAddress()
            } label: {
                Image(systemName: "arrow.right.circle")
            }
            .help(L10n.string("Go"))

            Toggle(isOn: $browser.showHiddenFiles) {
                Image(systemName: browser.showHiddenFiles ? "eye" : "eye.slash")
            }
            .toggleStyle(.button)
            .help(L10n.string("Show hidden files"))

            ToolbarIconButton(systemImageName: "folder.badge.plus", help: "New Folder") {
                browser.createFolder()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct ToolbarIconButton: View {
    let systemImageName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImageName)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .help(L10n.string(help))
    }
}

struct BreadcrumbBar: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(browser.breadcrumbs.enumerated()), id: \.element.id) { index, crumb in
                    Button {
                        browser.navigate(to: crumb.url)
                    } label: {
                        Text(crumb.title)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )

                    if index < browser.breadcrumbs.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .frame(height: 38)
    }
}

struct FileActionBarView: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    var body: some View {
        HStack(spacing: 8) {
            Picker(L10n.string("View"), selection: $browser.viewMode) {
                Image(systemName: "list.bullet")
                    .tag(BrowserViewMode.list)

                Image(systemName: "square.grid.2x2")
                    .tag(BrowserViewMode.icons)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 92)
            .help(L10n.string("View mode"))

            Divider()
                .frame(height: 22)

            ToolbarIconButton(systemImageName: "arrow.up", help: "Up") {
                browser.goUp()
            }
            .disabled(!browser.canGoUp)

            ToolbarIconButton(systemImageName: "folder.badge.plus", help: "New Folder") {
                browser.createFolder()
            }

            ToolbarIconButton(systemImageName: "doc.badge.plus", help: "New File") {
                browser.createFile()
            }

            ToolbarIconButton(systemImageName: "trash", help: "Move to Trash") {
                browser.trashSelection()
            }
            .disabled(browser.selectedIDs.isEmpty)

            Divider()
                .frame(height: 22)

            ToolbarIconButton(systemImageName: "dot.radiowaves.left.and.right", help: "AirDrop") {
                browser.shareSelectionViaAirDrop()
            }
            .disabled(browser.selectedIDs.isEmpty)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(browser.externalTools) { tool in
                        ExternalToolToolbarButton(tool: tool)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ToolbarIconButton(systemImageName: "gearshape", help: "Configure External Tools") {
                browser.showExternalToolsSettings()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: 42)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ExternalToolToolbarButton: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    let tool: ExternalTool

    var body: some View {
        Button {
            browser.openExternalTool(tool)
        } label: {
            ExternalToolIconView(tool: tool, size: 18) {
                browser.applicationIcon(for: tool)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .help(String(format: L10n.string("Open with %@"), tool.title))
        .disabled(!browser.canOpenExternalTool(tool))
    }
}

struct ExternalToolIconView: View {
    let tool: ExternalTool
    let size: CGFloat
    let applicationIcon: () -> NSImage?

    var body: some View {
        if let icon = applicationIcon() {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: tool.systemImageName)
                .frame(width: size, height: size)
        }
    }
}

struct ExternalToolsSettingsSheet: View {
    @EnvironmentObject private var browser: FileBrowserViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var tools: [ExternalTool] = []
    @State private var selectedToolID: UUID?

    private var selectedIndex: Int? {
        guard let selectedToolID else {
            return nil
        }

        return tools.firstIndex { $0.id == selectedToolID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("External Tools"))
                .font(.title3.weight(.semibold))

            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 8) {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(tools) { tool in
                                Button {
                                    selectedToolID = tool.id
                                } label: {
                                    HStack(spacing: 8) {
                                        ExternalToolIconView(tool: tool, size: 18) {
                                            applicationIcon(for: tool)
                                        }

                                        Text(tool.title)
                                            .lineLimit(1)

                                        Spacer()
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(selectedToolID == tool.id ? Color.accentColor.opacity(0.18) : Color.clear)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(width: 220, height: 310)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )

                    HStack(spacing: 6) {
                        ToolbarIconButton(systemImageName: "plus", help: "Add Application Tool") {
                            addApplicationTool()
                        }

                        ToolbarIconButton(systemImageName: "terminal", help: "Add Terminal Tool") {
                            addTerminalTool()
                        }

                        ToolbarIconButton(systemImageName: "arrow.up", help: "Move Up") {
                            moveSelectedTool(offset: -1)
                        }
                        .disabled(selectedIndex == nil || selectedIndex == 0)

                        ToolbarIconButton(systemImageName: "arrow.down", help: "Move Down") {
                            moveSelectedTool(offset: 1)
                        }
                        .disabled(selectedIndex == nil || selectedIndex == tools.count - 1)

                        ToolbarIconButton(systemImageName: "trash", help: "Delete Tool") {
                            deleteSelectedTool()
                        }
                        .disabled(selectedIndex == nil)
                    }
                }

                Divider()
                    .frame(height: 350)

                if let selectedIndex {
                    ExternalToolEditorView(tool: $tools[selectedIndex])
                        .frame(width: 390, alignment: .topLeading)
                } else {
                    Text(L10n.string("Select a tool to edit."))
                        .foregroundStyle(.secondary)
                        .frame(width: 390, height: 320, alignment: .center)
                }
            }

            HStack {
                Button(L10n.string("Restore Defaults")) {
                    tools = ExternalTool.defaultTools
                    selectedToolID = tools.first?.id
                }

                Spacer()

                Button(L10n.string("Cancel")) {
                    dismiss()
                }

                Button(L10n.string("Save")) {
                    browser.saveExternalTools(tools)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 690)
        .onAppear {
            tools = browser.externalTools
            selectedToolID = tools.first?.id
        }
    }

    private func addApplicationTool() {
        let tool = ExternalTool(
            title: L10n.string("New Tool"),
            systemImageName: "app",
            iconMode: .applicationIcon,
            kind: .application,
            target: .selectedFolder
        )
        tools.append(tool)
        selectedToolID = tool.id
    }

    private func addTerminalTool() {
        let tool = ExternalTool(
            title: "Terminal",
            systemImageName: "terminal",
            iconMode: .applicationIcon,
            kind: .terminal,
            target: .currentFolder
        )
        tools.append(tool)
        selectedToolID = tool.id
    }

    private func deleteSelectedTool() {
        guard let selectedIndex else {
            return
        }

        tools.remove(at: selectedIndex)
        selectedToolID = tools.indices.contains(selectedIndex)
            ? tools[selectedIndex].id
            : tools.last?.id
    }

    private func moveSelectedTool(offset: Int) {
        guard let selectedIndex else {
            return
        }

        let destinationIndex = selectedIndex + offset
        guard tools.indices.contains(destinationIndex) else {
            return
        }

        tools.swapAt(selectedIndex, destinationIndex)
    }

    private func applicationIcon(for tool: ExternalTool) -> NSImage? {
        guard tool.iconMode == .applicationIcon else {
            return nil
        }

        if let applicationPath = tool.applicationPath,
           FileManager.default.fileExists(atPath: applicationPath) {
            return NSWorkspace.shared.icon(forFile: applicationPath)
        }

        switch tool.kind {
        case .terminal:
            let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
                ?? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            return NSWorkspace.shared.icon(forFile: terminalURL.path)
        case .iTerm:
            if let iTermURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") {
                return NSWorkspace.shared.icon(forFile: iTermURL.path)
            }
        case .application:
            break
        }

        for bundleIdentifier in tool.bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }

        return nil
    }
}

struct ExternalToolEditorView: View {
    @Binding var tool: ExternalTool

    private var bundleIdentifiersText: Binding<String> {
        Binding(
            get: {
                tool.bundleIdentifiers.joined(separator: ", ")
            },
            set: { newValue in
                tool.bundleIdentifiers = newValue
                    .split { character in
                        character == "," || character == " " || character == "\n"
                    }
                    .map(String.init)
            }
        )
    }

    private var applicationPathText: Binding<String> {
        Binding(
            get: {
                tool.applicationPath ?? ""
            },
            set: { newValue in
                tool.applicationPath = newValue.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent(L10n.string("Name")) {
                TextField(L10n.string("Name"), text: $tool.title)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent(L10n.string("Tool Type")) {
                Picker(L10n.string("Tool Type"), selection: $tool.kind) {
                    ForEach(ExternalToolKind.allCases) { kind in
                        Text(L10n.string(kind.titleKey)).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            LabeledContent(L10n.string("Open Target")) {
                Picker(L10n.string("Open Target"), selection: $tool.target) {
                    ForEach(ExternalToolTarget.allCases) { target in
                        Text(L10n.string(target.titleKey)).tag(target)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            LabeledContent(L10n.string("Icon")) {
                Picker(L10n.string("Icon"), selection: $tool.iconMode) {
                    ForEach(ExternalToolIconMode.allCases) { mode in
                        Text(L10n.string(mode.titleKey)).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            LabeledContent(L10n.string("SF Symbol")) {
                TextField(L10n.string("SF Symbol"), text: $tool.systemImageName)
                    .textFieldStyle(.roundedBorder)
            }

            if tool.kind == .application {
                LabeledContent(L10n.string("Bundle identifiers")) {
                    TextField("com.example.App", text: bundleIdentifiersText)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledContent(L10n.string("Application path")) {
                    TextField("/Applications/App.app", text: applicationPathText)
                        .textFieldStyle(.roundedBorder)
                }

                Button(L10n.string("Choose Application...")) {
                    chooseApplication()
                }
            }
        }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        tool.applicationPath = url.path

        if let bundle = Bundle(url: url) {
            if let bundleIdentifier = bundle.bundleIdentifier {
                tool.bundleIdentifiers = [bundleIdentifier]
            }

            let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String

            if let displayName = displayName?.nilIfEmpty,
               tool.title == L10n.string("New Tool") || tool.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                tool.title = displayName
            }
        }

        tool.iconMode = .applicationIcon
    }
}

struct FileListView: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    var body: some View {
        VStack(spacing: 0) {
            if browser.viewMode == .list {
                FileHeaderRow()
            }

            if browser.items.isEmpty {
                Spacer()
                Text(L10n.string("Empty Folder"))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                switch browser.viewMode {
                case .list:
                    FileListRowsView()
                case .icons:
                    FileIconGridView()
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            browser.activateFilePane()
        }
        .onDrop(
            of: MihakoTransferType.urlDropTypeIdentifiers,
            isTargeted: nil
        ) { providers in
            browser.dropItems(from: providers, into: browser.currentURL)
        }
        .contextMenu {
            FolderContextMenu()
        }
    }
}

struct FileListRowsView: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(browser.items) { item in
                    FileListRowContainer(item: item)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct FileListRowContainer: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    let item: FileItem

    private var isSelected: Bool {
        browser.selectedIDs.contains(item.url)
    }

    var body: some View {
        FileRow(item: item)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
            .contextMenu {
                FileContextMenu(item: item)
            }
            .simultaneousGesture(TapGesture(count: 1).onEnded {
                browser.select(item)
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                browser.select(item)
                browser.open(item)
            })
            .overlay(FileDragInteractionView(item: item).environmentObject(browser))
            .onDrop(
                of: MihakoTransferType.urlDropTypeIdentifiers,
                isTargeted: nil
            ) { providers in
                guard item.canNavigateInto else {
                    return false
                }

                return browser.dropItems(from: providers, into: item.url)
            }
    }
}

struct FileIconGridView: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    private let columns = [
        GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(browser.items) { item in
                    FileIconCell(item: item)
                        .contextMenu {
                            FileContextMenu(item: item)
                        }
                        .simultaneousGesture(TapGesture(count: 1).onEnded {
                            browser.select(item)
                        })
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            browser.select(item)
                            browser.open(item)
                        })
                        .overlay(FileDragInteractionView(item: item).environmentObject(browser))
                        .onDrop(
                            of: MihakoTransferType.urlDropTypeIdentifiers,
                            isTargeted: nil
                        ) { providers in
                            guard item.canNavigateInto else {
                                return false
                            }

                            return browser.dropItems(from: providers, into: item.url)
                        }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

struct FileDragInteractionView: NSViewRepresentable {
    @EnvironmentObject private var browser: FileBrowserViewModel

    let item: FileItem

    func makeNSView(context: Context) -> FileDragInteractionNSView {
        FileDragInteractionNSView()
    }

    func updateNSView(_ view: FileDragInteractionNSView, context: Context) {
        view.browser = browser
        view.item = item
    }
}

@MainActor
final class FileDragInteractionNSView: NSView, NSDraggingSource {
    weak var browser: FileBrowserViewModel?
    var item: FileItem?

    private var mouseDownEvent: NSEvent?
    private var didStartDrag = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        switch NSApp.currentEvent?.type {
        case .rightMouseDown, .rightMouseDragged, .rightMouseUp, .otherMouseDown, .otherMouseDragged, .otherMouseUp:
            return nil
        default:
            return super.hitTest(point)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let browser, let item else {
            return
        }

        didStartDrag = false
        mouseDownEvent = event
        browser.activateFilePane()

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !browser.selectedIDs.contains(item.url) || flags.contains(.command) || flags.contains(.shift) {
            browser.select(item)
        }

        if event.clickCount == 2 {
            browser.open(item)
            mouseDownEvent = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didStartDrag,
              let browser,
              let item,
              let mouseDownEvent else {
            return
        }

        let urls = browser.draggedURLsForDraggingSession(for: item)
        let location = convert(mouseDownEvent.locationInWindow, from: nil)
        let draggingItems = urls.enumerated().map { index, url in
            let draggingItem = NSDraggingItem(pasteboardWriter: browser.pasteboardWriter(forDraggedURL: url))
            let offset = CGFloat(index) * 3
            draggingItem.setDraggingFrame(
                NSRect(x: location.x - 16 + offset, y: location.y - 16 - offset, width: 32, height: 32),
                contents: browser.dragImage(forDraggedURL: url)
            )
            return draggingItem
        }

        guard !draggingItems.isEmpty else {
            return
        }

        didStartDrag = true
        beginDraggingSession(with: draggingItems, event: mouseDownEvent, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
        didStartDrag = false
    }

    override func rightMouseDown(with event: NSEvent) {
        nextResponder?.rightMouseDown(with: event)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        false
    }
}

struct FileIconCell: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    let item: FileItem

    private var isSelected: Bool {
        browser.selectedIDs.contains(item.url)
    }

    var body: some View {
        VStack(spacing: 7) {
            FileSystemIcon(item: item, size: 46)
                .frame(width: 52, height: 46)

            Text(item.displayName)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(width: 92, height: 34, alignment: .top)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .frame(width: 108, height: 104)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

struct FileSystemIcon: View {
    let item: FileItem
    let size: CGFloat

    var body: some View {
        if SFTPClient.isSFTPURL(item.url) || S3Client.isS3URL(item.url) {
            Image(systemName: item.systemImageName)
                .resizable()
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        }
    }
}

struct FileHeaderRow: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    var body: some View {
        HStack(spacing: 0) {
            HeaderCell(title: "Name", column: .name)
                .frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)

            HeaderCell(title: "Modified", column: .modifiedAt)
                .frame(width: 180, alignment: .leading)

            HeaderCell(title: "Size", column: .size)
                .frame(width: 110, alignment: .trailing)

            HeaderCell(title: "Kind", column: .kind)
                .frame(width: 170, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct HeaderCell: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    let title: String
    let column: FileSortColumn

    var body: some View {
        Button {
            browser.sort(by: column)
        } label: {
            HStack(spacing: 4) {
                Text(L10n.string(title))

                if browser.sortColumn == column {
                    Image(systemName: browser.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
            }
            .frame(maxWidth: .infinity, alignment: column == .size ? .trailing : .leading)
        }
        .buttonStyle(.plain)
    }
}

struct FileRow: View {
    let item: FileItem

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                FileSystemIcon(item: item, size: 20)

                Text(item.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)

            Text(item.formattedModifiedAt)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 180, alignment: .leading)

            Text(item.formattedSize)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 110, alignment: .trailing)

            Text(L10n.string(item.kind))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 170, alignment: .leading)
        }
        .font(.system(size: 13))
        .frame(height: 28)
        .contentShape(Rectangle())
    }
}

struct FileContextMenu: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    let item: FileItem

    var body: some View {
        Button(L10n.string("Open")) {
            browser.open(item)
        }

        Divider()

        Button(L10n.string("Rename")) {
            browser.beginRename(item)
        }

        Button(L10n.string("Duplicate")) {
            browser.duplicate(item)
        }

        Divider()

        Button(L10n.string("Copy")) {
            browser.selectOnly(item.url)
            browser.copySelection()
        }

        Button(L10n.string("Cut")) {
            browser.selectOnly(item.url)
            browser.cutSelection()
        }

        Button(L10n.string("Paste Into Folder")) {
            browser.paste(into: item.url)
        }
        .disabled(!item.canNavigateInto)

        Divider()

        Button(L10n.string("Copy Path")) {
            browser.copyPath(item)
        }

        Button(L10n.string("Reveal in Finder")) {
            browser.revealInFinder(item)
        }
        .disabled(SFTPClient.isSFTPURL(item.url) || S3Client.isS3URL(item.url))

        Button(L10n.string("Open in Terminal")) {
            browser.openInTerminal(item.url)
        }
        .disabled(S3Client.isS3URL(item.url))

        Button(L10n.string("Open in iTerm")) {
            browser.openIniTerm(item.url)
        }
        .disabled(!browser.isITermAvailable || S3Client.isS3URL(item.url))

        Divider()

        Button(L10n.string("Move to Trash")) {
            browser.selectOnly(item.url)
            browser.trashSelection()
        }
    }
}

struct FolderContextMenu: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    var body: some View {
        Button(L10n.string("New Folder")) {
            browser.createFolder()
        }

        Button(L10n.string("New File")) {
            browser.createFile()
        }

        Divider()

        Button(L10n.string("Paste")) {
            browser.pasteIntoCurrentFolder()
        }

        Divider()

        Button(L10n.string("Open in Terminal")) {
            browser.openInTerminal(browser.currentURL)
        }
        .disabled(browser.isCurrentS3)

        Button(L10n.string("Open in iTerm")) {
            browser.openIniTerm(browser.currentURL)
        }
        .disabled(!browser.isITermAvailable || browser.isCurrentS3)

        Divider()

        Button(L10n.string("Copy Path")) {
            browser.copyPath(browser.currentURL)
        }

        Button(L10n.string("Reveal in Finder")) {
            browser.revealInFinder(browser.currentURL)
        }
        .disabled(browser.isCurrentRemote)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

struct ConnectServerSheet: View {
    @EnvironmentObject private var browser: FileBrowserViewModel
    @FocusState private var focusedField: ConnectServerField?

    private enum ConnectServerField {
        case name
        case address
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("Connect"))
                    .font(.headline)

                Text(L10n.string("Choose a protocol and enter a remote address."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Picker(L10n.string("Protocol"), selection: $browser.connectProtocol) {
                ForEach(RemoteConnectionKind.allCases) { kind in
                    Text(L10n.string(kind.displayName)).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: browser.connectProtocol) { _, newValue in
                browser.connectServerAddress = newValue.defaultAddress
                browser.connectAWSProfile = ""

                if newValue == .s3 {
                    browser.refreshAWSProfiles()
                }
            }

            TextField(L10n.string("Location name (optional)"), text: $browser.connectServerDisplayName)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .name)
                .onSubmit {
                    focusedField = .address
                }

            TextField(browser.connectProtocol.placeholder, text: $browser.connectServerAddress)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: NSFont.systemFontSize, design: .monospaced))
                .focused($focusedField, equals: .address)
                .onSubmit {
                    browser.commitConnectServerDialog()
                }

            if browser.connectProtocol == .s3 {
                Picker(L10n.string("AWS profile"), selection: $browser.connectAWSProfile) {
                    Text(L10n.string("Default")).tag("")

                    ForEach(browser.awsProfiles, id: \.self) { profile in
                        Text(profile).tag(profile)
                    }
                }
                .pickerStyle(.menu)
            }

            HStack {
                Spacer()

                Button(L10n.string("Cancel")) {
                    browser.cancelConnectServerDialog()
                }
                .keyboardShortcut(.cancelAction)

                Button(L10n.string("Connect")) {
                    browser.commitConnectServerDialog()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            if browser.connectProtocol == .s3 {
                browser.refreshAWSProfiles()
            }

            DispatchQueue.main.async {
                focusedField = .address
            }
        }
    }
}

struct LocationContextMenu: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    let location: SidebarLocation

    var body: some View {
        Button(L10n.string(location.isUnavailable ? "Reconnect" : "Open")) {
            browser.open(location)
        }

        Divider()

        Button(L10n.string("Open in Terminal")) {
            browser.openInTerminal(location.url)
        }
        .disabled(location.isUnavailable || S3Client.isS3URL(location.url))

        Button(L10n.string("Open in iTerm")) {
            browser.openIniTerm(location.url)
        }
        .disabled(!browser.isITermAvailable || location.isUnavailable || S3Client.isS3URL(location.url))

        Divider()

        Button(L10n.string("Copy Path")) {
            browser.copyPath(location.url)
        }
        .disabled(location.isUnavailable)

        Button(L10n.string("Reveal in Finder")) {
            browser.revealInFinder(location.url)
        }
        .disabled(location.isUnavailable || SFTPClient.isSFTPURL(location.url) || S3Client.isS3URL(location.url))

        if location.canDisconnect {
            Divider()

            Button(L10n.string("Disconnect")) {
                browser.disconnect(location)
            }
        }

        if location.canRemoveFromFavorites {
            Divider()

            Button(L10n.string("Remove from Favorites")) {
                browser.removeFavorite(location)
            }
        }
    }
}

struct StatusBarView: View {
    @EnvironmentObject private var browser: FileBrowserViewModel

    var body: some View {
        HStack(spacing: 12) {
            Text(L10n.format("items.count", browser.items.count))

            if !browser.selectedIDs.isEmpty {
                Text(L10n.format("items.selected", browser.selectedIDs.count))
            }

            if let operation = browser.pendingClipboardOperation {
                Text(L10n.string(operation.mode == .cut ? "Cut ready" : "Copy ready"))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(browser.currentDisplayAddress)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct RenameSheet: View {
    let request: RenameRequest
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @FocusState private var isFocused: Bool

    init(
        request: RenameRequest,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.onCommit = onCommit
        self.onCancel = onCancel
        _name = State(initialValue: request.currentName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("Rename"))
                .font(.headline)

            TextField(L10n.string("Name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit {
                    onCommit(name)
                }

            HStack {
                Spacer()

                Button(L10n.string("Cancel")) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button(L10n.string("Rename")) {
                    onCommit(name)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 380)
        .onAppear {
            isFocused = true
        }
    }
}
