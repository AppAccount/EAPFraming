import XCTest
import AsyncExternalAccessory
@testable import EAPFraming

extension String: Error {}

func makeMock(serialNumber: String="001") throws -> AccessoryMock {
    let streamBufferSize = 4096
    var optionalInputStream: InputStream?
    var optionalOutputStream: OutputStream?
    Stream.getBoundStreams(withBufferSize: streamBufferSize, inputStream: &optionalInputStream, outputStream: &optionalOutputStream)
    guard let inputStream = optionalInputStream, let outputStream = optionalOutputStream else {
        throw "can't initialize bound streams"
    }
    return AccessoryMock(name: "EMAN", modelNumber: "LEDOM", serialNumber: serialNumber, manufacturer: "GFM", hardwareRevision: "1.0", protocolStrings: ["com.example.eap"], connectionID: Int.random(in: 0..<Int.max), inputStream: inputStream, outputStream: outputStream)
}

public typealias SequenceNumber = UInt8

/// Sample message framing format:
///  1B client request sequence number
///  1B accessory notification sequence number
///  2B frame length (max 4kB including header)
class ConcreteEAPMessageFactory: EAPMessageFactory {
    var txSequenceNumber = SequenceNumber(arc4random_uniform(1<<8)) // reduce the likelihood of false accepts on replay after app restart
    var rxSequenceNumber: SequenceNumber?
    var remainder: Data?
    func encapsulate(body: ConcreteEAPMessageBody) -> ConcreteEAPMessage {
        let header = Data.init([txSequenceNumber, 0, 0, UInt8(body.data.count)])
        txSequenceNumber &+= 1 // "&+" is Swift's overflow addition operator
        return ConcreteEAPMessage.init(header: header, body: body)
    }
    func isMatched(_ first: ConcreteEAPMessage, _ second: ConcreteEAPMessage) -> Bool {
        first.data[first.data.startIndex] == second.data[second.data.startIndex] &&
        first.data[first.data.startIndex + 1] == second.data[second.data.startIndex+1]
    }
    func isPush(_ message: ConcreteEAPMessage) -> Bool {
        let messageTxSequenceNumber = message.data[message.data.startIndex]
        let messageRxSequenceNumber = message.data[message.data.startIndex+1]
        let isPush = messageTxSequenceNumber == 0 && (rxSequenceNumber == nil || rxSequenceNumber == messageRxSequenceNumber)
        if isPush {
            let nextSequenceNumber = messageRxSequenceNumber &+ 1
            rxSequenceNumber = nextSequenceNumber
        }
        return isPush
    }
    func destructure(data: Data) -> [ConcreteEAPMessage] {
        print(#function, data.count)
        var dataAndRemainder: Data
        if let remainder = remainder {
            print("with remainder \(remainder.count)")
            dataAndRemainder = remainder + data
            self.remainder = nil
        } else {
            dataAndRemainder = data
        }
        guard dataAndRemainder.count >= ConcreteEAPMessage.headerLength else {
            remainder = dataAndRemainder
            return []
        }
        let bodyLength = ConcreteEAPMessage.bodyLength(from: dataAndRemainder)
        let messageLength = ConcreteEAPMessage.headerLength + bodyLength
        guard dataAndRemainder.count >= messageLength else {
            remainder = dataAndRemainder
            return []
        }
        let index = dataAndRemainder.startIndex
        if let envelope = try? ConcreteEAPMessage.init(data: dataAndRemainder[index..<index+messageLength]) {
            return [envelope] + destructure(data: dataAndRemainder.dropFirst(messageLength))
        }
        return []
    }
}

struct ConcreteEAPMessage: EAPMessage {
    static var headerLength = 4
    
    static func bodyLength(from data: Data) -> Int {
        Int(data[data.startIndex+3])
    }
    var header: Data
    var body: ConcreteEAPMessageBody
    var data: Data {
        header + body.data
    }

    init(data: Data) throws {
        let bodyLength = Self.bodyLength(from: data)
        guard data.count == Self.headerLength + bodyLength else { throw "invalid framing" }
        guard data.count <= 4096 else { throw "frame too long" }
        self.header = data[data.startIndex..<data.startIndex+Self.headerLength]
        self.body = ConcreteEAPMessageBody.init(data: data.dropFirst(Self.headerLength))
    }
    init(header: Data, body: ConcreteEAPMessageBody) {
        self.header = header
        self.body = body
    }
}

struct ConcreteEAPMessageBody: EAPMessageBody, Equatable {
    var doesReset: Bool
    var data: Data
    
