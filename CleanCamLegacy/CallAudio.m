#import "CallAudio.h"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <os/lock.h>

static const double kSampleRate = 48000;
enum {
    /// Silence played before the first sound, and after the queue runs dry, to absorb uneven delivery.
    kPrebufferFrames = 1920,  // 40 ms
    /// At most this much is queued; older sound beyond it is dropped, so the delay stays short after a burst
    /// or when the PC's clock runs faster than the phone's.
    kMaxQueuedFrames = 3840,  // 80 ms
    /// More than the audio unit asks for in one callback.
    kMaxCallbackFrames = 4096,
};

@interface CallAudio ()
- (void)fillSpeaker:(int16_t *)samples frames:(UInt32)frames;
- (void)captureMic:(AudioUnitRenderActionFlags *)flags timeStamp:(const AudioTimeStamp *)timeStamp frames:(UInt32)frames;
@end

static OSStatus RenderSpeaker(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timeStamp,
                              UInt32 bus, UInt32 frames, AudioBufferList *data) {
    [(__bridge CallAudio *)refCon fillSpeaker:data->mBuffers[0].mData frames:frames];
    return noErr;
}

static OSStatus CaptureMic(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timeStamp,
                           UInt32 bus, UInt32 frames, AudioBufferList *data) {
    [(__bridge CallAudio *)refCon captureMic:flags timeStamp:timeStamp frames:frames];
    return noErr;
}

@implementation CallAudio {
    dispatch_queue_t _queue;
    // Used on _queue only.
    AudioUnit _unit;
    BOOL _micAllowed;
    BOOL _micRunning;
    NSMutableData *_leftover;

    // Shared with the audio thread, under _lock.
    os_unfair_lock _lock;
    int16_t _queued[kMaxQueuedFrames];
    int _queuedStart;
    int _queuedFrames;
    BOOL _micEnabled;

    // Used on the audio thread only.
    int16_t _micSamples[kMaxCallbackFrames];
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _queue = dispatch_queue_create("cleancam.callaudio", DISPATCH_QUEUE_SERIAL);
    _leftover = [NSMutableData data];
    _lock = OS_UNFAIR_LOCK_INIT;
    _micEnabled = YES;
    // An interruption, such as a call, stops the audio unit.
    __weak CallAudio *weakSelf = self;
    [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:nil
                                                  usingBlock:^(NSNotification *note) {
        CallAudio *strongSelf = weakSelf;
        if (!strongSelf || [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue]
                                != AVAudioSessionInterruptionTypeEnded) return;
        dispatch_async(strongSelf->_queue, ^{ [strongSelf startUnit]; });
    }];
    return self;
}

- (void)startWithMicAllowed:(BOOL)micAllowed onMicReady:(void (^)(BOOL micRunning))onMicReady {
    dispatch_async(_queue, ^{
        self->_micAllowed = micAllowed;
        onMicReady([self startUnit]);
    });
}

- (void)stop {
    dispatch_async(_queue, ^{
        if (self->_unit) AudioOutputUnitStop(self->_unit);
        [self clearQueue];
        [[AVAudioSession sharedInstance] setActive:NO
                                       withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
    });
}

- (void)setMicEnabled:(BOOL)enabled {
    os_unfair_lock_lock(&_lock);
    _micEnabled = enabled;
    os_unfair_lock_unlock(&_lock);
}

- (void)play:(NSData *)data {
    dispatch_async(_queue, ^{ [self enqueue:data]; });
}

/// Called on _queue. Returns whether the microphone runs.
- (BOOL)startUnit {
    if ([self isUnitRunning]) return _micRunning;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    // defaultToSpeaker plays on the loudspeaker instead of the earpiece.
    if (![session setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeVoiceChat
                      options:AVAudioSessionCategoryOptionDefaultToSpeaker error:nil]) return NO;
    [session setPreferredSampleRate:kSampleRate error:nil];
    if (![session setActive:YES error:nil]) return NO;

    if (!_unit && ![self makeUnit]) return NO;
    // A stopped unit leaves stale sound queued; start the queue afresh.
    [self clearQueue];
    _micRunning = AudioOutputUnitStart(_unit) == noErr && _micAllowed;
    return _micRunning;
}

/// Called on _queue.
- (BOOL)makeUnit {
    AudioComponentDescription description = {
        .componentType = kAudioUnitType_Output,
        .componentSubType = kAudioUnitSubType_VoiceProcessingIO,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
    };
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    if (!component || AudioComponentInstanceNew(component, &_unit) != noErr) {
        _unit = NULL;
        return NO;
    }
    // Bus 1 is the microphone and bus 0 the loudspeaker.
    UInt32 enableInput = _micAllowed ? 1 : 0;
    AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableInput,
                         sizeof enableInput);
    AudioStreamBasicDescription format = {
        .mSampleRate = kSampleRate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = 2,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = 2,
        .mChannelsPerFrame = 1,
        .mBitsPerChannel = 16,
    };
    // The unit converts between this format and the hardware's.
    AudioUnitSetProperty(_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof format);
    AudioUnitSetProperty(_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, sizeof format);
    AURenderCallbackStruct render = {RenderSpeaker, (__bridge void *)self};
    AudioUnitSetProperty(_unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &render, sizeof render);
    if (_micAllowed) {
        AURenderCallbackStruct capture = {CaptureMic, (__bridge void *)self};
        AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &capture,
                             sizeof capture);
    }
    if (AudioUnitInitialize(_unit) != noErr) {
        AudioComponentInstanceDispose(_unit);
        _unit = NULL;
        return NO;
    }
    return YES;
}

