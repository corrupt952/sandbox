import WiFiAware

extension LabDevice {
  init(_ device: WAPairedDevice) {
    self.init(
      id: device.id,
      name: device.name ?? device.pairingInfo?.pairingName,
      vendorName: device.pairingInfo?.vendorName,
      modelName: device.pairingInfo?.modelName
    )
  }
}
