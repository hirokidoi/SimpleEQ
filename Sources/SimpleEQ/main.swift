import AppKit

let app = NSApplication.shared
// Info.plist の LSUIElement=1 と合わせた二重指定でメニューバー常駐 (Dock 非表示) を保証する。
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate

app.run()
