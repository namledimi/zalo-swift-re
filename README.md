# zalo-swift-re — Olaz

**A reverse-engineered, native macOS client for [Zalo](https://zalo.me), written in Swift.**

Olaz puts a native SwiftUI interface (Liquid Glass, sidebar + labels, native media viewer) on top of Zalo's
own client code. It does **not** re-implement Zalo's protocol. Instead it runs the **official Zalo PC renderer**
(`app.asar`) headless inside a `WKWebView` and supplies in Swift everything that Electron's preload and main
process used to provide. The UI is native SwiftUI driven by the official client's state.

Zalo PC does not need to be installed. On first launch Olaz downloads the official Zalo PC installer from VNG
(or copies an installed Zalo.app of the same version), checks VNG's code signature and keeps only `app.asar`
and `ZaloHelper.app` (calls, screenshots) in `~/Library/Application Support/Olaz/ZaloRuntime/` (~270 MB).
See [`ZaloRuntime/ZaloRuntimeInstaller.swift`](Sources/Olaz/ZaloRuntime/ZaloRuntimeInstaller.swift).

> [!IMPORTANT]
> **Unofficial project, not affiliated with or endorsed by VNG Corporation.** "Zalo" is a trademark of VNG.
> This is an interoperability and reverse-engineering research project. Using an unofficial client may
> conflict with Zalo's terms of service, so use it at your own risk with your own account.

## Features

- **Real QR login** (trusted-device QR → scan with Zalo on your phone → confirm), session restore on relaunch
- **Chat**: history and load older, send text / reply / mentions, reactions, typing, read state, realtime updates
- **Composer "+"**: photos / video, files, screenshot (Zalo's own `ZaloCap`), my contact card, reminders
- **Message actions**: forward, copy, recall, delete with undo, pin bar, star
- **Voice / video calls** through Zalo's own `ZaloCall` helper
- **E2EE conversations**, including E2EE video playback
- **Phone → PC message sync** with a native progress UI
- Contacts and friend requests, My Cloud, polls, stickers, labels, hidden chats (PIN), stranger folder,
  shared-media browser, quick switcher, native notifications

## Requirements

- macOS 26 or later, Xcode 27 (Swift 6 toolchain)
- A Zalo account and the Zalo app on your phone (for QR login)
- About 340 MB of download on first launch (Zalo PC's code, fetched from VNG)

Zalo allows **one desktop (PC) session per account**. If the official Zalo PC is also running, quit it while
using Olaz.

## Build & run

```bash
git clone https://github.com/qnguyen3/zalo-swift-re.git
cd zalo-swift-re

swift test                     # crypto parity (vs Node), asar reader, JSC/libsignal and host-script tests
./scripts/make-app.sh debug    # → build/Olaz.app (ad-hoc signed, JIT entitlement)
open build/Olaz.app            # real QR login — scan with Zalo on your phone
```

A new PC session has no message history except My Cloud, because Zalo keeps history on the phone. Use
**Đồng bộ tin nhắn từ điện thoại** (confirm on the phone) to import it.

### AI replies (local command bridge)

Open **Settings (⌘,) → AI** to configure **ChatGPT via Codex** or **Claude via Claude Code**. The bridge uses
the locally installed `codex` / `claude` executable and its existing login (`codex login` / `claude auth login`).
It does not automate the ChatGPT/Claude desktop windows. Executables in common install locations are detected
automatically; a custom path and an optional model can be set for each provider. **Kiểm tra công cụ** checks the
installed executable's version; it does not verify authentication or make a model request.
**Thử với câu hỏi này** checks a real model response using an editable question, configured instructions/documents,
and enabled MCP tools, without sending any Zalo message. Claude diagnostics show the names of MCP tools it actually
called. Replies requiring MCP data must look it up before claiming data is missing; configured source/tool names
are supplied to the model without credentials. Claude loads the explicitly granted tool catalog upfront. Failed
MCP startup or denied tool permissions prevent that generated answer from being sent automatically.

1. Enter reply instructions and optionally import UTF-8 `.txt`, `.md`, or `.json` reference documents (200 KB per
   file, 400 KB total). Imported content is copied into Olaz's local AI configuration.
2. Select up to 20 conversations for the signed-in Zalo account.
3. Choose **Soạn để duyệt** to review/edit an AI suggestion in its chat, or **Tự động gửi** to send automatically.
4. Turn on **Bật trợ lý AI**. The feature is off by default.

The open chat's **Thông tin** panel also has an **AI cho hội thoại này** switch below its quick actions. It controls
the same conversation selection as Settings → AI. **Cài đặt AI…** opens the AI tab directly; the app-wide switch
remains separate, and the chat panel shows when AI is paused globally.

Only new text messages received after enabling are eligible; existing/synced history does not trigger replies.
Messages arriving close together are combined after a configurable delay. A newer message, manual text reply,
configuration change, hidden/unavailable conversation, or logout cancels pending replies. Sending revalidates the
latest message against the renderer. Conversations need not be open, but **Olaz must remain running**.

The bridge runs on the Mac; model inference uses OpenAI/Anthropic's service. Selected recent messages and the
instructions/reference documents are sent to that provider. This is prompt context, not model training or a
semantic document index. Settings are stored at `~/Library/Application Support/Olaz/AI/settings.json` with
owner-only permissions. Model subprocesses use temporary input/output files that are removed on completion,
have a 90-second deadline, and run without personal MCP configuration/plugins and with command tools disabled.
Only explicitly enabled Plugin connections and their selected tools are provided to the assistant.
No actual conversations are sent by the unit tests (`swift test --filter AIReplyTests`).

Integration references: [Codex non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode),
[Claude Code programmatic mode](https://code.claude.com/docs/en/headless).

### Per-chat notes and tasks

Open **+ → Ghi chú riêng…** or **+ → Việc cần làm…**, or use their separate cards in the conversation inspector.
Each opens its own sheet: notes have a larger editor and save locally as you edit; tasks have Pending, Completed,
and Removed tabs and support completion, due dates, edits, recoverable removal, and restoration. Records are scoped to
both Zalo account and conversation, and do not send chat messages or feed AI automatically.
See the [Vietnamese guide](docs/OLAZ-CHAT-NOTES-TODO.vi.md).

### Saved replies

Use **+ → Tin nhắn mẫu** in a chat or **Settings → Tin nhắn mẫu** to save, edit, search, remove, and restore
per-account reply templates. Typing `/dia-chi` opens matching suggestions; Return/Tab inserts the selected text
without sending it. Insertion preserves the rest of the draft, mention offsets, and native undo. Templates stay
local across launches. See the [Vietnamese usage guide](docs/OLAZ-SAVED-REPLIES.vi.md).

### Work assistant and commerce sources

Plugin now includes a direct work-assistant chat, MCP product cards/quotes, customer records/follow-ups,
local order drafts, and a guide library. WordPress/WooCommerce presets generate the MCP Adapter endpoint and
support Application Password authentication. Adapter execution is restricted by an explicit ability allowlist
as well as tool grants. Meta Ads and custom Facebook Page/Messenger servers have separate presets.

Conversation AI controls support mode overrides, source selection, timed pauses, and optional pauses after
manual replies. Assistant text can be appended to a Zalo draft; image sending requires a recipient confirmation.
Order drafts stay local and do not create remote orders. Website credentials and Meta client setup are still
required for live connections; a preset alone is not a connected account.

Detailed Vietnamese documentation: [implementation plan](docs/OLAZ-WORKSPACE-PLAN.vi.md) and
[connection and usage guide](docs/OLAZ-INTEGRATIONS.vi.md).

### Plugin → MCP

**Plugin** in the sidebar (⌥⌘7, also in ⌘K) manages external tools for the assistant replying inside Zalo.
It supports local **stdio** servers and remote **Streamable HTTP** servers using the MCP 2025-11-25 lifecycle.

1. Choose **Thêm kết nối…** and paste the MCP URL directly (for example `https://your-server.example/mcp`).
   Under **Xác thực**, choose the method documented by the server: **Bearer token**, **API key trong header**
   (including its required header name), **Tên đăng nhập / mật khẩu (HTTP Basic)**, or **Đăng nhập qua trình duyệt (OAuth)**. Enter credentials in Olaz's
   masked fields. Extra headers can be entered as JSON; custom authentication headers also have a JSON option.
   Existing connections can be updated through **Sửa…**. HTTP Basic only works when the server supports it;
   a website login does not necessarily authenticate MCP.
   Advanced setup also accepts a standard `mcpServers` JSON document, or a single server object containing
   `command` / `args` / `env` for stdio, or `url` / `headers` for Streamable HTTP. JSON configurations use their own
   `headers`; the authentication form applies when entering a URL directly.
2. For OAuth, save first and choose **Đăng nhập OAuth…** on the connection card. Olaz discovers protected-resource
   and authorization-server metadata, registers a public client when supported, and opens the system browser with
   PKCE S256. Complete sign-in and consent there. Advanced OAuth fields accept a pre-registered Client ID, optional
   Client Secret, scopes, and callback port; register the displayed loopback redirect URI with that client.
   Servers requiring an HTTPS callback can use **Callback HTTPS** in the advanced OAuth fields. Enter the full
   HTTPS URL (no query, fragment, or embedded credentials) of a tunnel forwarding to `http://127.0.0.1:8765`
   (or the selected local port), preserving the callback path. Register exactly that HTTPS URL at the provider.
   Olaz sends it in client registration, browser authorization and code exchange, while receiving the forwarded
   request only on loopback and checking its path, state, and PKCE. The tunnel must run during browser sign-in;
   normal MCP tool calls go directly to the configured MCP server and do not use the callback tunnel.
   Choose **Kiểm tra và tải công cụ** to perform a real MCP handshake and read the server's tool catalog.
3. Select the exact tools the assistant may use, then enable **Cho trợ lý AI dùng kết nối này**. New or edited
   connections start disabled with no tools granted. Command tools on the Mac remain disabled.
4. The existing AI instructions and review/automatic-send setting continue to apply to AI-enabled conversations.
   For example, add an instruction to look up current order status using the selected MCP tool when asked.

The same panel can call a selected tool with JSON arguments, show its text/structured result, and copy that result
into the AI's reference documents with **Dùng làm dữ liệu hướng dẫn AI**. That creates a local snapshot; normal
assistant tool calls query the MCP server directly when needed.

Use an installed/authenticated server. Remote URLs require HTTPS (HTTP is allowed on loopback only), and redirects
are not followed with configured credentials. OAuth requires standards-compliant discovery and PKCE S256; servers
without dynamic registration need a pre-registered Client ID. A hosted client-metadata document can also be supplied
as Client ID where the provider supports it; Olaz does not host one automatically. Native Google Drive sign-in is deferred.

Meta Ads currently rejects Olaz's automatic client registration with HTTP 400 `invalid_client_metadata`:
`Dynamic registration is not available for this client.` Reading Meta's public OAuth metadata succeeds but does not
verify registration, browser consent, or account access. For this connection, supply an accepted Meta App ID in
**Cấu hình OAuth nâng cao**, with the application's MCP permissions and displayed Redirect URI configured at Meta.
Without that client setup (or an already valid MCP access token supplied as Bearer authentication), Olaz cannot
complete this server's login. OAuth errors identify registration, code exchange, or refresh failures and show only
recognized error codes and local guidance; raw server error descriptions are never displayed or logged.

For temporary HTTPS testing with an installed `cloudflared`, run:

```bash
cloudflared tunnel --url http://127.0.0.1:8765
```

Append `/callback` to the generated HTTPS hostname and use the same full URL in Olaz and the provider's registered
callbacks. [Cloudflare Quick Tunnels](https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/) use a
different hostname on each start, so keep the process running and update both configurations after restarting it.
Use a stable hostname for regular use. A public callback does not replace the provider's Client ID, Client Secret
if required, or account consent. Olaz does not create or manage the external tunnel itself.

Plugin settings, including configured environment/header fields, are stored in the owner-only local file
`~/Library/Application Support/Olaz/Plugins/settings.json`. Per-request provider configuration is written to private
temporary files and removed when the model process finishes; credentials are not interpolated into provider arguments.
OAuth access/refresh tokens and Client Secrets are stored separately in macOS Keychain. Olaz refreshes expiring OAuth
sessions before manual tool access and AI replies, retaining rotated refresh tokens. Only the current access token
is passed to the temporary provider proxy; refresh tokens and OAuth Client Secrets stay in Olaz.
Successfully read credentials are cached in the running app's memory, so each reply does not read Keychain again.
Denied or failed Keychain reads/writes do not retry on every incoming message. An explicit **Kiểm tra và tải công cụ**,
manual tool call, or **Đăng nhập OAuth…** allows another attempt. Closing the app clears its in-memory cache.
macOS **Allow** grants a single access; **Always Allow** remembers the app's identity. The default ad-hoc development
signature is bound to the binary hash and changes when the executable changes, so a rebuilt app may need permission
again even after **Always Allow**. Use the same stable signing certificate through `OLAZ_SIGN_IDENTITY` for updates
that preserve code identity. Do not grant all applications access to the credential to work around development prompts.
Both providers use Olaz's stdio adapter, which exposes only selected tools and reads server credentials from the
private temporary file. Existing personal Codex/Claude configuration is not modified.

Offline integration tests use `scripts/testing/mcp-fixture.py`:

```bash
swift test --filter 'PluginTests|AIReplyTests|MCPOAuthTests'
# Optional: synthetic model requests against the fixture (no Zalo messages/data).
OLAZ_MCP_PROVIDER_TESTS=1 swift test --filter providersCanCallExplicitlyAllowedMCPTools
```

Protocol references: [MCP transports](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports),
[Codex MCP](https://learn.chatgpt.com/docs/extend/mcp), [Claude Code MCP](https://code.claude.com/docs/en/mcp).

### Release (maintainers)

```bash
xcrun notarytool store-credentials "olaz-notary" --apple-id <apple-id> --team-id <team-id>   # once
./scripts/release.sh           # → dist/Olaz-1.0.dmg + dist/Olaz-1.0.zip (Developer ID, hardened runtime, notarized, stapled)
OLAZ_VERSION=1.1 ./scripts/release.sh
```

The script signs `build/Olaz.app` with the "Developer ID Application" identity in your keychain, notarizes and
staples the app, then wraps it in a drag-to-Applications DMG that is signed, notarized and stapled as well.
Credentials stay in your keychain. Users still fetch the pinned Zalo runtime from VNG on first launch.

### Pinned Zalo version

The Zalo version is pinned in `ZaloRuntime.pinned` (version, DMG URL, SHA-256). To move Olaz to a newer Zalo,
test against it and bump the pin. Installed runtimes are upgraded in the background and switched at the next launch.
If the pinned DMG disappears from VNG's CDN, a fresh install falls back to whatever `zalo.me/download/zalo-pc` offers
(still signature-checked). `OLAZ_ZALO_DMG=pinned OLAZ_NETWORK_TESTS=1 swift test --filter ZaloRuntimeTests` runs the
install end to end.

### Developer harness

Prints every bridge/IPC call, console line and network request:

```bash
.build/debug/Olaz --engine-probe [login|main] [seconds]
OLAZ_TRACE_WORKERS=1 OLAZ_DEBUG_RESPONSES=1 OLAZ_QR_OUT=/tmp/qr.png …
```

* Engine diagnostics: `~/Library/Application Support/Olaz/logs/engine.log` (shapes only, no message content or tokens).
* Dev evaluation channel (debug builds only, off by default): `defaults write app.olaz.mac OlazDevEval -bool YES`.

## Architecture

```
SwiftUI (Liquid Glass)                     Views/, Shell/, App/
        │  @Observable ZaloEngine           ZaloRuntime/ZaloEngine.swift (+ feature extensions)
        ▼
OfficialClientHost  ── WKWebView, headless
  ├─ zalo-app:// scheme → pc-dist served straight out of Zalo's app.asar      (AsarArchive, ZaloRuntimeInstaller)
  ├─ HostScripts/network-shim.js → XHR/fetch/WebSocket proxied to URLSession   (NetworkProxy)
  ├─ HostScripts/bridge.js       → $z* preload globals, Electron IPC emulation (ZaloBridge)
  ├─ HostScripts/local-modules.js→ Node path/os/crypto objects, electron-store
  ├─ HostScripts/state-adapter.js→ official state → Swift (QR via DI container, Redux store)
  └─ HostScripts/*-adapter.js    → per-feature adapters over the official services (chat, composer, calls, …)
        │
ZaloMainProcess  ── Swift stand-in for Electron main.js: IPC channel handlers,
                    cookies (zpw_sek), zsafe-storage, keychain cipher, page hand-off
```

* **Bridge table**: `Resources/bridge-table.json` maps all 450 table-driven preload members
  to their IPC channel + type, generated from the official `preload-render.js`.
  Semantics per channel: [`reanalysis/bridge-spec.md`](reanalysis/bridge-spec.md).
* **Node parity**: `$znode.crypto` is reproduced on CommonCrypto/CryptoKit and verified
  byte-for-byte against Node (`Tests/OlazTests/RuntimeTests.swift`). The official
  client uses it to encrypt `zcid` and request params.
* **Storage**: native SQLite, as Zalo PC 26.10 runs after its IndexedDB → SQLite migration. The official data access
  layer talks to its `utility-process-sqlite` over a MessagePort channel; `HostScripts/sqlite-host.js` plays that
  process inside each page (channel broker + request protocol) and `ZaloRuntime/SQLiteHost.swift` executes the SQL on
  the system SQLite (`<userData>/sqlite/_production/<db>.db`). Installs that already hold IndexedDB data stay on the
  official "migration disabled" branch (`isMigrateFullDone→false`) until **Settings ▸ Engine ▸ Chuyển sang SQLite**;
  `OLAZ_STORAGE=idb|sqlite` overrides for a run. The legacy message search index still runs in its web worker
  (`fail_sqlite3=true`).
* **JSBridge/**: standalone JavaScriptCore runtime + WebCrypto shim + libsignal E2EE
  module, for JS-only pieces that run outside the renderer.

## Status

| Area | State |
|---|---|
| Official renderer in WKWebView, from the Zalo PC code Olaz fetches from VNG (no Zalo PC install needed) | ✅ |
| Electron main-process emulation (450-member IPC table) | ✅ login + main client paths |
| Network via Swift: cookies, UA `ZaloPC-darwin-23v694`, CSP-safe sync bridge | ✅ |
| Real QR login (trusted-device QR) → scan → confirm → session | ✅ verified end to end |
| Session restore on relaunch (no QR) | ✅ |
| Realtime WebSocket (`wsN-msg.chat.zalo.me`) | ✅ handshake + official sync commands |
| Conversation list from official services, native SwiftUI | ✅ names, groups, members, unread |
| Chat: open, history + load older, send text / reply, reactions, typing, read state, realtime | ✅ official chatbox controller + message loaders (`HostScripts/chat-adapter.js`) |
| Native chat UI (bubbles, media, quotes, reactions, composer with IME-safe Return) | ✅ `Views/ChatView.swift`, `MessageBubble.swift`, `ChatComposer.swift` |
| Composer "+": photos / video, files, screenshot, my contact card, reminder | ✅ official toolbar paths (`HostScripts/composer-adapter.js`, `ZaloEngine+Composer.swift`) |
| Message actions: forward, copy, recall, delete + undo, pin bar, star | ✅ `HostScripts/message-actions-adapter.js` |
| Voice / video calls | ✅ official `ZaloCall` helper (`CallBridge.swift`, `HostScripts/call-adapter.js`) |
| Phone → PC message sync, native Liquid Glass progress UI | ✅ official sync-v2 state machine (`HostScripts/transfer-adapter.js`, `Views/TransferView.swift`) |
| Hidden shared-worker window (Electron `sharedWorkerManager` port) | ✅ `ZaloRuntime/SharedWorkerRouter.swift` |
| CDN media when system DNS fails `*.zadn.vn` | ✅ DNS-over-HTTPS fallback with pinned-SNI TLS (`ZaloRuntime/MediaLoader.swift`), Zalo hosts only |
| Create group | 🧪 implemented over the official `createGroupV2` path, not yet verified against a live account |
| Native SQLite backend (Zalo 26.10 migrates new sessions to SQLite) | ✅ fresh installs; existing IndexedDB installs switch from Settings (no data migration: re-sync from the phone) |

## Reverse-engineering notes

* [REVERSE-ENGINEERING-NOTES.md](REVERSE-ENGINEERING-NOTES.md): how the original Zalo PC app (Electron 22) is
  packaged and structured, and why the renderer can be hosted outside Electron.
* [reanalysis/bridge-spec.md](reanalysis/bridge-spec.md): the preload bridge (`window.$z*`), IPC channels and
  their semantics, written as a spec for a Swift/WKWebView host.
* [reanalysis/bridge-table.json](reanalysis/bridge-table.json): machine-readable channel table.
* Comments at the top of each `HostScripts/*-adapter.js` document the official code paths each feature drives.

## What is (and isn't) in this repo

* **The Zalo runtime is not included.** Each user's Olaz downloads it from VNG and checks VNG's signature.
* **Zalo's brand assets, UI string table and other files from the official bundle are not included.** They're
  gitignored (see [.gitignore](.gitignore)). To regenerate them for research, extract them from your own copy of
  Zalo PC.
* **One third-party file is vendored**: [`Sources/Olaz/JSModules/vendor/libsignal-protocol.js`](Sources/Olaz/JSModules/vendor/libsignal-protocol.js),
  VNG's fork of [signalapp/libsignal-protocol-javascript](https://github.com/signalapp/libsignal-protocol-javascript),
  taken from Zalo PC 26.10.20 (`pc-dist/libs/libsignal-protocol.static.js`). Upstream is licensed **GPL-3.0**, so
  this build is redistributed under GPL-3.0. Only the standalone `JSBridge` E2EE module and its tests use it. The live
  client runs the copy inside the `app.asar` it downloads.

## License

Olaz is free software, licensed under the [GNU General Public License v3.0](LICENSE).
Copyright © 2026 Quan Nguyen.