    init(doesReset: Bool, data: Data) {
        self.doesReset = doesReset
        self.data = data
    }
    init (data: Data) {
        self.doesReset = false
        self.data = data
    }
}

final class EAPFramingTests: XCTestCase {
    static let testTimeout: UInt64 = 8_000_000_000
    var manager: ExternalAccessoryManager!
    var accessory: AccessoryMock!
    var transceiver: Transceiver<ConcreteEAPMessageFactory>!
    var shouldOpenCompletion: ((AccessoryMock)->Bool)?
    var didOpenCompletion: ((AccessoryMock, DuplexAsyncStream?)->())?
    var timeoutTask: Task<(), Never>!
    
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
        transceiver = Transceiver(accessory: accessory, session: duplex, factory: ConcreteEAPMessageFactory())
    }
    
    override func tearDown() {
        shouldOpenCompletion = nil
        didOpenCompletion = nil
        timeoutTask.cancel()
    }
    
    func testListenerDisconnect() async throws {
        let pushStream = await transceiver.listen()
        guard let duplex = self.accessory.getStreams(), let input = duplex.input else {
            XCTFail()
            return
        }
        input.delegate?.stream?(input, handle: Stream.Event.endEncountered)
        for await _ in pushStream { XCTFail() }
    }
    
    func testPreDisconnectRequest() async throws {
        let pushStream = await transceiver.listen()
        guard let duplex = self.accessory.getStreams(), let input = duplex.input else {
            XCTFail()
            return
        }
        let request = ConcreteEAPMessageBody.init(data: Data.init(count: 16))
        async let responseTask = transceiver.send(request)
        input.delegate?.stream?(input, handle: Stream.Event.endEncountered)
        for await _ in pushStream { XCTFail() }
        let response = await responseTask
        guard case .failure(let accessError) = response, accessError == .disconnected else {
            XCTFail()
            return
        }
    }
    
    func testPostDisconnectRequest() async throws {
        let pushStream = await transceiver.listen()
        guard let duplex = self.accessory.getStreams(), let input = duplex.input else {
            XCTFail()
            return
        }
        input.delegate?.stream?(input, handle: Stream.Event.endEncountered)
        for await _ in pushStream { XCTFail() }
        let request = ConcreteEAPMessageBody.init(data: Data.init(count: 16))
        let response = await transceiver.send(request)
        guard case .failure(let accessError) = response, accessError == .disconnected else {
            XCTFail()
            return
        }
    }
    
    func testMessagePreservesDoesReset() async throws {
        let request = ConcreteEAPMessageBody.init(doesReset: true, data: Data.init(count: 16))
        let message = ConcreteEAPMessageFactory().encapsulate(body: request)
        XCTAssert(message.body.doesReset == true)
    }
    
    func testResetRequestTimeout() async throws {
        let pushStream = await transceiver.listen()
        guard let duplex = self.accessory.getStreams(), let input = duplex.input else {
            XCTFail()
            return
        }
        let request = ConcreteEAPMessageBody.init(doesReset: true, data: Data.init(count: 16))
        async let responseTask = transceiver.send(request)
        input.delegate?.stream?(input, handle: Stream.Event.endEncountered)
        for await _ in pushStream { XCTFail() }
        let count = await transceiver.outstandingRequests.count
        XCTAssert(count == 1)
        await transceiver.reconnect(accessory: try makeMock(serialNumber: "101")) // non-matching reconnect
        let response = await responseTask
        guard case .failure(let error) = response, error == .requestTimeout else {
            XCTFail()
            return
        }
    }
    
    func testResetRequestSyntheticResponse() async throws {
        let pushStream = await transceiver.listen()
        guard let duplex = self.accessory.getStreams(), let input = duplex.input else {
            XCTFail()
            return
        }
        let request = ConcreteEAPMessageBody.init(doesReset: true, data: Data.init(count: 16))
        async let responseTask = transceiver.send(request)
        input.delegate?.stream?(input, handle: Stream.Event.endEncountered)
        for await _ in pushStream { XCTFail() }
        let count = await transceiver.outstandingRequests.count
        XCTAssert(count == 1)
        await transceiver.reconnect(accessory: try makeMock())
        let response = await responseTask
        guard case .success = response else {
            XCTFail()
            return
        }
    }
    /*
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
    // new transceiver!
     */
    
