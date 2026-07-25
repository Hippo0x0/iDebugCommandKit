#if I_DEBUG_COMMAND_KIT && canImport(UIKit)
import Darwin
import Foundation
import UIKit

/// A local, DEBUG-only command server for inspecting and driving a UIKit app.
///
/// The server binds only to `127.0.0.1`; it is intended for simulator and
/// developer-device workflows, never for a production network surface.
public final class DebugCommandServer: @unchecked Sendable {
    /// Runs on the main actor for an app-defined command.
    public typealias CommandHandler = @MainActor (DebugCommandContext, [String: Any]) -> DebugCommandResult

    public let port: UInt16

    private static let builtInCommands: Set<String> = [
        "ping",
        "viewTree",
        "tap",
        "scroll",
        "setText",
        "captureScreen"
    ]

    private let token: String
    private let excludedWindow: (UIWindow) -> Bool
    private let queue = DispatchQueue(label: "com.idebugcommandkit.accept")
    private let clientQueue = DispatchQueue(label: "com.idebugcommandkit.client", attributes: .concurrent)
    private let commandHandlersLock = NSLock()
    private let maxRequestBytes = 16 * 1024 * 1024
    private let socketTimeoutSeconds: Int = 3

    private var commandHandlers: [String: CommandHandler] = [:]
    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    /// Creates a server that will listen on loopback when `start()` is called.
    ///
    /// - Parameters:
    ///   - port: The loopback TCP port. Defaults to `47666`.
    ///   - token: An app-specific token required by every request.
    ///   - excludedWindow: A DEBUG overlay or other window to omit from normal
    ///     screenshots, view-tree traversal, targeting, and custom contexts.
    public init(
        port: UInt16 = 47666,
        token: String,
        excludedWindow: @escaping (UIWindow) -> Bool = { _ in false }
    ) {
        precondition(port > 0, "Debug command server port must be non-zero.")
        precondition(!token.isEmpty, "Debug command server token must not be empty.")
        self.port = port
        self.token = token
        self.excludedWindow = excludedWindow
    }

    /// Starts the loopback listener. Repeated calls are safe.
    public func start() {
        queue.async { [weak self] in
            self?.startListeningIfNeeded()
        }
    }

    /// Stops the listener. A later `start()` creates a new listener.
    public func stop() {
        queue.async { [weak self] in
            guard let self, let acceptSource else { return }
            self.acceptSource = nil
            self.serverSocket = -1
            acceptSource.cancel()
        }
    }

    /// Registers an app-defined DEBUG command.
    ///
    /// Built-in command names cannot be overridden. Register custom commands
    /// before calling `start()` so startup remains deterministic.
    public func register(command: String, handler: @escaping CommandHandler) {
        let normalizedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!normalizedCommand.isEmpty, "Custom debug command must not be empty.")
        precondition(
            !Self.builtInCommands.contains(normalizedCommand),
            "\(normalizedCommand) is a built-in debug command and cannot be overridden."
        )

