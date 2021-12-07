# EAPFraming

The `Transceiver` actor manages a collection of outstanding requests it has issued to the `EAAccessoryManager` (as proxied by `AsyncExternalAccessory`). Relying on an `EAPMessage` protocol, accessory responses are matched to requests. Each request has as associated timeout. If supported by the concrete `EAPMessageFactory`, unsolicited messages from the accessory (aka push messages) will be delivered via a delegate method. 

The table below lists the dependencies of this package and the key components provided by each. 

Package or Framework | Key Components
--- | ---
[EAPFraming](https://github.com/AppAccount/EAPFraming) | Transceiver, EAPMessage(Factory)
[AsyncExternalAccessory](https://github.com/AppAccount/AsyncExternalAccessory) | ExternalAccessoryManager, AccessoryProtocol
[AsyncStream](https://github.com/AppAccount/AsyncStream) | InputStreamActor, OutputStreamActor
[ExternalAccessory](https://developer.apple.com/documentation/externalaccessory) | EAAccessoryManager
