import CmuxCloud
import CmuxCore
import CmuxPanes
import CmuxSurfaceCatalogModel
import Foundation

extension Workspace: TerminalLinkOpenContainer {
    var terminalLinkContainerDebugName: String {
        "workspace:\(id.uuidString)"
    }

    func terminalLinkWorkingDirectory(for sourcePanelId: UUID) -> String? {
        guard let target = surfaceOwnershipTarget(for: sourcePanelId) else { return nil }
        return CommandClickFileOpenRouter.resolveWorkingDirectory(
            workspace: self,
            surfaceId: target.surfaceID
        )
    }

    func terminalLinkIsRemoteTerminal(_ sourcePanelId: UUID) -> Bool {
        let surfaceID = surfaceOwnershipTarget(for: sourcePanelId)?.surfaceID
            ?? sourcePanelId
        return !canResolveTerminalPathsAgainstLocalFilesystem(
            surfaceID: surfaceID
        )
    }

    /// Resolve the connection from the terminal's authoritative owner, including native SSH projections.
    func remoteTerminalFilePreviewConfiguration(for surfaceID: UUID) -> WorkspaceRemoteConfiguration? {
        guard let configuration = remoteConfiguration, configuration.transport == .ssh else { return nil }
        if usesSSHTui {
            let expectedMachine = SurfaceMachineID(rawValue: SSHTuiConnection(configuration: configuration).id)
            guard machineOwningSurface(surfaceID) == expectedMachine else {
                return nil
            }
        } else if !isRemoteTerminalSurface(surfaceID) {
            return nil
        }
        return configuration
    }

    /// The SSH connection a Cmd-clicked file in `surfaceID` downloads over:
    /// the managed SSH configuration as before, or, for a remote tmux mirror's
    /// pane, the mirror's own authenticated master (manaflow-ai/cmux#15749).
    /// Mirror workspaces have no `remoteConfiguration`, so before this the
    /// click had no route at all. Same rule as the Files root: only a
    /// connected SSH mirror; an ET control stream does not prove SSH works.
    func remoteTerminalFilePreviewConnection(for surfaceID: UUID) -> RemoteTerminalFilePreviewConnection? {
        if let configuration = remoteTerminalFilePreviewConfiguration(for: surfaceID) {
            return RemoteTerminalFilePreviewConnection(configuration: configuration)
        }
        guard isRemoteTmuxMirror,
              remoteTmuxControlPane(surfaceID: surfaceID) != nil,
              let link = remoteTmuxMirrorState.link,
              link.host.transport == .ssh,
              link.isConnected else { return nil }
        return RemoteTerminalFilePreviewConnection(mirrorHost: link.host)
    }

    /// The terminal panel of `surfaceID`, including a mirror pane's surface,
    /// which lives in its window mirror rather than in `panels`.
    func remoteFilePreviewTerminalPanel(for surfaceID: UUID) -> TerminalPanel? {
        terminalPanel(for: surfaceID) ?? remoteTmuxControlPane(surfaceID: surfaceID)?.pane.panel
    }

    /// Whether `surfaceID` is the terminal the workspace's focus lands on:
    /// the focused panel itself, or the active pane of a focused mirror container.
    func isFocusedTerminalSurface(_ surfaceID: UUID) -> Bool {
        guard let focusedPanelId else { return false }
        return focusedPanelId == surfaceID || surfaceOwnershipTarget(for: focusedPanelId)?.surfaceID == surfaceID
    }

    /// The panel that previews a deferred remote file link, or nil to leave the
    /// link to the other routes. Managed SSH defers exactly as before (its
    /// coordinator then decides); a mirror pane defers only with a live route.
    func remoteTerminalFileLinkDeferralTarget(sourcePanelId: UUID) -> TerminalPanel? {
        guard let target = surfaceOwnershipTarget(for: sourcePanelId),
              terminalLinkIsRemoteTerminal(target.surfaceID) else { return nil }
        if remoteConfiguration?.transport == .ssh {
            return terminalPanel(for: target.surfaceID)
        }
        guard remoteTerminalFilePreviewConnection(for: target.surfaceID) != nil else { return nil }
        return remoteFilePreviewTerminalPanel(for: target.surfaceID)
    }

    func deferRemoteTerminalFileLinkOpen(sourcePanelId: UUID, rawValue: String) -> Bool {
        guard let panel = remoteTerminalFileLinkDeferralTarget(sourcePanelId: sourcePanelId) else { return false }
        _ = panel.hostedView.openRemoteFilePreview(tokens: [rawValue])
        return true
    }

    func cloudTerminalLinkTarget(url: URL, sourcePanelId: UUID) -> CloudTerminalLinkTarget? {
        guard let target = surfaceOwnershipTarget(for: sourcePanelId),
              let resource = SurfaceCatalog.shared.resource(forPanel: target.surfaceID)
                ?? SurfaceCatalog.shared.resource(forPanel: target.containerPanelID),
              let address = SurfaceCatalog.shared.machineInfo(for: resource.machine)?.privateAddress,
              let target = CmuxTuiSurfaceProvider.cloudTerminalLinkTarget(url: url, resource: resource, privateAddress: address) else { return nil }
        return target
    }

    func deferTerminalFileLinkOpen(
        sourcePanelId: UUID,
        filePath: String,
        fallback: @escaping @MainActor @Sendable () -> Void
    ) -> Bool {
        guard let target = surfaceOwnershipTarget(for: sourcePanelId) else { return false }
        CommandClickFileOpenRouter.deferredOpenFileInCmux(
            workspace: self,
            preferredWorkspaceId: id,
            surfaceId: target.containerPanelID,
            filePath: filePath,
            fallback: fallback
        )
        return true
    }

    func openTerminalBrowserLink(url: URL, sourcePanelId: UUID, focus: Bool = true) -> Bool {
        guard let target = surfaceOwnershipTarget(for: sourcePanelId) else { return false }
        if let targetPane = preferredRightSideTargetPane(fromPanelId: target.containerPanelID) {
            return newBrowserSurface(inPane: targetPane, url: url, focus: focus) != nil
        }
        return newBrowserSplit(
            from: target.containerPanelID,
            orientation: .horizontal,
            url: url,
            focus: focus
        ) != nil
    }
}