        commandHandlersLock.lock()
        commandHandlers[normalizedCommand] = handler
        commandHandlersLock.unlock()
    }

    /// Removes a previously registered app-defined command.
    public func unregister(command: String) {
        commandHandlersLock.lock()
        commandHandlers.removeValue(forKey: command)
        commandHandlersLock.unlock()
    }

    private func startListeningIfNeeded() {
        guard acceptSource == nil else { return }

        let socketFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            print("[iDebugCommandKit] socket failed errno=\(errno)")
            return
        }

        var enabled: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.bind(socketFD, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            print("[iDebugCommandKit] bind 127.0.0.1:\(port) failed errno=\(errno)")
            Darwin.close(socketFD)
            return
        }

        guard Darwin.listen(socketFD, SOMAXCONN) == 0 else {
            print("[iDebugCommandKit] listen failed errno=\(errno)")
            Darwin.close(socketFD)
            return
        }

        let flags = fcntl(socketFD, F_GETFL, 0)
        _ = fcntl(socketFD, F_SETFL, flags | O_NONBLOCK)

        serverSocket = socketFD
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptAvailableConnections()
        }
        source.setCancelHandler {
            Darwin.close(socketFD)
        }
        acceptSource = source
        source.resume()

        print("[iDebugCommandKit] listening on 127.0.0.1:\(port)")
    }

    private func acceptAvailableConnections() {
        while true {
            let clientFD = Darwin.accept(serverSocket, nil, nil)
            if clientFD >= 0 {
                let flags = fcntl(clientFD, F_GETFL, 0)
                _ = fcntl(clientFD, F_SETFL, flags & ~O_NONBLOCK)

                var enabled: Int32 = 1
                setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
                configureClientSocket(clientFD)
                clientQueue.async { [weak self] in
                    self?.handleClient(clientFD)
                }
                continue
            }

            if errno == EWOULDBLOCK || errno == EAGAIN {
                break
            }
            if errno == EINTR {
                continue
            }
            print("[iDebugCommandKit] accept failed errno=\(errno)")
            break
        }
    }

    private func handleClient(_ clientFD: Int32) {
        defer { Darwin.close(clientFD) }

        guard let requestData = readRequest(from: clientFD) else {
            print("[iDebugCommandKit] client closed before sending request")
            return
        }

        send(response: handle(requestData: requestData), to: clientFD)
    }

    private func readRequest(from clientFD: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while data.count < maxRequestBytes {
            let bufferSize = buffer.count
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.recv(clientFD, rawBuffer.baseAddress, bufferSize, 0)
            }

            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                if let newlineIndex = data.firstIndex(of: 0x0A) {
                    return data.prefix(upTo: newlineIndex)
                }
                continue
            }

            if count == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            return nil
        }

        return data.isEmpty ? nil : data
    }

    private func configureClientSocket(_ clientFD: Int32) {
        var timeout = timeval(tv_sec: socketTimeoutSeconds, tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private func handle(requestData: Data) -> [String: Any] {
        guard
            let object = try? JSONSerialization.jsonObject(with: requestData),
            let request = object as? [String: Any]
        else {
            return errorResponse(id: nil, code: "invalid_json", message: "Request must be a JSON object.")
        }

        let id = request["id"] as? String
        guard request["token"] as? String == token else {
            return errorResponse(id: id, code: "unauthorized", message: "Invalid debug token.")
        }
        guard let command = request["command"] as? String else {
            return errorResponse(id: id, code: "missing_command", message: "Missing command.")
        }

        let params = request["params"] as? [String: Any] ?? [:]

        switch command {
        case "ping":
            return okResponse(id: id, payload: [
                "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
                "port": Int(port),
                "appState": applicationStateDescription(),
                "timestamp": Date().timeIntervalSince1970
            ])

        case "viewTree":
            let includeHidden = params["includeHidden"] as? Bool ?? false
            let maxDepth = params["maxDepth"] as? Int ?? 8
            switch viewTree(includeHidden: includeHidden, maxDepth: max(0, min(maxDepth, 20))) {
            case .success(let tree):
                return okResponse(id: id, payload: tree)
            case .failure(let error):
                return errorResponse(id: id, code: "view_tree_failed", message: error.message)
            }

        case "tap":
            switch tap(params: params) {
            case .success(let payload):
                return okResponse(id: id, payload: payload)
            case .failure(let error):
                return errorResponse(id: id, code: "tap_failed", message: error.message)
            }

        case "scroll":
            switch scroll(params: params) {
            case .success(let payload):
                return okResponse(id: id, payload: payload)
            case .failure(let error):
                return errorResponse(id: id, code: "scroll_failed", message: error.message)
            }

        case "setText":
            switch setText(params: params) {
            case .success(let payload):
                return okResponse(id: id, payload: payload)
            case .failure(let error):
                return errorResponse(id: id, code: "set_text_failed", message: error.message)
            }

        case "captureScreen":
            let includeExcludedWindows =
                params["includeExcludedWindows"] as? Bool ??
                params["includeDebugOverlay"] as? Bool ??
                false
            let afterScreenUpdates = params["afterScreenUpdates"] as? Bool ?? true
            switch captureScreen(
                includeExcludedWindows: includeExcludedWindows,
                afterScreenUpdates: afterScreenUpdates
            ) {
            case .success(let capture):
                return okResponse(id: id, payload: [
                    "format": "png",
                    "width": capture.width,
                    "height": capture.height,
                    "scale": capture.scale,
                    "pngBase64": capture.pngData.base64EncodedString()
                ])
            case .failure(let error):
                return errorResponse(id: id, code: "capture_failed", message: error.message)
            }

        default:
            guard let result = executeCustomCommand(named: command, params: params) else {
                return errorResponse(id: id, code: "unknown_command", message: "Unsupported command: \(command)")
            }
            switch result {
            case .success(let payload):
                return okResponse(id: id, payload: payload)
            case .failure(let code, let message):
                return errorResponse(id: id, code: code, message: message)
            }
        }
    }

    private func executeCustomCommand(named command: String, params: [String: Any]) -> DebugCommandResult? {
        guard let handler = commandHandler(named: command) else { return nil }
        let box = DebugCustomCommandResultBox()
        let parameters = DebugParametersBox(params)

        if Thread.isMainThread {
            MainActor.assumeIsolated {
                box.result = invokeCustomCommand(handler, params: parameters.value)
            }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    box.result = invokeCustomCommand(handler, params: parameters.value)
                }
            }
        }

        return box.result ?? .failure(
            code: "custom_command_failed",
            message: "Custom command did not produce a result."
        )
    }

    private func commandHandler(named command: String) -> CommandHandler? {
        commandHandlersLock.lock()
        defer { commandHandlersLock.unlock() }
        return commandHandlers[command]
    }

    @MainActor
    private func invokeCustomCommand(_ handler: CommandHandler, params: [String: Any]) -> DebugCommandResult {
        guard let scene = activeWindowScene() else {
            return .failure(
                code: "custom_command_failed",
                message: "No foreground window scene is available."
            )
        }
        let context = DebugCommandContext(
            windowScene: scene,
            windows: visibleWindows(in: scene, includeExcludedWindows: false)
        )
        return handler(context, params)
    }

    private func viewTree(
        includeHidden: Bool,
        maxDepth: Int
    ) -> Result<[String: Any], DebugCommandError> {
        runOnMain {
            guard let scene = self.activeWindowScene() else {
                return .failure(DebugCommandError(message: "No foreground window scene is available."))
            }

            let windows = self.visibleWindows(
                in: scene,
                includeExcludedWindows: false,
                includeHidden: includeHidden
            )
            return .success([
                "screen": self.rectDictionary(scene.coordinateSpace.bounds),
                "scale": Double(scene.screen.scale),
                "windows": windows.enumerated().map { index, window in
                    self.viewDictionary(
                        window,
                        window: window,
                        indexPath: "\(index)",
                        depth: 0,
                        maxDepth: maxDepth,
                        includeHidden: includeHidden
                    )
                }
            ])
        }
    }

    private func tap(params: [String: Any]) -> Result<[String: Any], DebugCommandError> {
        let request = DebugTapRequest(params: params)
        return runOnMain { () -> Result<[String: Any], DebugCommandError> in
            guard let scene = self.activeWindowScene() else {
                return .failure(DebugCommandError(message: "No foreground window scene is available."))
            }

            let point: CGPoint?
            if let x = request.x, let y = request.y {
                let scale = request.usesPixels ? scene.screen.scale : 1
                point = CGPoint(x: x / Double(scale), y: y / Double(scale))
            } else {
                point = nil
            }

            guard point != nil || request.query.hasCriteria else {
                return .failure(DebugCommandError(message: "Provide x/y coordinates or a text/identifier/label query."))
            }

            let target: DebugTarget?
            if let point {
                target = self.target(atScenePoint: point, in: scene)
            } else {
                target = self.target(matching: request.query, in: scene)
            }

            guard let target else {
                return .failure(DebugCommandError(message: "No matching visible view was found."))
            }

            switch self.performTap(on: target) {
            case .success(let action):
                return .success([
                    "action": action,
                    "target": self.viewSummary(target.view, window: target.window),
                    "point": self.pointDictionary(target.scenePoint)
                ])
            case .failure(let error):
                return .failure(error)
            }
        }
    }

    private func setText(params: [String: Any]) -> Result<[String: Any], DebugCommandError> {
        let request = DebugTextRequest(params: params)
        return runOnMain { () -> Result<[String: Any], DebugCommandError> in
            guard !request.text.isEmpty else {
                return .failure(DebugCommandError(message: "Missing text."))
            }
            guard let scene = self.activeWindowScene() else {
                return .failure(DebugCommandError(message: "No foreground window scene is available."))
            }

            let firstResponder = UIResponder.currentDebugFirstResponder() as? UIView
            let targetView: UIView?
            if request.query.hasCriteria {
                let identifiedView = request.query.identifier.flatMap {
                    self.view(withAccessibilityIdentifier: $0, in: scene)
                }
                let matchedView = identifiedView ?? self.target(matching: request.query, in: scene)?.view
                targetView = matchedView ?? firstResponder
            } else {
                targetView = firstResponder
            }

            guard let editable = self.editableView(from: targetView) else {
                if let keyInput = targetView as? UIKeyInput {
                    if !(targetView?.isFirstResponder ?? false) {
                        _ = targetView?.becomeFirstResponder()
                    }
                    keyInput.insertText(request.text)
                    return .success([
                        "target": self.viewSummary(targetView!, window: targetView?.window),
                        "textLength": request.text.count,
                        "action": "UIKeyInput.insertText"
                    ])
                }
                return .failure(DebugCommandError(message: "No matching text input was found."))
            }

            if let textField = editable as? UITextField {
                textField.text = request.text
                textField.sendActions(for: .editingChanged)
                return .success([
                    "target": self.viewSummary(textField, window: textField.window),
                    "textLength": request.text.count
                ])
            }

            if let textView = editable as? UITextView {
                textView.text = request.text
                NotificationCenter.default.post(name: UITextView.textDidChangeNotification, object: textView)
                textView.delegate?.textViewDidChange?(textView)
                return .success([
                    "target": self.viewSummary(textView, window: textView.window),
                    "textLength": request.text.count
                ])
            }

            return .failure(DebugCommandError(message: "Unsupported editable view."))
        }
    }

    private func scroll(params: [String: Any]) -> Result<[String: Any], DebugCommandError> {
        let request = DebugScrollRequest(params: params)
        return runOnMain { () -> Result<[String: Any], DebugCommandError> in
            guard let scene = self.activeWindowScene() else {
                return .failure(DebugCommandError(message: "No foreground window scene is available."))
            }

            let scrollView: UIScrollView?
            if let x = request.x, let y = request.y {
                let scale = request.usesPixels ? scene.screen.scale : 1
                let point = CGPoint(x: x / Double(scale), y: y / Double(scale))
                scrollView = self.target(atScenePoint: point, in: scene)?.view.ancestor(of: UIScrollView.self)
            } else if request.query.hasCriteria {
                scrollView = self.target(matching: request.query, in: scene)?.view.ancestor(of: UIScrollView.self)
            } else {
                scrollView = self.primaryScrollableView(in: scene, direction: request.direction)
            }

            guard let scrollView else {
                return .failure(DebugCommandError(message: "No visible scroll view was found."))
            }
            guard scrollView.contentSize.width > scrollView.bounds.width || scrollView.contentSize.height > scrollView.bounds.height else {
                return .failure(DebugCommandError(message: "Matched scroll view is not scrollable."))
            }

            let before = scrollView.contentOffset
            let maxOffset = self.maximumContentOffset(for: scrollView)
            var target = before

            switch request.direction {
            case "up":
                target.y -= request.amount
            case "down":
                target.y += request.amount
            case "left":
                target.x -= request.amount
            case "right":
                target.x += request.amount
            default:
                return .failure(DebugCommandError(message: "Unsupported direction: \(request.direction). Use up, down, left, or right."))
            }

            target.x = min(max(target.x, -scrollView.adjustedContentInset.left), maxOffset.x)
            target.y = min(max(target.y, -scrollView.adjustedContentInset.top), maxOffset.y)
            scrollView.setContentOffset(target, animated: request.animated)
            scrollView.layoutIfNeeded()

            return .success([
                "target": self.viewSummary(scrollView, window: scrollView.window),
                "direction": request.direction,
                "amount": request.amount,
                "animated": request.animated,
                "before": self.pointDictionary(before),
                "after": self.pointDictionary(target),
                "maximum": self.pointDictionary(maxOffset)
            ])
        }
    }

    private func captureScreen(
        includeExcludedWindows: Bool,
        afterScreenUpdates: Bool
    ) -> Result<ScreenCapture, DebugCommandError> {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                captureScreenOnMain(
                    includeExcludedWindows: includeExcludedWindows,
                    afterScreenUpdates: afterScreenUpdates
                )
            }
        }

        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                self.captureScreenOnMain(
                    includeExcludedWindows: includeExcludedWindows,
                    afterScreenUpdates: afterScreenUpdates
                )
            }
        }
    }

    private func applicationStateDescription() -> String {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                UIApplication.shared.applicationState.debugCommandDescription
            }
        }

        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                UIApplication.shared.applicationState.debugCommandDescription
            }
        }
    }

    private func runOnMain<T>(
        _ block: @MainActor () -> Result<T, DebugCommandError>
    ) -> Result<T, DebugCommandError> {
        let box = DebugResultBox<T>()
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                box.result = block()
            }
            return box.result ?? .failure(DebugCommandError(message: "Main-thread operation did not produce a result."))
        }

        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                box.result = block()
            }
        }
        return box.result ?? .failure(DebugCommandError(message: "Main-thread operation did not produce a result."))
    }

    @MainActor
    private func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
    }

    @MainActor
    private func visibleWindows(
        in scene: UIWindowScene,
        includeExcludedWindows: Bool,
        includeHidden: Bool = false
    ) -> [UIWindow] {
        scene.windows
            .filter { window in
                (includeHidden || (!window.isHidden && window.alpha > 0)) &&
                window.bounds.width > 0 &&
                window.bounds.height > 0 &&
                (includeExcludedWindows || !excludedWindow(window))
            }
            .sorted { $0.windowLevel.rawValue < $1.windowLevel.rawValue }
    }

    @MainActor
    private func captureScreenOnMain(
        includeExcludedWindows: Bool,
        afterScreenUpdates: Bool
    ) -> Result<ScreenCapture, DebugCommandError> {
        guard UIApplication.shared.applicationState == .active else {
            return .failure(DebugCommandError(message: "App is not active."))
        }
        guard let scene = activeWindowScene() else {
            return .failure(DebugCommandError(message: "No window scene is available."))
        }

        let windows = visibleWindows(
            in: scene,
            includeExcludedWindows: includeExcludedWindows
        )
        guard !windows.isEmpty else {
            return .failure(DebugCommandError(message: "No visible windows are available."))
        }

        let bounds = scene.coordinateSpace.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            return .failure(DebugCommandError(message: "Invalid scene bounds."))
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = scene.screen.scale
        format.opaque = false

        let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(origin: .zero, size: bounds.size))

            for window in windows {
                context.cgContext.saveGState()
                context.cgContext.translateBy(
                    x: window.frame.minX - bounds.minX,
                    y: window.frame.minY - bounds.minY
                )
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: afterScreenUpdates)
                context.cgContext.restoreGState()
            }
        }

        guard let data = image.pngData() else {
            return .failure(DebugCommandError(message: "Failed to encode PNG."))
        }

        return .success(ScreenCapture(
            pngData: data,
            width: Double(image.size.width),
            height: Double(image.size.height),
            scale: Double(image.scale)
        ))
    }

    @MainActor
    private func target(atScenePoint point: CGPoint, in scene: UIWindowScene) -> DebugTarget? {
        for window in visibleWindows(in: scene, includeExcludedWindows: false).reversed() {
            let windowPoint = CGPoint(x: point.x - window.frame.minX, y: point.y - window.frame.minY)
            guard window.bounds.contains(windowPoint), let view = window.hitTest(windowPoint, with: nil) else {
                continue
            }
            return DebugTarget(view: view, window: window, scenePoint: point)
        }
        return nil
    }

    @MainActor
    private func target(matching query: DebugViewQuery, in scene: UIWindowScene) -> DebugTarget? {
        for window in visibleWindows(in: scene, includeExcludedWindows: false).reversed() {
            if let view = firstMatchingView(in: window, window: window, query: query) {
                return DebugTarget(view: view, window: window, scenePoint: scenePoint(for: view, in: window))
            }
        }
        return nil
    }

    @MainActor
    private func firstMatchingView(in root: UIView, window: UIWindow, query: DebugViewQuery) -> UIView? {
        guard !root.isHidden, root.alpha > 0.01 else { return nil }
        let frameInWindow = root.convert(root.bounds, to: window)
        guard window.bounds.intersects(frameInWindow) else { return nil }

        if query.matches(root) {
            return root
        }
        for subview in root.subviews.reversed() {
            if let match = firstMatchingView(in: subview, window: window, query: query) {
                return match
            }
        }
        return nil
    }

    @MainActor
    private func performTap(on target: DebugTarget) -> Result<String, DebugCommandError> {
        if let tableView = target.view.ancestor(of: UITableView.self) {
            let tablePoint = target.window.convert(target.scenePoint, to: tableView)
            if let indexPath = tableView.indexPathForRow(at: tablePoint) {
                tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
                tableView.delegate?.tableView?(tableView, didSelectRowAt: indexPath)
                return .success("tableView.didSelectRow")
            }
        }

        if let collectionView = target.view.ancestor(of: UICollectionView.self) {
            let collectionPoint = target.window.convert(target.scenePoint, to: collectionView)
            if let indexPath = collectionView.indexPathForItem(at: collectionPoint) {
                collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
                collectionView.delegate?.collectionView?(collectionView, didSelectItemAt: indexPath)
                return .success("collectionView.didSelectItem")
            }
        }

        if let control = target.view.ancestor(of: UIControl.self) {
            let directActionCount = triggerRegisteredActions(on: control)
            if directActionCount > 0 {
                return .success("control.directActions(\(directActionCount))")
            }
            control.sendActions(for: .touchDown)
            control.sendActions(for: .touchUpInside)
            control.sendActions(for: .primaryActionTriggered)
            control.sendActions(for: .valueChanged)
            return .success("control.sendActions")
        }

        if let textInput = editableView(from: target.view) {
            textInput.becomeFirstResponder()
            return .success("becomeFirstResponder")
        }

        return .failure(DebugCommandError(
            message: "The matched view is not actionable. Use viewTree to pick a control or table/collection row."
        ))
    }

    @MainActor
    private func triggerRegisteredActions(on control: UIControl) -> Int {
        var count = 0
        let events: [UIControl.Event] = [.touchUpInside, .primaryActionTriggered, .valueChanged]
        for event in events {
            for target in control.allTargets {
                guard let actions = control.actions(forTarget: target, forControlEvent: event) else { continue }
                for actionName in actions {
                    let selector = Selector(actionName)
                    UIApplication.shared.sendAction(selector, to: target, from: control, for: nil)
                    count += 1
                }
            }
        }
        return count
    }

    @MainActor
    private func editableView(from view: UIView?) -> UIView? {
        guard let view else { return nil }
        if view is UITextField || view is UITextView {
            return view
        }
        for subview in view.subviews {
            if let editable = editableView(from: subview) {
                return editable
            }
        }
        return nil
    }

    @MainActor
    private func view(withAccessibilityIdentifier identifier: String, in scene: UIWindowScene) -> UIView? {
        func find(in view: UIView) -> UIView? {
            if view.accessibilityIdentifier == identifier {
                return view
            }
            for subview in view.subviews {
                if let match = find(in: subview) {
                    return match
                }
            }
            return nil
        }

        for window in visibleWindows(in: scene, includeExcludedWindows: false).reversed() {
            if let match = find(in: window) {
                return match
            }
        }
        return nil
    }

    @MainActor
    private func primaryScrollableView(in scene: UIWindowScene, direction: String) -> UIScrollView? {
        let candidates = visibleWindows(in: scene, includeExcludedWindows: false)
            .reversed()
            .flatMap { window in
                scrollableViews(in: window, window: window)
            }

        let directional = candidates.filter { scrollView in
            let range = scrollableRange(for: scrollView)
            if direction == "up" || direction == "down" {
                return range.y > 1
            }
            return range.x > 1
        }

        return (directional.isEmpty ? candidates : directional).max { lhs, rhs in
            scrollSelectionScore(lhs, direction: direction) < scrollSelectionScore(rhs, direction: direction)
        }
    }

    @MainActor
    private func scrollableViews(in root: UIView, window: UIWindow) -> [UIScrollView] {
        guard !root.isHidden, root.alpha > 0.01 else { return [] }
        let frameInWindow = root.convert(root.bounds, to: window)
        guard window.bounds.intersects(frameInWindow) else { return [] }

        var views: [UIScrollView] = []
        if let scrollView = root as? UIScrollView,
           scrollView.isScrollEnabled,
           scrollView.bounds.width > 0,
           scrollView.bounds.height > 0,
           scrollView.contentSize.width > scrollView.bounds.width || scrollView.contentSize.height > scrollView.bounds.height {
            views.append(scrollView)
        }
        for subview in root.subviews {
            views.append(contentsOf: scrollableViews(in: subview, window: window))
        }
        return views
    }

    @MainActor
    private func maximumContentOffset(for scrollView: UIScrollView) -> CGPoint {
        CGPoint(
            x: max(
                -scrollView.adjustedContentInset.left,
                scrollView.contentSize.width - scrollView.bounds.width + scrollView.adjustedContentInset.right
            ),
            y: max(
                -scrollView.adjustedContentInset.top,
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            )
        )
    }

    @MainActor
    private func scrollableRange(for scrollView: UIScrollView) -> CGPoint {
        let maximum = maximumContentOffset(for: scrollView)
        return CGPoint(
            x: maximum.x + scrollView.adjustedContentInset.left,
            y: maximum.y + scrollView.adjustedContentInset.top
        )
    }

    @MainActor
    private func scrollSelectionScore(_ scrollView: UIScrollView, direction: String) -> CGFloat {
        let visibleArea = scrollView
            .convert(scrollView.bounds, to: scrollView.window)
            .intersection(scrollView.window?.bounds ?? .zero)
            .area
        let range = scrollableRange(for: scrollView)
        let directionalRange = (direction == "up" || direction == "down") ? range.y : range.x
        return visibleArea + directionalRange * 10
    }

    @MainActor
    private func viewDictionary(
        _ view: UIView,
        window: UIWindow,
        indexPath: String,
        depth: Int,
        maxDepth: Int,
        includeHidden: Bool
    ) -> [String: Any] {
        var dictionary = viewSummary(view, window: window)
        dictionary["indexPath"] = indexPath
        dictionary["children"] = []

        guard depth < maxDepth else { return dictionary }

        let children = view.subviews.enumerated().compactMap { index, subview -> [String: Any]? in
            if !includeHidden, (subview.isHidden || subview.alpha <= 0.01) {
                return nil
            }
            return viewDictionary(
                subview,
                window: window,
                indexPath: "\(indexPath).\(index)",
                depth: depth + 1,
                maxDepth: maxDepth,
                includeHidden: includeHidden
            )
        }
        dictionary["children"] = children
        return dictionary
    }

    @MainActor
    private func viewSummary(_ view: UIView, window: UIWindow?) -> [String: Any] {
        var dictionary: [String: Any] = [
            "type": String(describing: type(of: view)),
            "frame": rectDictionary(view.frame),
            "screenFrame": window.map { rectDictionary(view.convert(view.bounds, to: $0)) } ?? rectDictionary(view.frame),
            "hidden": view.isHidden,
            "alpha": Double(view.alpha),
            "userInteractionEnabled": view.isUserInteractionEnabled
        ]

        if let identifier = view.accessibilityIdentifier, !identifier.isEmpty {
            dictionary["identifier"] = identifier
        }
        if let label = view.accessibilityLabel, !label.isEmpty {
            dictionary["label"] = label
        }
        if let value = view.accessibilityValue, !value.isEmpty {
            dictionary["value"] = value
        }
        if let text = view.debugVisibleText {
            dictionary["text"] = text
        }
        if view is UIControl {
            dictionary["actionable"] = true
        }
        if view is UITextField || view is UITextView {
            dictionary["editable"] = true
        }
        return dictionary
    }

    @MainActor
    private func scenePoint(for view: UIView, in window: UIWindow) -> CGPoint {
        let rect = view.convert(view.bounds, to: window)
        return CGPoint(x: window.frame.minX + rect.midX, y: window.frame.minY + rect.midY)
    }

    private func rectDictionary(_ rect: CGRect) -> [String: Double] {
        [
            "x": Double(rect.origin.x),
            "y": Double(rect.origin.y),
            "width": Double(rect.width),
            "height": Double(rect.height)
        ]
    }

    private func pointDictionary(_ point: CGPoint) -> [String: Double] {
        [
            "x": Double(point.x),
            "y": Double(point.y)
        ]
    }

    private func okResponse(id: String?, payload: [String: Any]) -> [String: Any] {
        var response: [String: Any] = [
            "status": "ok",
            "payload": payload
        ]
        if let id {
            response["id"] = id
        }
        return response
    }

    private func errorResponse(id: String?, code: String, message: String) -> [String: Any] {
        var response: [String: Any] = [
            "status": "error",
            "error": [
                "code": code,
                "message": message
            ]
        ]
        if let id {
            response["id"] = id
        }
        return response
    }

    private func send(response: [String: Any], to clientFD: Int32) {
        guard JSONSerialization.isValidJSONObject(response),
              var data = try? JSONSerialization.data(withJSONObject: response) else {
            return
        }

        data.append(0x0A)
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let count = Darwin.send(clientFD, baseAddress.advanced(by: sent), data.count - sent, 0)
                if count > 0 {
                    sent += count
                    continue
                }
                if count < 0, errno == EINTR {
                    continue
                }
                if count < 0 {
                    print("[iDebugCommandKit] send failed errno=\(errno)")
                }
                break
            }
        }
    }
}