/// Called on _queue.
- (BOOL)isUnitRunning {
    if (!_unit) return NO;
    UInt32 running = 0;
    UInt32 size = sizeof running;
    AudioUnitGetProperty(_unit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &running, &size);
    return running != 0;
}

/// Called on _queue.
- (void)clearQueue {
    _leftover.length = 0;
    os_unfair_lock_lock(&_lock);
    _queuedStart = 0;
    _queuedFrames = 0;
    os_unfair_lock_unlock(&_lock);
}

/// Called on _queue.
- (void)enqueue:(NSData *)data {
    if (![self isUnitRunning]) return;
    // TCP can split a 16-bit sample; the odd byte waits for the next chunk.
    [_leftover appendData:data];
    int received = (int)(_leftover.length / 2);
    if (received == 0) return;
    const int16_t *samples = _leftover.bytes;

    os_unfair_lock_lock(&_lock);
    if (_queuedFrames == 0) [self append:NULL frames:kPrebufferFrames];
    // Keep the newest sound that fits; what arrives late in a burst is stale.
    int frames = MIN(received, kMaxQueuedFrames - _queuedFrames);
    if (frames > 0) [self append:samples + (received - frames) frames:frames];
    os_unfair_lock_unlock(&_lock);

    [_leftover replaceBytesInRange:NSMakeRange(0, (NSUInteger)received * 2) withBytes:NULL length:0];
}

/// Called under _lock. Appends silence when `samples` is NULL.
- (void)append:(const int16_t *)samples frames:(int)frames {
    for (int i = 0; i < frames; i++) {
        _queued[(_queuedStart + _queuedFrames) % kMaxQueuedFrames] = samples ? samples[i] : 0;
        _queuedFrames += 1;
    }
}

/// Called on the audio thread; plays silence once the queue runs dry.
- (void)fillSpeaker:(int16_t *)samples frames:(UInt32)frames {
    os_unfair_lock_lock(&_lock);
    UInt32 count = MIN(frames, (UInt32)_queuedFrames);
    for (UInt32 i = 0; i < count; i++) {
        samples[i] = _queued[(_queuedStart + (int)i) % kMaxQueuedFrames];
    }
    _queuedStart = (_queuedStart + (int)count) % kMaxQueuedFrames;
    _queuedFrames -= (int)count;
    os_unfair_lock_unlock(&_lock);
    memset(samples + count, 0, (frames - count) * sizeof *samples);
}

/// Called on the audio thread.
- (void)captureMic:(AudioUnitRenderActionFlags *)flags timeStamp:(const AudioTimeStamp *)timeStamp frames:(UInt32)frames {
    if (frames > kMaxCallbackFrames) return;
    AudioBufferList list = {
        .mNumberBuffers = 1,
        .mBuffers = {{.mNumberChannels = 1, .mDataByteSize = frames * sizeof *_micSamples, .mData = _micSamples}},
    };
    if (AudioUnitRender(_unit, flags, timeStamp, 1, frames, &list) != noErr) return;
    os_unfair_lock_lock(&_lock);
    BOOL enabled = _micEnabled;
    os_unfair_lock_unlock(&_lock);
    if (enabled && self.onMicPCM) self.onMicPCM([NSData dataWithBytes:_micSamples length:list.mBuffers[0].mDataByteSize]);
}

@end