    func testRequestResponse() async throws {
        let pushStream = await transceiver.listen()
        Task {
            for await _ in pushStream { XCTFail() }
        }
        let size = 252
        let requestData = Data.init(repeating: UInt8.random(in: 0...255), count: size)
        let request = ConcreteEAPMessageBody.init(data: requestData)
        let result = await transceiver.send(request)
        guard case .success(let reponse) = result, reponse == request else {
            XCTFail()
            return
        }
    }
    
    func testRequestResponseTimeout() async throws {
        let pushStream = await transceiver.listen()
        Task {
            for await _ in pushStream { XCTFail() }
        }
        let factory = ConcreteEAPMessageFactory()
        let size = 16
        let requestData = Data.init(count: size)
        let requestBody = ConcreteEAPMessageBody.init(data: requestData)
        let request = factory.encapsulate(body: requestBody)
        let requestOverride = factory.encapsulate(body: requestBody)
        // response will be dropped due to a sequence number mismatch, resulting in a timeout
        let response = await transceiver.send(request, requestTimeoutSeconds: nil, requestOverride: requestOverride)
        guard case .failure(let error) = response, error == .requestTimeout else {
            XCTFail()
            return
        }
    }
    
    func testRequestBackPressure() async throws {
        let _ = await transceiver.listen()
        let size = 255
        let count = 32
        await withTaskGroup(of: Result<ConcreteEAPMessageBody, AccessoryAccessError>.self, body: { taskGroup in
            for i in 0..<count {
                taskGroup.addTask {
                    let requestData = Data.init(repeating: UInt8(i), count: size)
                    let request = ConcreteEAPMessageBody.init(data: requestData)
                    print("send \(i)")
                    let result = await self.transceiver.send(request)
                    print("result \(result)")
                    return result
                }
            }
            var results: Array<Result<ConcreteEAPMessageBody, AccessoryAccessError>> = []
            for await result in taskGroup {
                guard case .success(let response) = result else {
                    XCTFail()
                    return
                }
                print("received \(response.data[response.data.startIndex])")
                results.append(result)
            }
            XCTAssert(results.count == count)
        })
    }
    
    func testPush() async throws {
        let pushStream = await transceiver.listen()
        let size = 16
        var pushData = Data.init(count: size)
        pushData[1] = 0x55 // set RxSN
        pushData[3] = UInt8(size - ConcreteEAPMessage.headerLength)
        let pushMessage = try ConcreteEAPMessage.init(data: pushData)
        await withTaskGroup(of: Void.self) { taskGroup in
            taskGroup.addTask {
                for await _ in pushStream {
                    return
                }
            }
            taskGroup.addTask {
                await self.transceiver.inject(pushMessage)
            }
            await taskGroup.waitForAll()
        }
    }
    
    func testDoublePush() async throws {
        let pushStream = await transceiver.listen()
        let pushCounter: Task<Void, Never> = Task {
            var count = 0
            for await _ in pushStream {
                count += 1
                if count >= 2 {
                    return
                }
            }
        }
        let size = 16
        var pushData = Data.init(count: size)
        pushData[1] = 0x55 // set RxSN
        pushData[3] = UInt8(size - ConcreteEAPMessage.headerLength)
        let firstPushMessage = try ConcreteEAPMessage.init(data: pushData)
        pushData[1] = 0x56 // set RxSN
        let secondPushMessage = try ConcreteEAPMessage.init(data: pushData)
        await transceiver.inject(firstPushMessage)
        await transceiver.inject(secondPushMessage)
        await pushCounter.value
    }
    
    func testDuplicatePush() async throws {
        let pushStream = await transceiver.listen()
        let pushCounter: Task<Void, Never> = Task {
            var count = 0
            for await _ in pushStream {
                count += 1
                if count >= 2 {
                    return
                }
            }
        }
        let size = 16
        var pushData = Data.init(count: size)
        pushData[1] = 0x55 // set RxSN
        pushData[3] = UInt8(size - ConcreteEAPMessage.headerLength)
        let pushMessage = try ConcreteEAPMessage.init(data: pushData)
        await transceiver.inject(pushMessage)
        await transceiver.inject(pushMessage)
        pushData[1] = 0x56 // set RxSN
        let lastPushMessage = try ConcreteEAPMessage.init(data: pushData)
        await transceiver.inject(lastPushMessage)
        await pushCounter.value
    }
    
    func testReplacementListener() async throws {
        let pushStreamA = await transceiver.listen()
        Task {
            let _ = await transceiver.listen()
        }
        for await _ in pushStreamA {
            return
        }
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