/// The UIKit context supplied to an app-defined command handler.
@MainActor
public struct DebugCommandContext {
    public let windowScene: UIWindowScene
    public let windows: [UIWindow]

    init(windowScene: UIWindowScene, windows: [UIWindow]) {
        self.windowScene = windowScene
        self.windows = windows
    }
}

/// The response produced by an app-defined command handler.
public enum DebugCommandResult {
    case success([String: Any])
    case failure(code: String, message: String)
}

private struct ScreenCapture {
    let pngData: Data
    let width: Double
    let height: Double
    let scale: Double
}

private struct DebugTarget {
    let view: UIView
    let window: UIWindow
    let scenePoint: CGPoint
}

private struct DebugCommandError: Error {
    let message: String
}

private final class DebugResultBox<T>: @unchecked Sendable {
    var result: Result<T, DebugCommandError>?
}

private final class DebugCustomCommandResultBox: @unchecked Sendable {
    var result: DebugCommandResult?
}

/// JSONSerialization returns Foundation-backed values, which are read-only for
/// this request. The box keeps that payload on the socket thread until it is
/// consumed synchronously on the main actor by an app-defined command.
private final class DebugParametersBox: @unchecked Sendable {
    let value: [String: Any]

    init(_ value: [String: Any]) {
        self.value = value
    }
}

