import XCTest
import AsyncExternalAccessory
@testable import EAPFraming

extension String: Error {}

func makeMock() throws -> AccessoryMock {
    let streamBufferSize = 4096
    var optionalInputStream: InputStream?
    var optionalOutputStream: OutputStream?
    Stream.getBoundStreams(withBufferSize: streamBufferSize, inputStream: &optionalInputStream, outputStream: &optionalOutputStream)
    guard let inputStream = optionalInputStream, let outputStream = optionalOutputStream else {
        throw "can't initialize bound streams"
    }
    return AccessoryMock(name: "EMAN", modelNumber: "LEDOM", serialNumber: "001", manufacturer: "GFM", hardwareRevision: "1.0", protocolStrings: ["com.example.eap"], connectionID: Int.random(in: 0..<Int.max), inputStream: inputStream, outputStream: outputStream)
}

public typealias SequenceNumber = UInt8

actor ConcreteEAPMessageFactory: EAPMessageFactory {
    var txSequenceNumber = SequenceNumber(arc4random_uniform(1<<8)) // reduce the likelihood of false accepts on replay after app restart
    var rxSequenceNumber: SequenceNumber?
    func message<MessageT: EAPMessage>(with payload: Data) async throws -> MessageT {
        let header = Data.init([txSequenceNumber, 0])
        txSequenceNumber &+= 1 // "&+" is Swift's overflow addition operator
        return try MessageT.init(from: header + payload)
    }
    func isPush<MessageT: EAPMessage>(_ message: MessageT) async -> Bool {
        let messageTxSequenceNumber = message.data[0]
        let messageRxSequenceNumber = message.data[1]
        let isPush = messageTxSequenceNumber == 0 && (rxSequenceNumber == nil || rxSequenceNumber == messageRxSequenceNumber)
        if isPush {
            let nextSequenceNumber = messageRxSequenceNumber &+ 1
            rxSequenceNumber = nextSequenceNumber
        }
        return isPush
    }
}

struct ConcreteEAPMessage: EAPMessage, Equatable {
    static func destructure(data: Data) -> [ConcreteEAPMessage] {
        if let envelope = try? Self.init(from: data) {
            return [envelope]
        }
        return []
    }
    
    var data: Data

    init(from data: Data) throws {
        self.data = data
    }
    
    func isMatched(response: EAPMessage) -> Bool {
        data[0] == response.data[0] && data[1] == response.data[1]
    }
}

final class EAPFramingTests: XCTestCase {
    static let testTimeout: UInt64 = 8_000_000_000
    var manager: ExternalAccessoryManager!
    var accessory: AccessoryMock!
    var transceiver: Transceiver<ConcreteEAPMessage>!
    var messageFactory: ConcreteEAPMessageFactory!
    var shouldOpenCompletion: ((AccessoryMock)->Bool)?
    var didOpenCompletion: ((AccessoryMock, DuplexAsyncStream?)->())?
    var timeoutTask: Task<(), Never>!
    var pushCount: Int!
    
