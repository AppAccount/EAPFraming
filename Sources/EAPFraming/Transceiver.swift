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
    func message(from: Data) async -> EAPMessage?
    func isPush(_: EAPMessage) async -> Bool
}

public protocol EAPMessage {
    static func destructure(data: Data) -> [Self]
    init?(from data: Data)
    var data: Data { get }
    func isMatched(response: EAPMessage) -> Bool
}

public enum AccessoryAccessError: Error {
    case requestTimeout
    case disconnected
}

public protocol TransceiverDelegate: AnyObject {
    func received(push: EAPMessage)
}

public actor Transceiver<MessageT: EAPMessage & Equatable> {
    struct OutstandingRequest {
        var request: MessageT
        var continuation: CheckedContinuation<MessageT, Error>
        var timer: Task<(), Never>
    }
    let accessory: AccessoryProtocol
    let session: DuplexAsyncStream
    let factory: EAPMessageFactory
    var outstandingRequests = [OutstandingRequest]()
    var write: ((Data)->())?
    var finish: (()->())?
    var read: AsyncThrowingStream<Data, Error>?
    
    public init(accessory: AccessoryProtocol, session: DuplexAsyncStream, factory: EAPMessageFactory) {
        self.accessory = accessory
        self.session = session
        self.factory = factory
    }
    public func listen(with delegate: TransceiverDelegate?=nil) async -> Task<(), Error> {
        let read = await session.input.getReadDataStream()
        let writeDataStream = AsyncStream<Data> { continuation in
            write = { data in
                continuation.yield(data)
            }
            finish = {
                continuation.finish()
            }
        }
        await session.output.setWriteDataStream(writeDataStream)
        return Task {
            for try await data in read {
                let messages = MessageT.destructure(data: data)
                for message in messages {
                    // match or drop
                    let matchingRequestIndices = outstandingRequests.indices.filter({
                        outstandingRequests[$0].request.isMatched(response: message)
                    })
                    if let outstandingRequestIndex = matchingRequestIndices.first {
                        let outstandingRequest = outstandingRequests[outstandingRequestIndex]
                        outstandingRequest.timer.cancel()
                        outstandingRequest.continuation.resume(returning: message)
                        outstandingRequests.remove(at: outstandingRequestIndex)
                    } else {
                        if await factory.isPush(message) {
                            delegate?.received(push: message)
                        }
                    }
                }
            }
            finish?()
            write = nil
        }
    }
    public func send(_ request: MessageT, requestTimeoutSeconds: UInt = 2) async -> Result<MessageT, AccessoryAccessError> {
        await send(request, requestTimeoutSeconds: requestTimeoutSeconds, requestOverride: nil)
    }
    func send(_ request: MessageT, requestTimeoutSeconds: UInt, requestOverride: MessageT?) async -> Result<MessageT, AccessoryAccessError> {
        guard let write = write else {
            return .failure(.disconnected)
        }
        write(requestOverride?.data ?? request.data)
        do {
            let response: MessageT = try await withCheckedThrowingContinuation { cont in
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
                        outstandingRequests[$0].request == request
                    }).first {
                        cont.resume(throwing: AccessoryAccessError.requestTimeout)
                        outstandingRequests.remove(at: outstandingRequestIndex)
                    }
                }
                let outstandingRequest = OutstandingRequest(request: request, continuation: cont, timer: timer)
                outstandingRequests.append(outstandingRequest)
            }
            return .success(response)
        } catch(let e) {
            return .failure(e as! AccessoryAccessError)
        }
    }
}