private struct DebugTapRequest: Sendable {
    let x: Double?
    let y: Double?
    let usesPixels: Bool
    let query: DebugViewQuery

    init(params: [String: Any]) {
        x = params["x"] as? Double
        y = params["y"] as? Double
        usesPixels = (params["coordinateSpace"] as? String) == "pixels"
        query = DebugViewQuery(params: params["query"] as? [String: Any] ?? params)
    }
}

private struct DebugTextRequest: Sendable {
    let text: String
    let query: DebugViewQuery

    init(params: [String: Any]) {
        text = params["text"] as? String ?? ""
        query = DebugViewQuery(params: params["query"] as? [String: Any] ?? params)
    }
}

private struct DebugScrollRequest: Sendable {
    let direction: String
    let amount: Double
    let animated: Bool
    let x: Double?
    let y: Double?
    let usesPixels: Bool
    let query: DebugViewQuery

    init(params: [String: Any]) {
        direction = (params["direction"] as? String ?? "down").lowercased()
        amount = max(1, params["amount"] as? Double ?? 360)
        animated = params["animated"] as? Bool ?? false
        x = params["x"] as? Double
        y = params["y"] as? Double
        usesPixels = (params["coordinateSpace"] as? String) == "pixels"
        query = DebugViewQuery(params: params["query"] as? [String: Any] ?? params)
    }
}

