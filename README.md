# iDebugCommandKit

`iDebugCommandKit` is a loopback-only command server for inspecting and driving
UIKit apps while they run in **DEBUG**. It is intended for local development,
UI diagnosis, and automation helpers; it is not a production remote-control
surface.

The built-in commands are:

- `ping`
- `viewTree`
- `captureScreen`
- `tap`
- `scroll`
- `setText`

Apps may register additional commands for their own DEBUG-only fixtures or
workflows.

## Debug-only guarantee

Every Swift declaration and implementation in this package is wrapped in
`#if I_DEBUG_COMMAND_KIT && canImport(UIKit)`. The package explicitly defines
`I_DEBUG_COMMAND_KIT` for SwiftPM Debug builds and its podspec defines it only
for CocoaPods Debug builds; its Release product contains no server
implementation or public API.

For CocoaPods, integrate the pod only into the app's Debug configuration. This
ensures it is neither linked nor embedded in Release builds. Keep the app-side
`import` and startup code inside `#if DEBUG` as well.

The TCP listener is always bound to `127.0.0.1`; it never listens on the LAN.
Use an app-specific token rather than relying on the default.

## Swift Package Manager

Add the package in Xcode, or declare a local dependency while developing:

```swift
.package(path: "../iDebugCommandKit")
```

Then add `iDebugCommandKit` to the app target and start it only in DEBUG:

```swift
#if DEBUG
import iDebugCommandKit

private let debugServer = DebugCommandServer(token: "my-app-debug")
#endif

// In application(_:didFinishLaunchingWithOptions:)
#if DEBUG
debugServer.start()
#endif
```

For a remote package, replace the local path with your repository URL and a
version rule.

## CocoaPods

Use a Debug-only dependency in the host app's `Podfile`:

```ruby
target 'MyApp' do
  pod 'iDebugCommandKit', :path => '../iDebugCommandKit', :configurations => ['Debug']
end
```

After publishing the podspec, replace `:path` with a version requirement. The
`#if DEBUG` guards remain required even when the pod is configuration-scoped.

## App-defined commands

The custom command handler runs on the main actor and receives the active
window scene plus the visible, non-excluded windows. This keeps app-specific
code out of the reusable package.

```swift
#if DEBUG
let server = DebugCommandServer(
    token: "my-app-debug",
    excludedWindow: { $0 is MyDebugOverlayWindow }
)

server.register(command: "resetFixtures") { context, _ in
    FixtureStore.shared.reset()
    return .success([
        "windowCount": context.windows.count
    ])
}
#endif
```

Return `.failure(code:message:)` to send a structured error to the client.

## Client

`tools/debug-command` is a dependency-free Python 3 client for the built-in
protocol. It also supports `--device`/`--udid` through `iproxy` for a connected
iPhone.

```bash
tools/debug-command --token my-app-debug ping
tools/debug-command --token my-app-debug tree --out /tmp/view-tree.json
tools/debug-command --token my-app-debug capture --out /tmp/app.png
tools/debug-command --token my-app-debug tap --identifier saveButton
tools/debug-command --token my-app-debug type "Hello" --identifier messageInput
tools/debug-command --token my-app-debug send resetFixtures --params '{}'
```

The wire format is newline-delimited JSON. Requests contain `id`, `token`,
`command`, and `params`; responses contain either `status: "ok"` with a
`payload`, or `status: "error"` with `error.code` and `error.message`.

## Security model

This is intentionally a DEBUG-only developer tool. Do not expose it in
production, bind it beyond loopback, or add arbitrary selector invocation.
The `tap` command only activates UIKit controls and table/collection selections
that are already present in the app.
