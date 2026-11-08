import Testing
import Foundation
import AppKit
import SwiftUI
@testable import Olaz

@Suite @MainActor struct SavedReplyTests {
    private func reply(account: String = "a", shortcut: String = "/dia-chi", body: String = "Địa chỉ cửa hàng do người dùng nhập.") -> SavedReply {
        SavedReply(account: account, shortcut: shortcut, title: "Địa chỉ cửa hàng", body: body)
    }
    @Test func generatesValidCommandsFromVietnameseNames() throws {
        #expect(SavedReply.suggestedShortcut(for: "Địa chỉ cửa hàng") == "dia-chi-cua-hang")
        #expect(SavedReply.suggestedShortcut(for: "  GIỜ MỞ CỬA & Thanh toán!!! ") == "gio-mo-cua-thanh-toan")
        #expect(SavedReply.suggestedShortcut(for: " \n ") == "")
        #expect(SavedReply.suggestedShortcut(for: "🌸") == "mau")
        let generated = SavedReply.suggestedShortcut(for: String(repeating: "Địa chỉ ", count: 15))
        #expect(generated.count <= 40 && !generated.hasSuffix("-"))
        #expect(try reply(shortcut: generated).validated().shortcut == generated)
    }
    @Test func generatedCommandsAvoidDuplicatesWithoutExceedingTheLimit() throws {
        #expect(SavedReply.suggestedShortcut(for: "Địa chỉ", reserved: ["dia-chi", "dia-chi-2"]) == "dia-chi-3")
        let title = String(repeating: "a", count: 50)
        let first = SavedReply.suggestedShortcut(for: title)
        let second = SavedReply.suggestedShortcut(for: title, reserved: [first])
        #expect(second.count == 40 && second.hasSuffix("-2"))
        #expect(try reply(shortcut: second).validated().shortcut == second)
    }
    @Test func savesNormalizedCommandsAndRejectsDuplicatesWithinAccount() throws {
        let store = SavedReplyStore(url: nil)
        try store.save(reply(shortcut: " /Địa-Chỉ "))
        #expect(store.replies(account: "a").first?.shortcut == "dia-chi")
        #expect(throws: (any Error).self) { try store.save(reply(shortcut: "dia-chi")) }
        try store.save(reply(account: "b"))
        #expect(store.replies(account: "a").count == 1 && store.replies(account: "b").count == 1)
        #expect(store.replies(account: "c").isEmpty)
    }
    @Test func validatesCommandsAndBodyWithoutRemovingFormatting() throws {
        for shortcut in ["/", "//dia-chi", "dia chi", "a/b", "-a", "a.*", String(repeating: "a", count: 41)] {
            #expect(throws: (any Error).self) { try reply(shortcut: shortcut).validated() }
        }
        for body in [" \n", "bad\0text", String(repeating: "a", count: 8001)] {
            #expect(throws: (any Error).self) { try reply(body: body).validated() }
        }
        #expect(try reply(body: "  Dòng một\nDòng hai  ").validated().body == "  Dòng một\nDòng hai  ")
    }
    @Test func savesEditsAndPreventsMovingAnExistingTemplateAcrossAccounts() throws {
        let store = SavedReplyStore(url: nil)
        var template = reply(); try store.save(template)
        template.body = "Nội dung đã sửa"; template.shortcut = "/dia-chi-moi"; try store.save(template)
        #expect(store.matches(account: "a", query: "dia-chi-moi").first?.body == "Nội dung đã sửa")
        #expect(store.replies(account: "a").count == 1)
        template.account = "b"
        #expect(throws: (any Error).self) { try store.save(template) }
    }
    @Test func deleteIsRecoverableAndRestoreChecksNewShortcutConflicts() throws {
        let store = SavedReplyStore(url: nil)
        let original = reply(); try store.save(original)
        try store.remove(original.id, account: "b")
        #expect(store.replies(account: "a").count == 1)
        try store.remove(original.id, account: "a")
        #expect(store.matches(account: "a", query: "dia", slash: true).isEmpty)
        #expect(store.replies(account: "a", deleted: true).count == 1)
        try store.restore(original.id, account: "a")
        #expect(store.replies(account: "a").count == 1)
        try store.remove(original.id, account: "a")
        try store.save(reply())
        #expect(throws: (any Error).self) { try store.restore(original.id, account: "a") }
    }
    @Test func searchIsAccentInsensitiveAndExactCommandComesFirst() throws {
        let store = SavedReplyStore(url: nil)
        try store.save(reply(shortcut: "dia-chi-cu"))
        try store.save(reply())
        try store.save(SavedReply(account: "a", shortcut: "hotline", title: "Liên hệ", body: "Gọi hotline để biết địa chỉ."))
        #expect(store.matches(account: "a", query: "/địa-chỉ", slash: true).map(\.shortcut) == ["dia-chi", "dia-chi-cu"])
        #expect(store.matches(account: "a", query: "hotline").count == 1)
        #expect(store.matches(account: "b", query: "", slash: true).isEmpty)
    }
    @Test func persistsEditsAndTrashWithPrivatePermissions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("SavedReplies/replies.json")
        let store = SavedReplyStore(url: url)
        var template = reply(); try store.save(template)
        template.body = "Nội dung mới\nCó xuống dòng"; try store.save(template)
        let restored = SavedReplyStore(url: url)
        #expect(restored.replies(account: "a").first?.body == template.body)
        try restored.remove(template.id, account: "a")
        let reopened = SavedReplyStore(url: url)
        #expect(reopened.replies(account: "a").isEmpty && reopened.replies(account: "a", deleted: true).count == 1)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }
    @Test func invalidSavedFileCannotBeSilentlyOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not JSON".utf8).write(to: url)
        let store = SavedReplyStore(url: url)
        #expect(store.storageError != nil)
        #expect(throws: (any Error).self) { try store.save(reply()) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "not JSON")
    }
    @Test func queryUsesCaretAndUTF16AndReplacesTheWholeToken() throws {
        let text = "😀 Xin chào /dia-chi sau"
        let token = (text as NSString).range(of: "/dia-chi")
        let query = try #require(SavedReplyQuery.detect(in: text, selection: NSRange(location: token.location + 3, length: 0)))
        #expect(query.range == token && query.text == "di" && query.token == "/dia-chi")
        #expect(SavedReplyQuery.detect(in: "/", selection: NSRange(location: 1, length: 0))?.text == "")
        #expect(SavedReplyQuery.detect(in: "Dòng một\n/địa-chỉ", selection: NSRange(location: ("Dòng một\n/địa-chỉ" as NSString).length, length: 0))?.text == "địa-chỉ")
    }
    @Test func queryRejectsURLsPathsSelectionAndIMEComposition() {
        for text in ["https://example.com/dia-chi", "abc/dia-chi", "/Users/name", "x /" + String(repeating: "a", count: 41)] {
            #expect(SavedReplyQuery.detect(in: text, selection: NSRange(location: (text as NSString).length, length: 0)) == nil)
        }
        #expect(SavedReplyQuery.detect(in: "/Users/name", selection: NSRange(location: 3, length: 0)) == nil)
        #expect(SavedReplyQuery.detect(in: "/dia-chi", selection: NSRange(location: 8, length: 0), composing: true) == nil)
        #expect(SavedReplyQuery.detect(in: "/dia-chi", selection: NSRange(location: 0, length: 8)) == nil)
        #expect(SavedReplyQuery.detect(in: "😀/dia", selection: NSRange(location: 1, length: 0)) == nil)
        #expect(SavedReplyQuery.detect(in: "a", selection: NSRange(location: NSNotFound, length: 0)) == nil)
    }
    @Test func insertionPreservesOtherDraftTextMentionsAndUndo() throws {
        let box = ComposerState()
        let tv = TestTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 120))
        tv.useTestUndo = true
        tv.allowsUndo = true; tv.isRichText = false
        let handle = ComposerHandle(); handle.textView = tv
        let parent = ComposerTextView(text: Binding(get: { box.text }, set: { box.text = $0 }), mentions: Binding(get: { box.mentions }, set: { box.mentions = $0 }), height: .constant(24), focusTick: 0, onSend: { box.sends += 1 })
        let coordinator = parent.makeCoordinator(); tv.delegate = coordinator
        let original = "😀 /dia-chi @Nam cuối"
        let mention = (original as NSString).range(of: "@Nam")
        ComposerTextView.setContent(tv, text: original, mentions: [Mention(uid: "nam", pos: mention.location, len: mention.length, isAll: false)])
        let range = (original as NSString).range(of: "/dia-chi")
        tv.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
        let query = try #require(SavedReplyQuery.detect(in: original, selection: tv.selectedRange()))
        tv.testUndo.beginUndoGrouping()
        #expect(handle.insertSavedReply("Địa chỉ mới\nDòng hai", replacing: query))
        #expect(tv.string == "😀 Địa chỉ mới\nDòng hai @Nam cuối")
        #expect(box.sends == 0)
        coordinator.syncMentions(tv)
        #expect(box.mentions.first?.pos == (tv.string as NSString).range(of: "@Nam").location)
        #expect(box.mentions.first?.uid == "nam")
        while tv.testUndo.groupingLevel > 0 { tv.testUndo.endUndoGrouping() }
        #expect(tv.testUndo.canUndo)
        tv.testUndo.undo()
        #expect(tv.string == original)
    }
    @Test func insertionRejectsStaleCommandsAndComposingText() throws {
        let tv = TestTextView(frame: .zero); let handle = ComposerHandle(); handle.textView = tv
        tv.string = "/dia-chi"; tv.setSelectedRange(NSRange(location: 8, length: 0))
        let query = try #require(SavedReplyQuery.detect(in: tv.string, selection: tv.selectedRange()))
        tv.string = "/gio-mo-cua"
        #expect(!handle.insertSavedReply("Should not insert", replacing: query))
        #expect(tv.string == "/gio-mo-cua")
        tv.composing = true
        #expect(!handle.insertSavedReply("Should not insert"))
    }
    @Test func returnExpandsFirstAndDoesNotSendWhileIMEIsOpen() throws {
        let box = ComposerState(), handle = ComposerHandle()
        let tv = TestTextView(frame: .zero); handle.textView = tv
        let parent = ComposerTextView(text: Binding(get: { box.text }, set: { box.text = $0 }), mentions: .constant([]), height: .constant(24), focusTick: 0,
            onSavedReplyQuery: { box.query = $0 }, onSuggestionKey: { key in
                guard key == .confirm, let query = box.query else { return false }
                return handle.insertSavedReply("Nội dung mẫu", replacing: query)
            }, onSend: { box.sends += 1 })
        let coordinator = parent.makeCoordinator(); tv.delegate = coordinator
        tv.string = "/dia-chi"; tv.setSelectedRange(NSRange(location: 8, length: 0)); coordinator.refreshQuery(tv)
        #expect(coordinator.textView(tv, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(tv.string == "Nội dung mẫu" && box.sends == 0)
        #expect(coordinator.textView(tv, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(box.sends == 1)
        tv.composing = true
        #expect(!coordinator.textView(tv, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(box.sends == 1)
    }
}

@MainActor private final class ComposerState {
    var text = ""
    var mentions: [Mention] = []
    var query: SavedReplyQuery?
    var sends = 0
}
@MainActor private final class TestTextView: NSTextView {
    let testUndo: UndoManager = { let manager = UndoManager(); manager.groupsByEvent = false; return manager }()
    var useTestUndo = false
    var composing = false
    override var undoManager: UndoManager? { useTestUndo ? testUndo : nil }
    override func hasMarkedText() -> Bool { composing }
}