private struct DebugViewQuery: Sendable {
    let identifier: String?
    let label: String?
    let text: String?
    let type: String?
    let contains: Bool

    init(params: [String: Any]) {
        identifier = params["identifier"] as? String
        label = params["label"] as? String
        text = params["text"] as? String
        type = params["type"] as? String
        contains = params["contains"] as? Bool ?? false
    }

    var hasCriteria: Bool {
        [identifier, label, text, type].contains { value in
            guard let value else { return false }
            return !value.isEmpty
        }
    }

    @MainActor
    func matches(_ view: UIView) -> Bool {
        if let identifier, !matchesString(view.accessibilityIdentifier, query: identifier) {
            return false
        }
        if let label, !matchesString(view.accessibilityLabel, query: label) {
            return false
        }
        if let text, !matchesString(view.debugVisibleText, query: text) {
            return false
        }
        if let type, !matchesString(String(describing: Swift.type(of: view)), query: type) {
            return false
        }
        return true
    }

    private func matchesString(_ candidate: String?, query: String) -> Bool {
        guard let candidate, !candidate.isEmpty else { return false }
        if contains {
            return candidate.localizedCaseInsensitiveContains(query)
        }
        return candidate.caseInsensitiveCompare(query) == .orderedSame
    }
}

private extension UIApplication.State {
    var debugCommandDescription: String {
        switch self {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}

private extension UIView {
    @MainActor
    var debugVisibleText: String? {
        if let label = self as? UILabel {
            return label.text?.nilIfEmpty
        }
        if let button = self as? UIButton {
            return button.title(for: .normal)?.nilIfEmpty
        }
        if let textField = self as? UITextField {
            return textField.text?.nilIfEmpty ?? textField.placeholder?.nilIfEmpty
        }
        if let textView = self as? UITextView {
            return textView.text?.nilIfEmpty
        }
        if let segmentedControl = self as? UISegmentedControl, segmentedControl.selectedSegmentIndex >= 0 {
            return segmentedControl.titleForSegment(at: segmentedControl.selectedSegmentIndex)?.nilIfEmpty
        }
        return nil
    }

    @MainActor
    func ancestor<T: UIView>(of type: T.Type) -> T? {
        var view: UIView? = self
        while let current = view {
            if let match = current as? T {
                return match
            }
            view = current.superview
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isInfinite, width > 0, height > 0 else { return 0 }
        return width * height
    }
}

@MainActor
private weak var capturedDebugFirstResponder: UIResponder?

private extension UIResponder {
    @MainActor
    static func currentDebugFirstResponder() -> UIResponder? {
        capturedDebugFirstResponder = nil
        UIApplication.shared.sendAction(
            #selector(UIResponder.debugCaptureFirstResponder(_:)),
            to: nil,
            from: nil,
            for: nil
        )
        return capturedDebugFirstResponder
    }

    @objc
    func debugCaptureFirstResponder(_ sender: Any?) {
        capturedDebugFirstResponder = self
    }
}
#endif
