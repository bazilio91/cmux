import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Cmd-click in a remote tmux mirror pane (manaflow-ai/cmux#15749). A mirror
/// workspace has no `remoteConfiguration`, so the managed-SSH preview route
/// never answered for it, while the local route is correctly refused for
/// remote panes. The mirror's own authenticated master (its ControlPath) is
/// the connection, exactly as the Files root uses it (#22053).
@MainActor
@Suite(.serialized)
struct RemoteTmuxMirrorFileLinkTests {
    @Test func connectedSSHMirrorPaneUsesTheMirrorControlPath() throws {
        let harness = try RemoteTmuxSessionMirrorLayoutHarness()
        defer { harness.tearDown() }
        let panel = try #require(harness.singlePanePanel(tmuxPaneID: 11))

        let route = try #require(harness.workspace.remoteTerminalFilePreviewConnection(for: panel.id))
        #expect(harness.workspace.remoteConfiguration == nil)
        #expect(route.connection.destination == harness.connection.host.destination)
        #expect(route.connection.port == harness.connection.host.port)
        #expect(route.connection.identityFile == harness.connection.host.identityFile)
        #expect(route.connection.sshOptions == ["ControlPath=\(harness.connection.host.controlSocketPath)"])
        #expect(route.displayTarget == harness.connection.host.destination)
        let arguments = ProcessSSHFileExplorerTransport.sshArguments(connection: route.connection, command: "pwd")
        #expect(arguments.contains("ControlPath=\(harness.connection.host.controlSocketPath)"))
        #expect(arguments.contains("ControlMaster=no"))
    }

    @Test func disconnectedMirrorPaneHasNoRoute() throws {
        let harness = try RemoteTmuxSessionMirrorLayoutHarness()
        defer { harness.tearDown() }
        let panel = try #require(harness.singlePanePanel(tmuxPaneID: 11))
        #expect(harness.workspace.remoteTerminalFilePreviewConnection(for: panel.id) != nil)

        harness.connection.beginReconnecting()
        #expect(harness.workspace.remoteTmuxMirrorState.link?.isConnected == false)
        #expect(harness.workspace.remoteTerminalFilePreviewConnection(for: panel.id) == nil)
    }

    /// An ET control stream does not prove that SSH works, the same rule as Files.
    @Test func etMirrorPaneHasNoRoute() throws {
        let harness = try RemoteTmuxSessionMirrorLayoutHarness()
        defer { harness.tearDown() }
        let panel = try #require(harness.singlePanePanel(tmuxPaneID: 11))
        harness.workspace.remoteTmuxMirrorState.link = RemoteTmuxMirrorLink(
            host: RemoteTmuxHost(destination: "user@host", transport: .et), isConnected: true
        )
        #expect(harness.workspace.remoteTerminalFilePreviewConnection(for: panel.id) == nil)
    }

    @Test func surfacesThatAreNotMirrorPanesHaveNoRoute() throws {
        let harness = try RemoteTmuxSessionMirrorLayoutHarness()
        defer { harness.tearDown() }
        let panel = try #require(harness.singlePanePanel(tmuxPaneID: 11))
        let container = try #require(harness.workspace.remoteTmuxControlPane(surfaceID: panel.id)?.containerPanelID)
        #expect(container != panel.id)
        #expect(harness.workspace.remoteTerminalFilePreviewConnection(for: container) == nil)
        #expect(harness.workspace.remoteTerminalFilePreviewConnection(for: UUID()) == nil)

        let manager = TabManager(autoWelcomeIfNeeded: false)
        let local = try #require(manager.selectedWorkspace)
        let localPanel = try #require(local.focusedPanelId)
        #expect(local.remoteTerminalFilePreviewConnection(for: localPanel) == nil)
    }

    /// Managed SSH keeps the exact fields it used before the mirror route existed.
    @Test func managedSSHConfigurationMapsUnchanged() {
        let configuration = WorkspaceRemoteConfiguration(
            destination: "alice@example.invalid", port: 2222, identityFile: "/tmp/key",
            sshOptions: ["StrictHostKeyChecking=accept-new"],
            localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil, localSocketPath: nil,
            terminalStartupCommand: nil, agentSocketPath: nil, preserveAfterTerminalExit: true
        )
        let route = RemoteTerminalFilePreviewConnection(configuration: configuration)
        #expect(route.connection.destination == configuration.destination)
        #expect(route.connection.port == configuration.port)
        #expect(route.connection.identityFile == configuration.identityFile)
        #expect(route.connection.sshOptions == configuration.fileOperationSSHOptions)
        #expect(route.displayTarget == configuration.displayTarget)
        #expect(route.managedConfiguration == configuration)

        // The completion guard compares the whole configuration, as before:
        // a change outside the connection fields still discards a download.
        let relayed = WorkspaceRemoteConfiguration(
            destination: "alice@example.invalid", port: 2222, identityFile: "/tmp/key",
            sshOptions: ["StrictHostKeyChecking=accept-new"],
            localProxyPort: nil, relayPort: 4567, relayID: nil, relayToken: nil, localSocketPath: nil,
            terminalStartupCommand: nil, agentSocketPath: nil, preserveAfterTerminalExit: true
        )
        #expect(RemoteTerminalFilePreviewConnection(configuration: relayed) != route)
    }

    /// The pane surface is not in `workspace.panels`; the click must still find it.
    @Test func mirrorPaneSurfaceResolvesToItsTerminalPanel() throws {
        let harness = try RemoteTmuxSessionMirrorLayoutHarness()
        defer { harness.tearDown() }
        let panel = try #require(harness.singlePanePanel(tmuxPaneID: 11))
        #expect(harness.workspace.terminalPanel(for: panel.id) == nil)
        #expect(harness.workspace.remoteFilePreviewTerminalPanel(for: panel.id) === panel)
        #expect(harness.workspace.remoteTerminalFileLinkDeferralTarget(sourcePanelId: panel.id) === panel)
    }

    @Test func deferralRefusesWithoutARoute() throws {
        let harness = try RemoteTmuxSessionMirrorLayoutHarness()
        defer { harness.tearDown() }
        let panel = try #require(harness.singlePanePanel(tmuxPaneID: 11))
        harness.connection.beginReconnecting()
        #expect(harness.workspace.remoteTerminalFileLinkDeferralTarget(sourcePanelId: panel.id) == nil)

        let manager = TabManager(autoWelcomeIfNeeded: false)
        let local = try #require(manager.selectedWorkspace)
        let localPanel = try #require(local.focusedPanelId)
        #expect(local.remoteTerminalFileLinkDeferralTarget(sourcePanelId: localPanel) == nil)
    }

    /// Workspace focus stays on the outer container; the preview's completion
    /// check must still count the container's active pane as focused.
    @Test func focusedMirrorPaneCountsAsTheFocusedSurface() throws {
        let harness = try RemoteTmuxSessionMirrorLayoutHarness()
        defer { harness.tearDown() }
        let panel = try #require(harness.singlePanePanel(tmuxPaneID: 11))
        harness.workspace.focusPanel(panel.id)
        #expect(harness.workspace.focusedPanelId != panel.id)
        #expect(harness.workspace.isFocusedTerminalSurface(panel.id))
        #expect(!harness.workspace.isFocusedTerminalSurface(UUID()))
    }

    /// Relative tokens resolve against the pane's tmux cwd, which cmux already tracks.
    @Test func relativeTokensResolveAgainstThePaneCwd() throws {
        let harness = try RemoteTmuxSessionMirrorLayoutHarness()
        defer { harness.tearDown() }
        let panel = try #require(harness.singlePanePanel(tmuxPaneID: 11))
        harness.connection.handleMessageForTesting(
            .subscriptionChanged(name: "cmux_cwd_11", value: "/home/dev/project")
        )
        #expect(harness.workspace.effectivePanelDirectory(panelId: panel.id) == "/home/dev/project")
    }
}
