#import "StreamServer.h"

#import <errno.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <sys/socket.h>
#import <unistd.h>

/// About one second of video or half a second of audio.
/// A client further behind skips ahead to the next keyframe instead of lagging more.
static const int kMaxPendingSends = 30;

@interface StreamClient : NSObject
@property (nonatomic) int fd;
/// Sends block on this queue, one client's sends after another.
@property (nonatomic, strong) dispatch_queue_t sendQueue;
@property (nonatomic, strong) dispatch_source_t readSource;
@property (nonatomic) BOOL waitingForKeyframe;
@property (nonatomic) int pendingSends;
@end

@implementation StreamClient
@end

static BOOL SendAll(int fd, NSData *data) {
    const uint8_t *bytes = data.bytes;
    size_t left = data.length;
    while (left > 0) {
        ssize_t sent = send(fd, bytes, left, 0);
        if (sent < 0 && errno == EINTR) continue;
        if (sent <= 0) return NO;
        bytes += sent;
        left -= (size_t)sent;
    }
    return YES;
}

@implementation StreamServer {
    uint16_t _port;
    dispatch_queue_t _queue;
    // Used on _queue only.
    dispatch_source_t _listenSource;
    NSMutableSet<StreamClient *> *_clients;

    NSLock *_lock;
    NSUInteger _clientCount;
    int _peakBacklog;
}

- (instancetype)initWithPort:(uint16_t)port {
    if (!(self = [super init])) return nil;
    _port = port;
    _queue = dispatch_queue_create("cleancam.server", DISPATCH_QUEUE_SERIAL);
    _clients = [NSMutableSet set];
    _lock = [NSLock new];
    return self;
}

- (BOOL)hasClients {
    [_lock lock];
    BOOL hasClients = _clientCount > 0;
    [_lock unlock];
    return hasClients;
}

- (int)takePeakBacklog {
    [_lock lock];
    int peak = _peakBacklog;
    _peakBacklog = 0;
    [_lock unlock];
    return peak;
}

- (void)start {
    dispatch_async(_queue, ^{
        if (self->_listenSource) return;
        int fd = [self openListener];
        if (fd < 0) {
            // The port can stay taken for a moment after the app comes back; try again.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), self->_queue, ^{ [self start]; });
            return;
        }
        dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, self->_queue);
        dispatch_source_set_event_handler(source, ^{ [self acceptFrom:fd]; });
        dispatch_source_set_cancel_handler(source, ^{ close(fd); });
        dispatch_resume(source);
        self->_listenSource = source;
        [self clientsChanged];
    });
}

- (void)stop {
    dispatch_async(_queue, ^{
        if (self->_listenSource) {
            dispatch_source_cancel(self->_listenSource);
            self->_listenSource = nil;
        }
        for (StreamClient *client in [self->_clients copy]) [self remove:client];
        [self clientsChanged];
    });
}

- (void)broadcast:(NSData *)data isKeyframe:(BOOL)isKeyframe {
    dispatch_async(_queue, ^{
        int backlog = 0;
        for (StreamClient *client in self->_clients) {
            if (client.waitingForKeyframe) {
                if (!isKeyframe) continue;
                client.waitingForKeyframe = NO;
            }
            backlog = MAX(backlog, client.pendingSends);
            if (client.pendingSends >= kMaxPendingSends) {
                client.waitingForKeyframe = YES;
                continue;
            }
            client.pendingSends += 1;
            int fd = client.fd;
            dispatch_async(client.sendQueue, ^{
                BOOL sent = SendAll(fd, data);
                dispatch_async(self->_queue, ^{
                    client.pendingSends -= 1;
                    if (!sent) [self remove:client];
                });
            });
        }
        [self->_lock lock];
        self->_peakBacklog = MAX(self->_peakBacklog, backlog);
        [self->_lock unlock];
    });
}

/// Returns a non-blocking socket listening on the port over IPv4 and IPv6, or -1.
- (int)openListener {
    int fd = socket(AF_INET6, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int yes = 1, no = 0;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes);
    setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &no, sizeof no);
    struct sockaddr_in6 address = {0};
    address.sin6_len = sizeof address;
    address.sin6_family = AF_INET6;
    address.sin6_port = htons(_port);
    address.sin6_addr = in6addr_any;
    if (bind(fd, (struct sockaddr *)&address, sizeof address) != 0 || listen(fd, 4) != 0
        || fcntl(fd, F_SETFL, O_NONBLOCK) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

- (void)acceptFrom:(int)listener {
    int fd = accept(listener, NULL, NULL);
    if (fd < 0) return;
    // The socket inherits the listener's non-blocking flag; sends block on the client's own queue instead.
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK);
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof yes);
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof yes);

    StreamClient *client = [StreamClient new];
    client.fd = fd;
    client.waitingForKeyframe = YES;
    dispatch_queue_t sendQueue = dispatch_queue_create("cleancam.client", DISPATCH_QUEUE_SERIAL);
    client.sendQueue = sendQueue;
    // Reading also notices when the client leaves.
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, _queue);
    __weak StreamClient *weakClient = client;
    dispatch_source_set_event_handler(source, ^{ [self readFrom:weakClient]; });
    // Close after the sends already queued, which fail once the socket is shut down.
    dispatch_source_set_cancel_handler(source, ^{
        dispatch_async(sendQueue, ^{ close(fd); });
    });
    client.readSource = source;
    [_clients addObject:client];
    dispatch_resume(source);
    [self clientsChanged];
}

- (void)readFrom:(StreamClient *)client {
    if (!client) return;
    uint8_t buffer[65536];
    ssize_t count = recv(client.fd, buffer, sizeof buffer, 0);
    if (count > 0) {
        if (self.onReceive) self.onReceive([NSData dataWithBytes:buffer length:(NSUInteger)count]);
    } else if (count == 0 || (errno != EINTR && errno != EAGAIN)) {
        [self remove:client];
    }
}

- (void)remove:(StreamClient *)client {
    if (![_clients containsObject:client]) return;
    [_clients removeObject:client];
    shutdown(client.fd, SHUT_RDWR);
    dispatch_source_cancel(client.readSource);
    [self clientsChanged];
}

- (void)clientsChanged {
    NSUInteger count = _clients.count;
    [_lock lock];
    _clientCount = count;
    [_lock unlock];
    if (self.onClientsChanged) self.onClientsChanged(count);
}

@end
