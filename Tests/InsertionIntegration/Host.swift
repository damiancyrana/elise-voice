import AppKit
import WebKit

@MainActor
final class DelayedTextView: NSTextView {
    override func paste(_ sender: Any?) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1400))
            super.paste(sender)
        }
    }
}

@MainActor
final class IgnoringTextView: NSTextView {
    override func paste(_ sender: Any?) {}
}

@main
@MainActor
final class InsertionHost: NSObject, NSApplicationDelegate {
    let directory = URL(fileURLWithPath: CommandLine.arguments[1])
    var window: NSWindow!
    var emptyWindow: NSWindow?
    let field = NSTextField(string: "A😀B")
    let secure = NSSecureTextField(string: "")
    let text = NSTextView()
    let slow = DelayedTextView()
    let ignored = IgnoringTextView()
    let button = NSButton(title: "Non-text control", target: nil, action: nil)
    let web = WKWebView()
    var timer: Timer?
    var lastCommand = ""

    static func main() {
        let app = NSApplication.shared
        let delegate = InsertionHost()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 700, height: 620),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Elise insertion test — disposable fields"
        for (index, view) in [field, secure, text, slow, ignored, button].enumerated() {
            view.frame = NSRect(x: 20, y: 565 - index * 55, width: 650, height: 45)
            window.contentView!.addSubview(view)
        }
        text.string = "native"
        text.allowsUndo = true
        slow.string = "slow"
        ignored.string = "ignored"
        web.frame = NSRect(x: 20, y: 20, width: 650, height: 225)
        window.contentView!.addSubview(web)
        web.loadHTMLString("""
        <input id="plain" value="web" aria-label="web input">
        <div id="rich" contenteditable="true" role="textbox" aria-label="web editor">rich</div>
        <input id="password" type="password" aria-label="web password">
        <script>
        window.inputCount = 0;
        document.addEventListener('input', () => window.inputCount++);
        </script>
        """, baseURL: nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func poll() {
        guard let command = try? String(contentsOf: directory.appendingPathComponent("command"), encoding: .utf8),
              command != lastCommand else { return }
        lastCommand = command
        let parts = command.components(separatedBy: " ")
        let action = parts[1]
        if action == "quit" { NSApp.terminate(nil); return }
        if action == "opaque" {
            let empty = NSWindow(contentRect: NSRect(x: 250, y: 250, width: 400, height: 200),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            empty.title = "Elise test — no text field"
            empty.makeKeyAndOrderFront(nil)
            emptyWindow = empty
            reply(command)
            return
        }
        if action == "read" {
            web.evaluateJavaScript("JSON.stringify({plain: plain.value, rich: rich.innerText, inputCount: window.inputCount})") { value, _ in
                self.reply(command, webValue: value as? String)
            }
            return
        }
        emptyWindow?.orderOut(nil)
        window.makeKeyAndOrderFront(nil)
        let views: [String: NSView] = ["field": field, "secure": secure, "text": text,
                                      "slow": slow, "ignored": ignored, "button": button]
        if let view = views[action] {
            window.makeFirstResponder(view)
            if let editor = window.firstResponder as? NSTextView {
                editor.setSelectedRange(action == "field" ? NSRange(location: 1, length: 2)
                                                       : NSRange(location: editor.string.utf16.count, length: 0))
            }
            reply(command)
        } else {
            let id = action == "web" ? "plain" : (action == "rich" ? "rich" : "password")
            window.makeFirstResponder(web)
            web.evaluateJavaScript("""
            document.getElementById('\(id)').focus();
            if ('\(id)' == 'rich') {
                const s = window.getSelection(), r = document.createRange();
                r.selectNodeContents(rich); r.collapse(false); s.removeAllRanges(); s.addRange(r);
            } else { document.getElementById('\(id)').setSelectionRange(3, 3); }
            """) { _, _ in self.reply(command) }
        }
    }

    func reply(_ command: String, webValue: String? = nil) {
        let data: [String: Any] = ["command": command, "field": field.stringValue, "text": text.string,
                                   "slow": slow.string, "ignored": ignored.string, "web": webValue ?? ""]
        if let encoded = try? JSONSerialization.data(withJSONObject: data) {
            try? encoded.write(to: directory.appendingPathComponent("reply"), options: .atomic)
        }
    }
}
