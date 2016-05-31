#import "RMQConnection.h"
#import "RMQConnectionShutdown.h"
#import "RMQConnectionRecover.h"
#import "RMQGCDHeartbeatSender.h"
#import "RMQGCDSerialQueue.h"
#import "RMQHandshaker.h"
#import "RMQMethods.h"
#import "RMQMultipleChannelAllocator.h"
#import "RMQProtocolHeader.h"
#import "RMQQueuingConnectionDelegateProxy.h"
#import "RMQReader.h"
#import "RMQSemaphoreWaiterFactory.h"
#import "RMQTCPSocketTransport.h"
#import "RMQURI.h"
#import "RMQTickingClock.h"
#import "RMQTLSOptions.h"
#import "RMQErrors.h"

NSInteger const RMQChannelLimit = 65535;

@interface RMQConnection ()
@property (strong, nonatomic, readwrite) id <RMQTransport> transport;
@property (nonatomic, readwrite) RMQReader *reader;
@property (nonatomic, readwrite) id <RMQChannelAllocator> channelAllocator;
@property (nonatomic, readwrite) id <RMQFrameHandler> frameHandler;
@property (nonatomic, readwrite) id<RMQLocalSerialQueue> commandQueue;
@property (nonatomic, readwrite) id<RMQWaiterFactory> waiterFactory;
@property (nonatomic, readwrite) id<RMQHeartbeatSender> heartbeatSender;
@property (nonatomic, weak, readwrite) id<RMQConnectionDelegate> delegate;
@property (nonatomic, readwrite) id <RMQChannel> channelZero;
@property (nonatomic, readwrite) RMQConnectionConfig *config;
@property (nonatomic, readwrite) NSMutableDictionary *userChannels;
@property (nonatomic, readwrite) NSNumber *frameMax;
@property (nonatomic, readwrite) BOOL handshakeComplete;
@property (nonatomic, readwrite) NSNumber *handshakeTimeout;
@end

@implementation RMQConnection

- (instancetype)initWithTransport:(id<RMQTransport>)transport
                           config:(RMQConnectionConfig *)config
                 handshakeTimeout:(NSNumber *)handshakeTimeout
                 channelAllocator:(nonnull id<RMQChannelAllocator>)channelAllocator
                     frameHandler:(nonnull id<RMQFrameHandler>)frameHandler
                         delegate:(id<RMQConnectionDelegate>)delegate
                     commandQueue:(nonnull id<RMQLocalSerialQueue>)commandQueue
                    waiterFactory:(nonnull id<RMQWaiterFactory>)waiterFactory
                  heartbeatSender:(nonnull id<RMQHeartbeatSender>)heartbeatSender {
    self = [super init];
    if (self) {
        self.config = config;
        self.handshakeComplete = NO;
        self.handshakeTimeout = handshakeTimeout;
        self.frameMax = config.frameMax;
        self.transport = transport;
        self.transport.delegate = self;
        self.channelAllocator = channelAllocator;
        self.channelAllocator.sender = self;
        self.frameHandler = frameHandler;
        self.reader = [[RMQReader alloc] initWithTransport:self.transport frameHandler:self];

        self.userChannels = [NSMutableDictionary new];
        self.delegate = delegate;
        self.commandQueue = commandQueue;
        self.waiterFactory = waiterFactory;
        self.heartbeatSender = heartbeatSender;

        self.channelZero = [self.channelAllocator allocate];
        [self.channelZero activateWithDelegate:self.delegate];
    }
    return self;
}

