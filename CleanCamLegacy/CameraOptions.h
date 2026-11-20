#import <Foundation/Foundation.h>

/// The exposure compensations the settings sheet offers, from minus to plus this many EV.
extern const float kExposureBiasLimit;
/// The fixed white balances the settings sheet offers, in kelvins, and the one a fixed white balance starts at.
extern const int kMinWhiteBalance;
extern const int kMaxWhiteBalance;
extern const int kDefaultWhiteBalance;

/// The preset and the camera options the user picked in the settings sheet. The app keeps them for the next start.
/// The presets and stabilizations go by their debug-port names, such as "lowlight" and "standard".
@interface CameraOptions : NSObject <NSCopying>

/// "call" or "lowlight".
@property (nonatomic, copy) NSString *preset;
/// "auto", "off" or "standard".
@property (nonatomic, copy) NSString *stabilization;
/// Exposure compensation in EV; 0 leaves auto exposure as it is.
@property (nonatomic) float exposureBias;
/// A fixed white balance in kelvins, or 0 for iOS's auto white balance.
@property (nonatomic) int whiteBalance;
/// Autofocus looks for near subjects first.
@property (nonatomic) BOOL nearFocus;
/// The highest bitrate the stream sends, or 0 for no limit.
@property (nonatomic) int maxBitRate;

/// The options the user picked last, or the defaults.
+ (instancetype)saved;
- (void)save;

+ (NSArray<NSString *> *)presets;
+ (NSString *)nameOfPreset:(NSString *)preset;
+ (NSString *)summaryOfPreset:(NSString *)preset;
/// The rate auto exposure slows toward in the dark; every preset holds 30 fps in good light.
+ (int)bottomFrameRateOfPreset:(NSString *)preset;
+ (NSArray<NSString *> *)stabilizations;
+ (NSString *)nameOfStabilization:(NSString *)stabilization;
/// The highest bitrates the settings sheet offers.
+ (NSArray<NSNumber *> *)maxBitRates;

@end
