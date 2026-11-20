#import <UIKit/UIKit.h>

@class CameraController;

/// Picks the preset and the camera options. The camera follows each change at once, and the app keeps them for the
/// next start. It offers only what this camera supports.
@interface SettingsViewController : UITableViewController

- (instancetype)initWithCamera:(CameraController *)camera;

@end