- (nonnull instancetype)initWithUri:(NSString *)uri
                         tlsOptions:(RMQTLSOptions *)tlsOptions
                         channelMax:(NSNumber *)channelMax
                           frameMax:(NSNumber *)frameMax
                          heartbeat:(NSNumber *)heartbeat
                        syncTimeout:(NSNumber *)syncTimeout
                           delegate:(id<RMQConnectionDelegate>)delegate
                      delegateQueue:(dispatch_queue_t)delegateQueue
                       recoverAfter:(nonnull NSNumber *)recoveryInterval
                   recoveryAttempts:(nonnull NSNumber *)recoveryAttempts {
    NSError *error = NULL;
    RMQURI *rmqURI = [RMQURI parse:uri error:&error];

    RMQTCPSocketTransport *transport = [[RMQTCPSocketTransport alloc] initWithHost:rmqURI.host
                                                                              port:rmqURI.portNumber
                                                                        tlsOptions:tlsOptions];
    RMQMultipleChannelAllocator *allocator = [[RMQMultipleChannelAllocator alloc] initWithChannelSyncTimeout:syncTimeout];
    RMQQueuingConnectionDelegateProxy *delegateProxy = [[RMQQueuingConnectionDelegateProxy alloc] initWithDelegate:delegate
                                                                                                             queue:delegateQueue];
    RMQSemaphoreWaiterFactory *waiterFactory = [RMQSemaphoreWaiterFactory new];
    RMQGCDHeartbeatSender *heartbeatSender = [[RMQGCDHeartbeatSender alloc] initWithTransport:transport
                                                                                        clock:[RMQTickingClock new]];
    RMQCredentials *credentials = [[RMQCredentials alloc] initWithUsername:rmqURI.username
                                                                  password:rmqURI.password];

    RMQGCDSerialQueue *commandQueue = [[RMQGCDSerialQueue alloc] initWithName:@"connection commands"];
    id<RMQConnectionRecovery> recovery;
    if (recoveryInterval.integerValue > 0) {
        recovery = [[RMQConnectionRecover alloc] initWithInterval:recoveryInterval
                                                     attemptLimit:recoveryAttempts
                                                       onlyErrors:NO
                                                  heartbeatSender:heartbeatSender
                                                     commandQueue:commandQueue
                                                         delegate:delegateProxy];
    } else {
        recovery = [[RMQConnectionShutdown alloc] initWithHeartbeatSender:heartbeatSender];
    }

    RMQConnectionConfig *config = [[RMQConnectionConfig alloc] initWithCredentials:credentials
                                                                        channelMax:channelMax
                                                                          frameMax:frameMax
                                                                         heartbeat:heartbeat
                                                                             vhost:rmqURI.vhost
                                                                     authMechanism:tlsOptions.authMechanism
                                                                          recovery:recovery];
    return [self initWithTransport:transport
                            config:config
                  handshakeTimeout:syncTimeout
                  channelAllocator:allocator
                      frameHandler:allocator
                          delegate:delegateProxy
                      commandQueue:commandQueue
                     waiterFactory:waiterFactory
                   heartbeatSender:heartbeatSender];
}

- (instancetype)initWithUri:(NSString *)uri
                 tlsOptions:(RMQTLSOptions *)tlsOptions
                 channelMax:(NSNumber *)channelMax
                   frameMax:(NSNumber *)frameMax
                  heartbeat:(NSNumber *)heartbeat
                syncTimeout:(NSNumber *)syncTimeout
                   delegate:(id<RMQConnectionDelegate>)delegate
              delegateQueue:(dispatch_queue_t)delegateQueue {
    return [self initWithUri:uri
                  tlsOptions:tlsOptions
                  channelMax:channelMax
                    frameMax:frameMax
                   heartbeat:heartbeat
                 syncTimeout:syncTimeout
                    delegate:delegate
               delegateQueue:delegateQueue
                recoverAfter:@0
            recoveryAttempts:@0];
}

- (instancetype)initWithUri:(NSString *)uri
                 channelMax:(NSNumber *)channelMax
                   frameMax:(NSNumber *)frameMax
                  heartbeat:(NSNumber *)heartbeat
                syncTimeout:(NSNumber *)syncTimeout
                   delegate:(id<RMQConnectionDelegate>)delegate
              delegateQueue:(dispatch_queue_t)delegateQueue {
    return [self initWithUri:uri
                  tlsOptions:[RMQTLSOptions fromURI:uri]
                  channelMax:channelMax
                    frameMax:frameMax
                   heartbeat:heartbeat
                 syncTimeout:syncTimeout
                    delegate:delegate
               delegateQueue:delegateQueue];
}

- (instancetype)initWithUri:(NSString *)uri
                 tlsOptions:(RMQTLSOptions *)tlsOptions
                   delegate:(id<RMQConnectionDelegate>)delegate {
    return [self initWithUri:uri
                  tlsOptions:tlsOptions
                  channelMax:@(RMQChannelLimit)
                    frameMax:@131072
                   heartbeat:@0
                 syncTimeout:@10
                    delegate:delegate
               delegateQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)];
}

- (instancetype)initWithUri:(NSString *)uri
                 verifyPeer:(BOOL)verifyPeer
                   delegate:(id<RMQConnectionDelegate>)delegate {
    RMQTLSOptions *tlsOptions = [RMQTLSOptions fromURI:uri verifyPeer:verifyPeer];
    return [self initWithUri:uri tlsOptions:tlsOptions delegate:delegate];
}

- (instancetype)initWithUri:(NSString *)uri
                   delegate:(id<RMQConnectionDelegate>)delegate {
    return [self initWithUri:uri
                  tlsOptions:[RMQTLSOptions fromURI:uri]
                    delegate:delegate];
}

- (instancetype)initWithDelegate:(id<RMQConnectionDelegate>)delegate {
    return [self initWithUri:@"amqp://guest:guest@localhost" delegate:delegate];
}

- (instancetype)init
{
    return [self initWithDelegate:nil];
}

