#import "CameraOptions.h"

const float kExposureBiasLimit = 2;
const int kMinWhiteBalance = 2500;
const int kMaxWhiteBalance = 8000;
const int kDefaultWhiteBalance = 5000;  // daylight

static NSString *const kKey = @"options";

@implementation CameraOptions

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _preset = @"call";
    _stabilization = @"auto";
    return self;
}

+ (instancetype)saved {
    CameraOptions *options = [CameraOptions new];
    NSDictionary *saved = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kKey];
    if ([[self presets] containsObject:saved[@"preset"]]) options.preset = saved[@"preset"];
    if ([[self stabilizations] containsObject:saved[@"stabilization"]]) options.stabilization = saved[@"stabilization"];
    options.exposureBias = MIN(MAX([saved[@"exposureBias"] floatValue], -kExposureBiasLimit), kExposureBiasLimit);
    int kelvins = [saved[@"whiteBalance"] intValue];
    if (kelvins >= kMinWhiteBalance && kelvins <= kMaxWhiteBalance) options.whiteBalance = kelvins;
    options.nearFocus = [saved[@"nearFocus"] boolValue];
    options.maxBitRate = MAX([saved[@"maxBitRate"] intValue], 0);
    return options;
}

- (void)save {
    [[NSUserDefaults standardUserDefaults] setObject:@{
        @"preset": self.preset, @"stabilization": self.stabilization, @"exposureBias": @(self.exposureBias),
        @"whiteBalance": @(self.whiteBalance), @"nearFocus": @(self.nearFocus), @"maxBitRate": @(self.maxBitRate),
    } forKey:kKey];
}

- (id)copyWithZone:(NSZone *)zone {
    CameraOptions *copy = [CameraOptions new];
    copy.preset = self.preset;
    copy.stabilization = self.stabilization;
    copy.exposureBias = self.exposureBias;
    copy.whiteBalance = self.whiteBalance;
    copy.nearFocus = self.nearFocus;
    copy.maxBitRate = self.maxBitRate;
    return copy;
}

+ (NSArray<NSString *> *)presets {
    return @[@"call", @"lowlight"];
}

+ (NSString *)nameOfPreset:(NSString *)preset {
    return [preset isEqualToString:@"lowlight"] ? @"Low light" : @"Call";
}

+ (NSString *)summaryOfPreset:(NSString *)preset {
    return [preset isEqualToString:@"lowlight"]
        ? @"15–30 fps. Slows further in the dark for a brighter, cleaner face, but moves less smoothly."
        : @"20–30 fps, for Zoom, Meet and Teams, which send 30. Slows toward 20 in a dim room.";
}

+ (int)bottomFrameRateOfPreset:(NSString *)preset {
    return [preset isEqualToString:@"lowlight"] ? 15 : 20;
}

+ (NSArray<NSString *> *)stabilizations {
    return @[@"auto", @"off", @"standard"];
}

+ (NSString *)nameOfStabilization:(NSString *)stabilization {
    if ([stabilization isEqualToString:@"off"]) return @"Off";
    if ([stabilization isEqualToString:@"standard"]) return @"Standard";
    return @"Auto";
}

+ (NSArray<NSNumber *> *)maxBitRates {
    return @[@20000000, @10000000, @6000000, @3000000];
}

@end
