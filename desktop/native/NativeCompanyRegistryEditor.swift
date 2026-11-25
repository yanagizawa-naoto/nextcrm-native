import AppKit

extension CRMEditor {
    func attachCompanyRegistry(_ registry: NativeCompanyRegistry, allowLookup: Bool) throws {
        let controls = try NativeCompanyRegistryControls(registry: registry, allowLookup: allowLookup, read: { [weak self] in
            self?.textValues() ?? [:]
        }, apply: { [weak self] values in
            guard let self else { throw CancellationError() }; try self.applyTextValues(values)
        })
        installAccessory(controls, onClose: { [weak controls] in controls?.cancel() })
    }
}
