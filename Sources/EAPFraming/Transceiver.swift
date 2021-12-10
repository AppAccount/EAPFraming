//  Transceiver.swift
//
//  Created by Yuval Koren on 12/2/21.
//  Copyright © 2021 Appcessori Corporation.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// 
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import Foundation
import AsyncExternalAccessory

public protocol EAPMessageFactory {
    associatedtype MessageT: EAPMessage
    func encapsulate(body: MessageT.BodyT) throws -> MessageT
    func isMatched(_: MessageT, _: MessageT) -> Bool
    func isPush(_: MessageT) -> Bool
    func destructure(data: Data) -> [MessageT]
}

public protocol EAPMessageBody {
    var data: Data { get }
}

public protocol EAPMessage {
    associatedtype BodyT: EAPMessageBody
    init(data: Data) throws
    var data: Data { get }
    var body: BodyT { get }
}

public enum AccessoryAccessError: Error {
    case requestTimeout
    case disconnected
    case invalidRequest
}

public actor Transceiver<FactoryT: EAPMessageFactory> {
    struct OutstandingRequest {
        var request: FactoryT.MessageT
        var continuation: CheckedContinuation<FactoryT.MessageT, Error>
        var timer: Task<(), Never>
    }
    let accessory: AccessoryProtocol
    let session: DuplexAsyncStream
    let factory: FactoryT
    var outstandingRequests = [OutstandingRequest]()
    var write: ((Data)->())?
    var finish: (()->())?
    var read: AsyncThrowingStream<Data, Error>?
    var push: ((FactoryT.MessageT.BodyT)->())?
    
    public init(accessory: AccessoryProtocol, session: DuplexAsyncStream, factory: FactoryT) {
        self.accessory = accessory
        self.session = session
        self.factory = factory
    }
    public func listen() async -> AsyncStream<FactoryT.MessageT.BodyT> {
        let read = await session.input.getReadDataStream()
        var writeFinish: (()->())?
        let writeDataStream = AsyncStream<Data> { continuation in
            write = { data in
                continuation.yield(data)
            }
            writeFinish = {
                continuation.finish()
            }
        }
        await session.output.setWriteDataStream(writeDataStream)
        var pushFinish: (()->())?
        let push = AsyncStream<FactoryT.MessageT.BodyT> { continuation in
            self.push = { body in
                continuation.yield(body)
            }
            pushFinish = {
                continuation.finish()
            }
        }
        finish = {
            writeFinish?()
            pushFinish?()
        }
        Task {
            for try await data in read {
                await process(data: data)
            }
            finish?()
            write = nil
        }
        return push
    }
#if DEBUG
    public func inject(_ response: FactoryT.MessageT) async {
        await process(data: response.data)
    }
#endif
    func process(data: Data) async {
        let messages: [FactoryT.MessageT] = factory.destructure(data: data)
        for message in messages {
            // match or drop
            let matchingRequestIndices = outstandingRequests.indices.filter({
                factory.isMatched(outstandingRequests[$0].request, message)
            })
            if let outstandingRequestIndex = matchingRequestIndices.first {
                let outstandingRequest = outstandingRequests[outstandingRequestIndex]
                outstandingRequest.timer.cancel()
                outstandingRequest.continuation.resume(returning: message)
                outstandingRequests.remove(at: outstandingRequestIndex)
            } else {
                if factory.isPush(message) {
                    push?(message.body)
                }
            }
        }
    }
    public func send(_ request: FactoryT.MessageT.BodyT, requestTimeoutSeconds: UInt = 2) async -> Result<FactoryT.MessageT.BodyT, AccessoryAccessError> {
        guard let requestMessage: FactoryT.MessageT = try? factory.encapsulate(body: request) else {
            return .failure(.invalidRequest)
        }
        return await send(requestMessage, requestTimeoutSeconds: requestTimeoutSeconds, requestOverride: nil)
    }
#if DEBUG
    /// bypass factory for testability
    public func send(_ request: FactoryT.MessageT, requestTimeoutSeconds: UInt?, requestOverride: FactoryT.MessageT?) async -> Result<FactoryT.MessageT.BodyT, AccessoryAccessError> {
        await send(request, requestTimeoutSeconds: requestTimeoutSeconds ?? 2, requestOverride: requestOverride)
    }
#endif
    func send(_ request: FactoryT.MessageT, requestTimeoutSeconds: UInt, requestOverride: FactoryT.MessageT?) async -> Result<FactoryT.MessageT.BodyT, AccessoryAccessError> {
        guard let write = write else {
            return .failure(.disconnected)
        }
        write(requestOverride?.data ?? request.data)
        do {
            let response: FactoryT.MessageT = try await withCheckedThrowingContinuation { cont in
                let timer = Task {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(requestTimeoutSeconds)*1_000_000_000)
                    } catch(let error) {
                        if !(error is CancellationError) {
                            print("can't start request timer")
                        }
                        return
                    }
                    if let outstandingRequestIndex = outstandingRequests.indices.filter({
                        factory.isMatched(outstandingRequests[$0].request, request)
                    }).first {
                        cont.resume(throwing: AccessoryAccessError.requestTimeout)
                        outstandingRequests.remove(at: outstandingRequestIndex)
                    }
                }
                let outstandingRequest = OutstandingRequest(request: request, continuation: cont, timer: timer)
                outstandingRequests.append(outstandingRequest)
            }
            return .success(response.body)
        } catch(let e) {
            return .failure(e as! AccessoryAccessError)
        }
    }
}
