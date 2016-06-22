#import "RMQGCDSerialQueue.h"
#import <libkern/OSAtomic.h>

typedef NS_ENUM(int32_t, RMQGCDSerialQueueStatus) {
    RMQGCDSerialQueueStatusNormal = 1,
    RMQGCDSerialQueueStatusSuspended,
};

@interface RMQGCDSerialQueue ()
@property (nonatomic, readwrite) NSString *name;
@property (nonatomic, readwrite) dispatch_queue_t dispatchQueue;
@property (atomic, readwrite) volatile int32_t status;
@property (nonatomic, readwrite) BOOL performOperations;
@end

@implementation RMQGCDSerialQueue

- (instancetype)initWithName:(NSString *)name {
    self = [super init];
    if (self) {
        self.performOperations = YES;
        self.name = name;
        self.status = RMQGCDSerialQueueStatusNormal;
        [self createQueue];
    }
    return self;
}

- (instancetype)init {
    [self doesNotRecognizeSelector:_cmd];
    return nil;
}

- (void)dealloc {
    [self resume];
}

- (void)enqueue:(RMQOperation)operation {
    dispatch_async(self.dispatchQueue, [self wrap:operation]);
}

- (void)blockingEnqueue:(RMQOperation)operation {
    dispatch_sync(self.dispatchQueue, [self wrap:operation]);
}

- (void)delayedBy:(NSNumber *)delay
          enqueue:(RMQOperation)operation {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                   self.dispatchQueue,
                   [self wrap:operation]);
}

- (void)suspend {
    if (self.status == RMQGCDSerialQueueStatusSuspended) {
        return;
    }
    while (true) {
        if (OSAtomicCompareAndSwap32(self.status,
                                     RMQGCDSerialQueueStatusSuspended,
                                     &_status)) {
            dispatch_suspend(self.dispatchQueue);
            return;
        }
    }
}

- (void)resume {
    if (self.status == RMQGCDSerialQueueStatusNormal) {
        return;
    }
    while (true) {
        if (OSAtomicCompareAndSwap32(self.status,
                                     RMQGCDSerialQueueStatusNormal,
                                     &_status)) {
            dispatch_resume(self.dispatchQueue);
            return;
        }
    }
}

- (void)reset {
    self.performOperations = NO;
    [self resume];
    [self blockingEnqueue:^{}];
    self.performOperations = YES;
    [self createQueue];
}

#pragma mark - Private

- (RMQOperation)wrap:(RMQOperation)operation {
    return ^{
        if (self.performOperations) {
            operation();
        }
    };
}

- (void)createQueue {
    NSString *qName = [NSString stringWithFormat:@"RMQGCDSerialQueue (%@)", self.name];
    self.dispatchQueue = dispatch_queue_create([qName cStringUsingEncoding:NSUTF8StringEncoding], NULL);
}

@end
