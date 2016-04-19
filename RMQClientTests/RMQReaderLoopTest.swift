import XCTest

class RMQReaderLoopTest: XCTestCase {

    func testSkipsServerHeartbeats() {
        let transport = ControlledInteractionTransport()
        let frameHandler = FrameHandlerSpy()
        let readerLoop = RMQReaderLoop(transport: transport, frameHandler: frameHandler)
        let method = MethodFixtures.channelOpenOk()
        let expectedFrameset = AMQFrameset(channelNumber: 42, method: method)

        readerLoop.runOnce()

        transport.serverSendsPayload(AMQHeartbeat(), channelNumber: 0)
        transport.serverSendsPayload(method, channelNumber: 42)

        XCTAssertEqual(
            expectedFrameset,
            frameHandler.lastReceivedFrameset()!,
            "\n\nExpected: \(method)\n\nGot: \(frameHandler.lastReceivedFrameset()!.method)"
        )
    }

    func testSendsDecodedContentlessFramesetToFrameHandler() {
        let transport = ControlledInteractionTransport()
        let frameHandler = FrameHandlerSpy()
        let readerLoop = RMQReaderLoop(transport: transport, frameHandler: frameHandler)
        let method = MethodFixtures.connectionStart()
        let expectedFrameset = AMQFrameset(channelNumber: 42, method: method)

        readerLoop.runOnce()

        transport.serverSendsPayload(method, channelNumber: 42)

        XCTAssertEqual(
            expectedFrameset,
            frameHandler.lastReceivedFrameset()!,
            "\n\nExpected: \(method)\n\nGot: \(frameHandler.lastReceivedFrameset()!.method)"
        )
    }
    
    func testHandlesContentTerminatedByNonContentFrame() {
        let transport = ControlledInteractionTransport()
        let frameHandler = FrameHandlerSpy()
        let readerLoop = RMQReaderLoop(transport: transport, frameHandler: frameHandler)
        let method = MethodFixtures.basicGetOk("my.great.queue")
        let content1 = AMQContentBody(data: "aa".dataUsingEncoding(NSUTF8StringEncoding)!)
        let content2 = AMQContentBody(data: "bb".dataUsingEncoding(NSUTF8StringEncoding)!)
        let contentHeader = AMQContentHeader(
            classID: 10,
            bodySize: 999999,
            properties: [
                AMQBasicContentType("text/flame")
            ]
        )
        let expectedContentFrameset = AMQFrameset(
            channelNumber: 42,
            method: method,
            contentHeader: contentHeader,
            contentBodies: [content1, content2]
        )
        let nonContent = nonContentPayload()
        let expectedNonContentFrameset = AMQFrameset(channelNumber: 42, method: nonContent)

        readerLoop.runOnce()

        transport
            .serverSendsPayload(method, channelNumber: 42)
            .serverSendsPayload(contentHeader, channelNumber: 42)
            .serverSendsPayload(content1, channelNumber: 42)
            .serverSendsPayload(content2, channelNumber: 42)
            .serverSendsPayload(nonContent, channelNumber: 42)

        XCTAssertEqual(2, frameHandler.receivedFramesets.count)
        XCTAssertEqual(expectedContentFrameset, frameHandler.receivedFramesets[0])
        XCTAssertEqual(expectedNonContentFrameset, frameHandler.receivedFramesets[1])
    }

    func testHandlesContentTerminatedByEndOfDataSize() {
        let transport = ControlledInteractionTransport()
        let frameHandler = FrameHandlerSpy()
        let readerLoop = RMQReaderLoop(transport: transport, frameHandler: frameHandler)
        let method = MethodFixtures.basicGetOk("my.great.queue")
        let content1 = AMQContentBody(data: "aa".dataUsingEncoding(NSUTF8StringEncoding)!)
        let content2 = AMQContentBody(data: "bb".dataUsingEncoding(NSUTF8StringEncoding)!)
        let contentHeader = AMQContentHeader(
            classID: 10,
            bodySize: content1.amqEncoded().length + content2.amqEncoded().length,
            properties: [
                AMQBasicContentType("text/flame")
            ]
        )
        let expectedContentFrameset = AMQFrameset(
            channelNumber: 42,
            method: method,
            contentHeader: contentHeader,
            contentBodies: [content1, content2]
        )

        readerLoop.runOnce()

        transport
            .serverSendsPayload(method, channelNumber: 42)
            .serverSendsPayload(contentHeader, channelNumber: 42)
            .serverSendsPayload(content1, channelNumber: 42)
            .serverSendsPayload(content2, channelNumber: 42)

        XCTAssertEqual([expectedContentFrameset], frameHandler.receivedFramesets)
    }

    func testDeliveryWithZeroBodySizeDoesNotCauseBodyFrameRead() {
        let transport = ControlledInteractionTransport()
        let frameHandler = FrameHandlerSpy()
        let readerLoop = RMQReaderLoop(transport: transport, frameHandler: frameHandler)

        let deliver = AMQFrame(channelNumber: 42, payload: MethodFixtures.basicDeliver())
        let header = AMQFrame(channelNumber: 42, payload: AMQContentHeader(classID: 60, bodySize: 0, properties: []))

        readerLoop.runOnce()

        transport.serverSendsData(deliver.amqEncoded())

        let before = transport.readCallbacks.count
        transport.serverSendsData(header.amqEncoded())
        let after = transport.readCallbacks.count

        XCTAssertEqual(after, before)
    }

    func testDeliveryWithZeroBodySizeGetsSentToFrameHandler() {
        let transport = ControlledInteractionTransport()
        let frameHandler = FrameHandlerSpy()
        let readerLoop = RMQReaderLoop(transport: transport, frameHandler: frameHandler)

        let method = MethodFixtures.basicDeliver()
        let deliver = AMQFrame(channelNumber: 42, payload: method)
        let header = AMQContentHeader(classID: 60, bodySize: 0, properties: [])
        let headerFrame = AMQFrame(channelNumber: 42, payload: header)

        readerLoop.runOnce()

        transport.serverSendsData(deliver.amqEncoded())
        transport.serverSendsData(headerFrame.amqEncoded())

        XCTAssertEqual(AMQFrameset(channelNumber: 42, method: method, contentHeader: header, contentBodies: []),
                       frameHandler.lastReceivedFrameset())
    }

    func nonContentPayload() -> AMQBasicDeliver {
        return AMQBasicDeliver(consumerTag: AMQShortstr(""), deliveryTag: AMQLonglong(0), options: AMQBasicDeliverOptions.NoOptions, exchange: AMQShortstr(""), routingKey: AMQShortstr("somekey"))
    }
}
