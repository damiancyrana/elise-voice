import AppKit
import ApplicationServices

@main
@MainActor
struct InsertionIntegrationCheck {
    static var serial = 0
    static let directory = URL(fileURLWithPath: CommandLine.arguments[1])
    static let text = "Zażółć 👩‍💻"

    static func command(_ action: String) async throws -> [String: Any] {
        serial += 1
        let command = "\(serial) \(action)"
        try command.write(to: directory.appendingPathComponent("command"), atomically: true, encoding: .utf8)
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            if let data = try? Data(contentsOf: directory.appendingPathComponent("reply")),
               let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               reply["command"] as? String == command { return reply }
        }
        fatalError("Test host did not acknowledge \(action)")
    }

    static func capture() async throws -> TextInsertionTarget {
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == Int32(CommandLine.arguments[2]),
                     "Another app took focus during the interactive test")
        return try await TextInserter.captureTarget()
    }

    static func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    static func main() async throws {
        guard AXIsProcessTrusted() else {
            print("Run from a terminal with Accessibility permission.")
            exit(2)
        }
        let app = NSRunningApplication(processIdentifier: Int32(CommandLine.arguments[2])!)!
        app.activate()
        try await Task.sleep(for: .seconds(1))
        let clipboard = NSPasteboard.general
        let savedClipboard = clipboard.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        defer {
            clipboard.clearContents()
            let items = savedClipboard.map { saved in
                let item = NSPasteboardItem()
                for (type, data) in saved { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { clipboard.writeObjects(items) }
        }

        for (name, expected) in [("field", "A\(text)B"), ("text", "native\(text)")] {
            _ = try await command(name)
            clipboard.clearContents()
            clipboard.setString("previous clipboard", forType: .string)
            print("CHECK: \(name)"); fflush(nil)
            let target = try await capture()
            do {
                try await TextInserter.paste(text, into: target)
            } catch {
                let state = try await command("read")
                print("Native fixture on failure: \(state)")
                fflush(nil)
                throw error
            }
            let state = try await command("read")
            precondition(state[name] as? String == expected, "Wrong native model: \(name)")
            try await Task.sleep(for: .milliseconds(1200))
            precondition(clipboard.string(forType: .string) == "previous clipboard")
            if name == "text" {
                key(0x06, flags: .maskCommand)
                try await Task.sleep(for: .milliseconds(100))
                let undone = try await command("read")
                precondition(undone[name] as? String == "native", "Paste must be undoable")
            }
            print("PASS \(name): Unicode, selection, model, clipboard restoration")
        }

        for name in ["web", "rich"] {
            _ = try await command(name)
            try await Task.sleep(for: .milliseconds(200))
            print("CHECK: \(name)"); fflush(nil)
            let target = try await capture()
            try await TextInserter.paste(text, into: target)
            try await Task.sleep(for: .milliseconds(200))
            let state = try await command("read")
            let web = try JSONSerialization.jsonObject(with: Data((state["web"] as! String).utf8)) as! [String: Any]
            precondition(web[name == "web" ? "plain" : "rich"] as? String == "\(name == "web" ? "web" : "rich")\(text)")
            precondition((web["inputCount"] as? Int ?? 0) > 0)
            try await Task.sleep(for: .milliseconds(1200))
            print("PASS \(name): DOM model and input event")
        }

        for name in ["secure", "password"] {
            _ = try await command(name)
            try await Task.sleep(for: .milliseconds(200))
            do {
                _ = try await capture()
                fatalError("Password field accepted: \(name)")
            } catch TextInserterError.secureTextField {}
            print("PASS \(name): password rejected")
        }

        _ = try await command("text")
        let changed = try await capture()
        _ = try await command("field")
        do {
            try await TextInserter.paste(text, into: changed)
            fatalError("Focus change accepted")
        } catch TextInserterError.targetChanged {}
        precondition(clipboard.string(forType: .string) == text)
        print("PASS changed focus: no paste, transcript retained")

        _ = try await command("opaque")
        let opaque = try await capture()
        do {
            try await TextInserter.paste(text, into: opaque)
            fatalError("Unknown destination accepted")
        } catch TextInserterError.manualPasteRequired {}
        precondition(clipboard.string(forType: .string) == text)
        print("PASS unknown destination: capture succeeds, manual paste available")

        _ = try await command("text")
        let raced = try await capture()
        let replacement = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(30))
            clipboard.clearContents()
            clipboard.setString("unrelated copy", forType: .string)
        }
        do {
            try await TextInserter.paste(text, into: raced)
            fatalError("Changed clipboard was pasted")
        } catch TextInserterError.clipboardChanged {}
        try await replacement.value
        let unchanged = try await command("read")
        precondition(unchanged["text"] as? String == "native")
        print("PASS clipboard race: unrelated text was not pasted")

        let longText = String(repeating: "Zażółć 👩‍💻\n", count: 1000)
        try await TextInserter.paste(longText, into: raced)
        let longState = try await command("read")
        precondition(longState["text"] as? String == "native\(longText)")
        clipboard.clearContents()
        clipboard.setString("new user clipboard", forType: .string)
        try await Task.sleep(for: .milliseconds(1200))
        precondition(clipboard.string(forType: .string) == "new user clipboard")
        print("PASS long multiline paste and preservation of a subsequent user copy")

        for name in ["ignored", "slow"] {
            _ = try await command(name)
            print("CHECK: \(name)"); fflush(nil)
            let target = try await capture()
            do {
                try await TextInserter.paste(text, into: target)
                fatalError("Unacknowledged paste reported as verified")
            } catch TextInserterError.insertionUnverified {}
            try await Task.sleep(for: .milliseconds(1600))
            let state = try await command("read")
            precondition(state[name] as? String == (name == "slow" ? "slow\(text)" : "ignored"))
            precondition(clipboard.string(forType: .string) == text)
            print("PASS \(name): transcript retained, no duplicate retry")
        }
        print("All live insertion integration checks passed")
    }
}
