import Foundation

@MainActor
final class TVDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var hosts: Set<String> = []
    private var completion: (([String]) -> Void)?
    private var deadline: Task<Void, Never>?

    func start(completion: @escaping ([String]) -> Void) {
        self.completion = completion
        browser.delegate = self
        browser.searchForServices(ofType: "_androidtvremote2._tcp.", inDomain: "local.")
        deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    func stop() {
        completion = nil
        deadline?.cancel()
        deadline = nil
        browser.delegate = nil
        browser.stop()
        for service in services {
            service.delegate = nil
            service.stop()
        }
        services.removeAll()
        hosts.removeAll()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 3)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        if sender.port == 6466, let host = sender.hostName, !host.isEmpty {
            hosts.insert(host.lowercased())
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        finish()
    }

    private func finish() {
        let callback = completion
        let results = hosts.sorted()
        stop()
        callback?(results)
    }
}
