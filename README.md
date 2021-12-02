# EAPFraming

The `Transceiver` actor manages a collection of outstanding requests it has issued to the `EAAccessoryManager` (as proxied by `AsyncExternalAccessory`). Relying on an `EAPMessage` protocol, accessory responses are matched to requests. Each request has as associated timeout. If supported by the concrete `EAPMessageFactory`, unsolicited messages from the accessory (aka push messages) will be delivered via a delegate method. 
