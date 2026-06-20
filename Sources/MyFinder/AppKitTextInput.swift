import AppKit

final class ShortcutFriendlyTextField: NSTextField {
    override var acceptsFirstResponder: Bool {
        true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        guard flags == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        switch key {
        case "x":
            return performTextAction(#selector(NSText.cut(_:)))
        case "c":
            return performTextAction(#selector(NSText.copy(_:)))
        case "v":
            return performTextAction(#selector(NSText.paste(_:)))
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    private func performTextAction(_ selector: Selector) -> Bool {
        if currentEditor() == nil {
            window?.makeFirstResponder(self)
            selectText(nil)
        }

        guard let editor = currentEditor() else {
            return false
        }

        NSApp.sendAction(selector, to: editor, from: self)
        return true
    }
}

@MainActor
final class ConnectServerDialog: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let input: ShortcutFriendlyTextField
    private var result: String?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 150),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        input = ShortcutFriendlyTextField(frame: .zero)

        super.init()

        panel.title = "Connect Server"
        panel.level = .modalPanel
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let contentView = NSView()
        panel.contentView = contentView

        let message = NSTextField(labelWithString: "Enter an SMB address.")
        let detail = NSTextField(labelWithString: "Use smb://server/share or server/share.")
        let connectButton = NSButton(title: "Connect", target: self, action: #selector(connect))
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))

        input.stringValue = "smb://"
        input.placeholderString = "smb://server/share"
        input.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        input.isEditable = true
        input.isSelectable = true
        input.usesSingleLineMode = true
        input.bezelStyle = .roundedBezel

        connectButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"

        for view in [message, detail, input, connectButton, cancelButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }

        NSLayoutConstraint.activate([
            message.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            message.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            message.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),

            detail.leadingAnchor.constraint(equalTo: message.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: message.trailingAnchor),
            detail.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 4),

            input.leadingAnchor.constraint(equalTo: message.leadingAnchor),
            input.trailingAnchor.constraint(equalTo: message.trailingAnchor),
            input.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 14),

            cancelButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            cancelButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),

            connectButton.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -8),
            connectButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor)
        ])
    }

    func run() -> String? {
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(input)
        input.selectText(nil)
        input.currentEditor()?.selectedRange = NSRange(location: input.stringValue.count, length: 0)

        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)

        return response == .OK ? result : nil
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal(withCode: .cancel)
    }

    @objc private func connect() {
        result = input.stringValue
        NSApp.stopModal(withCode: .OK)
    }

    @objc private func cancel() {
        NSApp.stopModal(withCode: .cancel)
    }
}
