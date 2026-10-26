#import <Foundation/Foundation.h>

/// TCP server that sends a stream, the H.264 video or the PCM audio, to every connected client,
/// or receives one, the PC's speaker audio.
/// Over USB the PC reaches it through usbmuxd (`iproxy`); over WiFi a PC can connect to the phone's IP directly.
@interface StreamServer : NSObject

@property (nonatomic, copy) void (^onClientsChanged)(NSUInteger count);
/// When set, called on the server's queue with whatever a client sends.
@property (nonatomic, copy) void (^onReceive)(NSData *data);
@property (nonatomic, readonly) BOOL hasClients;

- (instancetype)initWithPort:(uint16_t)port;
- (void)start;
- (void)stop;
- (void)broadcast:(NSData *)data isKeyframe:(BOOL)isKeyframe;
/// The most sends any client had waiting since the last call, up to 30.
/// It grows when the link carries less than the stream sends.
- (int)takePeakBacklog;

@end