- (void)start:(void (^)())completionHandler {
    NSError *connectError = NULL;

    [self.transport connectAndReturnError:&connectError];
    if (connectError) {
        [self.delegate connection:self failedToConnectWithError:connectError];
    } else {
        [self.transport write:[RMQProtocolHeader new].amqEncoded];

        [self.commandQueue enqueue:^{
            id<RMQWaiter> handshakeCompletion = [self.waiterFactory makeWithTimeout:self.handshakeTimeout];

            RMQHandshaker *handshaker = [[RMQHandshaker alloc] initWithSender:self
                                                                       config:self.config
                                                            completionHandler:^(NSNumber *heartbeatInterval) {
                                                                [self.heartbeatSender startWithInterval:heartbeatInterval];
                                                                [handshakeCompletion done];
                                                                [self.reader run];
                                                                self.handshakeComplete = YES;
                                                                completionHandler();
                                                            }];
            RMQReader *handshakeReader = [[RMQReader alloc] initWithTransport:self.transport
                                                                 frameHandler:handshaker];
            handshaker.reader = handshakeReader;
            [handshakeReader run];

            if (handshakeCompletion.timesOut) {
                NSError *error = [NSError errorWithDomain:RMQErrorDomain
                                                     code:RMQErrorConnectionHandshakeTimedOut
                                                 userInfo:@{NSLocalizedDescriptionKey: @"Handshake timed out."}];
                [self.delegate connection:self failedToConnectWithError:error];
            }
        }];
    }
}

- (void)start {
    [self start:^{}];
}

- (id<RMQChannel>)createChannel {
    id<RMQChannel> ch = self.channelAllocator.allocate;
    self.userChannels[ch.channelNumber] = ch;

    [self.commandQueue enqueue:^{
        [ch activateWithDelegate:self.delegate];
    }];

    [ch open];

    return ch;
}

- (void)close {
    for (RMQOperation operation in self.closeOperations) {
        [self.commandQueue enqueue:operation];
    }
}

- (void)blockingClose {
    for (RMQOperation operation in self.closeOperations) {
        [self.commandQueue blockingEnqueue:operation];
    }
}

# pragma mark - RMQSender

- (void)sendFrameset:(RMQFrameset *)frameset
               force:(BOOL)isForced {
    if (self.handshakeComplete || isForced) {
        [self.transport write:frameset.amqEncoded];
        [self.heartbeatSender signalActivity];
    } else {
        double handshakeVersusChannelRaceLeeway = 1;
        [self.commandQueue delayedBy:@(self.config.recovery.interval.integerValue + handshakeVersusChannelRaceLeeway)
                             enqueue:^{
                                 [self.transport write:frameset.amqEncoded];
                                 [self.heartbeatSender signalActivity];
                             }];
    }
}

- (void)sendFrameset:(RMQFrameset *)frameset {
    [self sendFrameset:frameset force:NO];
}

# pragma mark - RMQFrameHandler

- (void)handleFrameset:(RMQFrameset *)frameset {
    id method = frameset.method;

    if ([method isKindOfClass:[RMQConnectionClose class]]) {
        [self sendFrameset:[[RMQFrameset alloc] initWithChannelNumber:@0 method:[RMQConnectionCloseOk new]]];
        self.handshakeComplete = NO;
        [self.transport close];
    } else {
        [self.frameHandler handleFrameset:frameset];
        [self.reader run];
    }
}

# pragma mark - RMQTransportDelegate

- (void)transport:(id<RMQTransport>)transport failedToWriteWithError:(NSError *)error {
    [self.delegate connection:self failedToWriteWithError:error];
}

- (void)transport:(id<RMQTransport>)transport disconnectedWithError:(NSError *)error {
    if (error) [self.delegate connection:self disconnectedWithError:error];
    [self.recovery recover:self
          channelAllocator:self.channelAllocator
                     error:error];
}

# pragma mark - Private

- (NSArray *)closeOperations {
    return @[^{[self closeAllUserChannels];},
              ^{[self sendFrameset:[[RMQFrameset alloc] initWithChannelNumber:@0 method:self.amqClose]];},
              ^{[self.channelZero blockingWaitOn:[RMQConnectionCloseOk class]];},
              ^{[self.heartbeatSender stop];},
              ^{[self.transport close];}];
}

- (void)closeAllUserChannels {
    for (id<RMQChannel> ch in self.userChannels.allValues) {
        [ch blockingClose];
    }
}

- (RMQConnectionClose *)amqClose {
    return [[RMQConnectionClose alloc] initWithReplyCode:[[RMQShort alloc] init:200]
                                               replyText:[[RMQShortstr alloc] init:@"Goodbye"]
                                                 classId:[[RMQShort alloc] init:0]
                                                methodId:[[RMQShort alloc] init:0]];
}

- (id<RMQConnectionRecovery>)recovery {
    return self.config.recovery;
}

@end
