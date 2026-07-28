import AppKit

extension StatusItemController {
    func wireOpenCodexProxyUpdates() {
        self.openCodexProxy.onStateChange = { [weak self] in
            self?.invalidateMenus(refreshOpenMenus: true)
        }
    }

    @objc func toggleOpenCodexProxyFromMenu() {
        switch self.openCodexProxy.state {
        case .running, .starting:
            self.openCodexProxy.isEnabled = false
            self.openCodexProxy.stop()
        case .stopped, .error:
            self.openCodexProxy.isEnabled = true
            self.openCodexProxy.start()
        }
    }
}