    override func setUp() async throws {
        continueAfterFailure = false
        accessory = try makeMock()
        self.manager = ExternalAccessoryManager()
        await manager.set(self)
        timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: Self.testTimeout)
            } catch {
                guard error is CancellationError else {
                    XCTFail("can't start timer")
                    return
                }
                return
            }
            XCTFail("timed out")
        }
        self.shouldOpenCompletion = { accessory in
            return true
        }
        Task {
            await self.manager.connectToPresentAccessories([self.accessory])
        }
        let duplexAsyncStream = await withCheckedContinuation { cont in
            self.didOpenCompletion = { _, duplex in
                cont.resume(returning: duplex)
            }
        }
        guard let duplex = duplexAsyncStream else {
            XCTFail()
            return
        }
        pushCount = 0
        messageFactory = ConcreteEAPMessageFactory()
        transceiver = Transceiver<ConcreteEAPMessage>(accessory: accessory, session: duplex, factory: messageFactory)
    }
    
    override func tearDown() {
        XCTAssert(pushCount == 0)
        shouldOpenCompletion = nil
        didOpenCompletion = nil
        timeoutTask.cancel()
    }
    
    func testListenerDisconnect() async throws {
        let listener = await transceiver.listen()
        guard let duplex = self.accessory.getStreams(), let input = duplex.input else {
            XCTFail()
            return
        }
        input.delegate?.stream?(input, handle: Stream.Event.endEncountered)
        try await listener.value
    }
    
    func testDisconnectedRequest() async throws {
        let listener = await transceiver.listen()
        guard let duplex = self.accessory.getStreams(), let input = duplex.input else {
            XCTFail()
            return
        }
        input.delegate?.stream?(input, handle: Stream.Event.endEncountered)
        try await listener.value
        let requestMessage = try ConcreteEAPMessage(from: Data.init(count: 16))
        let response = await transceiver.send(requestMessage)
        guard case .failure(let accessError) = response, accessError == .disconnected else {
            XCTFail()
            return
        }
    }
    
    func testRequestResponse() async throws {
        let _ = await transceiver.listen()
        let size = 16
        let requestData = Data.init(count: size)
        let requestMessage: ConcreteEAPMessage = try await messageFactory.message(with: requestData)
        print("send request")
        let response = await transceiver.send(requestMessage)
        guard case .success(let responseMessage) = response, responseMessage == requestMessage else {
            XCTFail()
            return
        }
    }
    
    func testRequestResponseTimeout() async throws {
        let _ = await transceiver.listen()
        let size = 16
        let requestData = Data.init(count: size)
        let requestMessage: ConcreteEAPMessage = try await messageFactory.message(with: requestData)
        let requestOverride: ConcreteEAPMessage = try await messageFactory.message(with: requestData)
        print("send request")
        let response = await transceiver.send(requestMessage, requestTimeoutSeconds: nil, requestOverride: requestOverride)
        guard case .failure(let error) = response, error == .requestTimeout else {
            XCTFail()
            return
        }
    }
    
    func testPush() async throws {
        let _ = await transceiver.listen(with: self)
        let size = 16
        var pushData = Data.init(count: size)
        pushData[1] = 0x55 // set RxSN
        let pushMessage = try ConcreteEAPMessage.init(from: pushData)
        await transceiver.inject(pushMessage, delegate: self)
        XCTAssert(pushCount == 1)
        pushCount = 0
    }
    
    func testDoublePush() async throws {
        let _ = await transceiver.listen(with: self)
        let size = 16
        var pushData = Data.init(count: size)
        pushData[1] = 0x55 // set RxSN
        let firstPushMessage = try ConcreteEAPMessage.init(from: pushData)
        pushData[1] = 0x56 // set RxSN
        let secondPushMessage = try ConcreteEAPMessage.init(from: pushData)
        await transceiver.inject(firstPushMessage, delegate: self)
        await transceiver.inject(secondPushMessage, delegate: self)
        XCTAssert(pushCount == 2)
        pushCount = 0
    }
    
    func testDuplicatePush() async throws {
        let _ = await transceiver.listen(with: self)
        let size = 16
        var pushData = Data.init(count: size)
        pushData[1] = 0x55 // set RxSN
        let pushMessage = try ConcreteEAPMessage.init(from: pushData)
        await transceiver.inject(pushMessage, delegate: self)
        await transceiver.inject(pushMessage, delegate: self)
        XCTAssert(pushCount == 1)
        pushCount = 0
    }
}

extension EAPFramingTests: AccessoryConnectionDelegate {
    func shouldOpenSession(for accessory: AccessoryProtocol) -> Bool {
        shouldOpenCompletion?(accessory as! AccessoryMock) ?? false
    }
    func sessionDidOpen(for accessory: AccessoryProtocol, session: DuplexAsyncStream?) {
        didOpenCompletion?(accessory as! AccessoryMock, session)
    }
}

extension EAPFramingTests: TransceiverDelegate {
    func received<MessageT: EAPMessage>(push: MessageT) {
        print(#function)
        pushCount += 1
    }
}
