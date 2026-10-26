import Foundation

enum RemoteMCPPages {
    static func waiting(clientName: String, code: String) -> String {
        let title = localized("Approve on your Mac")
        let body = String(format: localized("Tivano is waiting for you to approve %@ on your Mac. Check that Tivano shows this code:"), clientName)
        return document(title: title, content: "<p>\(escape(body))</p><strong>\(escape(code))</strong><p>\(escape(localized("This page refreshes by itself. You can close it after your agent says it is connected.")))</p>", refresh: true)
    }

    static func message(title: String, body: String) -> String {
        document(title: localized(title), content: "<p>\(escape(localized(body)))</p>", refresh: false)
    }

    private static func localized(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: "Localizable")
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func document(title: String, content: String, refresh: Bool) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        \(refresh ? "<meta http-equiv=\"refresh\" content=\"2\">" : "")
        <title>\(escape(title))</title><style>
        :root{color-scheme:light dark}body{font-family:system-ui,sans-serif;margin:0;min-height:100vh;display:grid;place-items:center;background:#fafafa;color:#202020}main{max-width:30rem;padding:2rem;text-align:center}h1{font-size:1.6rem}p{line-height:1.6}strong{display:block;font-size:2.4rem;letter-spacing:.15em;margin:1.5rem 0}@media(prefers-color-scheme:dark){body{background:#181818;color:#eee}}
        </style></head><body><main><h1>\(escape(title))</h1>\(content)</main></body></html>
        """
    }
}
