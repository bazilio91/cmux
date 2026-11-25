import CmuxCloud
import AppKit
import CmuxSettings
import CmuxTerminalCore
import Foundation

/// Owns remote click downloads and discards completions whose source terminal has changed.
/// The connection a remote Cmd-click download uses: managed SSH's fields, or
/// a remote tmux mirror's ControlPath master (see
/// `Workspace.remoteTerminalFilePreviewConnection(for:)`).
struct RemoteTerminalFilePreviewConnection: Equatable {
    let connection: SSHFileExplorerConnection
    let displayTarget: String
    /// The whole managed configuration, so the completion guard still discards
    /// a download when any of it changed, exactly as before mirror routes.
    let managedConfiguration: WorkspaceRemoteConfiguration?

    init(configuration: WorkspaceRemoteConfiguration) {
        connection = SSHFileExplorerConnection(
            destination: configuration.destination, port: configuration.port,
            identityFile: configuration.identityFile, sshOptions: configuration.fileOperationSSHOptions
        )
        displayTarget = configuration.displayTarget
        managedConfiguration = configuration
    }

    /// The mirror's master, exactly as the Files root reuses it.
    init(mirrorHost host: RemoteTmuxHost) {
        connection = SSHFileExplorerConnection(
            destination: host.destination, port: host.port, identityFile: host.identityFile,
            sshOptions: ["ControlPath=\(host.controlSocketPath)"]
        )
        displayTarget = host.destination
        managedConfiguration = nil
    }
}

@MainActor
final class RemoteTerminalFilePreviewCoordinator {
    private let defaults: UserDefaults
    private let transport: any SSHFileExplorerTransport
    private let cacheDirectory: URL
    private let clock: any Clock<Duration>
    private let timeout: Duration
    private var tasks: [UUID: (id: UUID, task: Task<Void, Never>)] = [:]

    init(
        defaults: UserDefaults,
        transport: any SSHFileExplorerTransport,
        cacheDirectory: URL,
        clock: any Clock<Duration> = ContinuousClock(),
        timeout: Duration = .seconds(30)
    ) {
        self.defaults = defaults
        self.transport = transport
        self.cacheDirectory = cacheDirectory
        self.clock = clock
        self.timeout = timeout
    }

    @discardableResult
    func open(workspace: Workspace, sourcePanelID: UUID, tokens: [String]) -> Bool {
        let tokens = tokens.filter { RemoteTerminalPathResolver().isFileReference($0) }
        guard !tokens.isEmpty,
              let route = workspace.remoteTerminalFilePreviewConnection(for: sourcePanelID),
              let panel = workspace.remoteFilePreviewTerminalPanel(for: sourcePanelID) else { return false }
        tasks[sourcePanelID]?.task.cancel()
        let settings = FileRouteSettingsStore(defaults: defaults)
        guard !ManagedFileTransferPolicy.isDisabled,
              settings.supportedFileRouteEnabled ||
                (settings.markdownRouteEnabled && tokens.contains { FileRouteSettingsStore.isMarkdownPath($0.trimmingTrailingTerminalPunctuation()) }) else {
            return true
        }
        let directory = workspace.effectivePanelDirectory(panelId: sourcePanelID)
        let provider = SSHFileExplorerProvider(
            destination: route.connection.destination,
            port: route.connection.port,
            identityFile: route.connection.identityFile,
            sshOptions: route.connection.sshOptions,
            displayTarget: route.displayTarget,
            homePath: "",
            isAvailable: true,
            transport: transport
        )
        let loader = RemoteTerminalFilePreviewLoader(
            provider: provider,
            cacheDirectory: cacheDirectory,
            fileManager: FileManager()
        )
        let clock = self.clock
        let timeout = self.timeout
        let requestID = UUID()
        #if DEBUG
        cmuxDebugLog("remotePreview.start request=\(requestID.uuidString) surface=\(sourcePanelID.uuidString)")
        #endif
        let sourceSurface = panel.surface
        let lifecycleID = sourceSurface.terminalLifecycleId
        let attemptID = workspace.remoteTerminalAttemptIDsBySurfaceId[sourcePanelID]
        let tuiAttemptID = workspace.sshTuiConnectionAttemptID
        let projectionResource = SurfaceCatalog.shared.projectionIncludingPendingRestore(forPanel: sourcePanelID)?.resource
        let task = Task { [weak self, weak workspace, weak panel, weak sourceSurface] in
            defer {
                if self?.tasks[sourcePanelID]?.id == requestID {
                    self?.tasks.removeValue(forKey: sourcePanelID)
                }
            }
            do {
                let localURL = try await withThrowingTaskGroup(of: URL.self) { group in
                    group.addTask { try await loader.load(tokens: tokens, workingDirectory: directory) }
                    group.addTask {
                        // A genuine transfer deadline, not a delay used to synchronize UI state.
                        try await clock.sleep(for: timeout)
                        throw URLError(.timedOut)
                    }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
                try Task.checkCancellation()
                guard let self, let workspace, let panel, let sourceSurface,
                      !ManagedFileTransferPolicy.isDisabled,
                      !workspace.isRetiredFromOwningTabManager,
                      workspace.remoteTerminalFilePreviewConnection(for: sourcePanelID) == route,
                      workspace.remoteFilePreviewTerminalPanel(for: sourcePanelID) === panel,
                      panel.surface === sourceSurface,
                      sourceSurface.terminalLifecycleId == lifecycleID,
                      workspace.remoteTerminalAttemptIDsBySurfaceId[sourcePanelID] == attemptID,
                      workspace.sshTuiConnectionAttemptID == tuiAttemptID,
                      SurfaceCatalog.shared.projectionIncludingPendingRestore(forPanel: sourcePanelID)?.resource == projectionResource,
                      sourceSurface.owningWorkspace() === workspace,
                      workspace.owningTabManager?.selectedTabId == workspace.id,
                      workspace.isFocusedTerminalSurface(sourcePanelID),
                      panel.hostedView.window?.isKeyWindow == true else {
                    #if DEBUG
                    cmuxDebugLog("remotePreview.discarded request=\(requestID.uuidString)")
                    #endif
                    return
                }
                let opened = CommandClickFileOpenRouter.openInCmux(
                    workspace: workspace,
                    sourcePanelId: sourcePanelID,
                    filePath: localURL.path,
                    defaults: self.defaults
                )
                #if DEBUG
                cmuxDebugLog("remotePreview.complete request=\(requestID.uuidString) opened=\(opened)")
                #endif
            } catch {
                guard !Task.isCancelled else { return }
                #if DEBUG
                cmuxDebugLog("remotePreview.failed request=\(requestID.uuidString)")
                #endif
                guard let workspace, let panel,
                      workspace.remoteTerminalFilePreviewConnection(for: sourcePanelID) == route,
                      workspace.sshTuiConnectionAttemptID == tuiAttemptID,
                      workspace.remoteFilePreviewTerminalPanel(for: sourcePanelID) === panel,
                      workspace.owningTabManager?.selectedTabId == workspace.id,
                      workspace.isFocusedTerminalSurface(sourcePanelID),
                      panel.hostedView.window?.isKeyWindow == true else { return }
                // Match the existing file-explorer preview failure affordance without exposing SSH diagnostics.
                NSSound.beep()
            }
        }
        tasks[sourcePanelID] = (requestID, task)
        return true
    }

    deinit {
        for entry in tasks.values { entry.task.cancel() }
    }
}
