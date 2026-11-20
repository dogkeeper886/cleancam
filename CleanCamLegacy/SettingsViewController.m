#import "SettingsViewController.h"

#import "CameraController.h"

static NSString *ExposureText(float bias) {
    return [NSString stringWithFormat:@"%+.1f EV", bias];
}

static NSString *WhiteBalanceText(int kelvins) {
    return [NSString stringWithFormat:@"%d K", kelvins];
}

@implementation SettingsViewController {
    CameraController *_camera;
    /// Each section's header, footer and rows. Each row holds its cell and, for a row you tap, a block that changes
    /// the options.
    NSArray<NSDictionary *> *_sections;
    UILabel *_exposureLabel;
    UILabel *_whiteBalanceLabel;
}

- (instancetype)initWithCamera:(CameraController *)camera {
    if (!(self = [super initWithStyle:UITableViewStyleGrouped])) return nil;
    _camera = camera;
    self.title = @"Settings";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 44;
    [self rebuild];
}

- (void)done {
    [self dismissViewControllerAnimated:YES completion:nil];
}

/// Builds the rows from the current options and what the camera supports.
- (void)rebuild {
    CameraOptions *options = _camera.options;
    NSMutableArray<NSDictionary *> *sections = [NSMutableArray array];

    NSMutableArray<NSDictionary *> *presets = [NSMutableArray array];
    for (NSString *preset in [CameraOptions presets]) {
        UITableViewCell *cell = [self choiceCell:[CameraOptions nameOfPreset:preset]
                                          detail:[CameraOptions summaryOfPreset:preset]
                                         checked:[options.preset isEqualToString:preset]];
        [presets addObject:@{@"cell": cell, @"select": [^(CameraOptions *changed) { changed.preset = preset; } copy]}];
    }
    [sections addObject:@{@"header": @"Preset", @"rows": presets}];

    if (_camera.canStabilize) {
        NSMutableArray<NSDictionary *> *stabilizations = [NSMutableArray array];
        for (NSString *stabilization in [CameraOptions stabilizations]) {
            UITableViewCell *cell = [self choiceCell:[CameraOptions nameOfStabilization:stabilization] detail:nil
                                             checked:[options.stabilization isEqualToString:stabilization]];
            [stabilizations addObject:@{
                @"cell": cell, @"select": [^(CameraOptions *changed) { changed.stabilization = stabilization; } copy],
            }];
        }
        [sections addObject:@{
            @"header": @"Stabilization", @"rows": stabilizations,
            @"footer": @"Auto turns stabilization on while the phone shakes and off while it stands still.",
        }];
    }

    NSMutableArray<NSDictionary *> *picture = [NSMutableArray array];
    NSMutableArray<NSString *> *pictureNotes = [NSMutableArray array];
    UISlider *exposure = [UISlider new];
    exposure.minimumValue = -kExposureBiasLimit;
    exposure.maximumValue = kExposureBiasLimit;
    exposure.value = options.exposureBias;
    [exposure addTarget:self action:@selector(exposureChanged:) forControlEvents:UIControlEventValueChanged];
    _exposureLabel = [UILabel new];
    _exposureLabel.text = ExposureText(options.exposureBias);
    [picture addObject:@{@"cell": [self sliderCell:@"Exposure" valueLabel:_exposureLabel slider:exposure]}];
    if (_camera.canFixWhiteBalance) {
        [picture addObject:@{
            @"cell": [self switchCell:@"Auto white balance" on:!options.whiteBalance action:@selector(autoWhiteBalanceChanged:)],
        }];
        if (options.whiteBalance) {
            UISlider *whiteBalance = [UISlider new];
            whiteBalance.minimumValue = kMinWhiteBalance;
            whiteBalance.maximumValue = kMaxWhiteBalance;
            whiteBalance.value = options.whiteBalance;
            [whiteBalance addTarget:self action:@selector(whiteBalanceChanged:) forControlEvents:UIControlEventValueChanged];
            _whiteBalanceLabel = [UILabel new];
            _whiteBalanceLabel.text = WhiteBalanceText(options.whiteBalance);
            [picture addObject:@{
                @"cell": [self sliderCell:@"White balance" valueLabel:_whiteBalanceLabel slider:whiteBalance],
            }];
            [pictureNotes addObject:@"Lower kelvins turn the picture blue, for warm lamps; higher ones turn it yellow, for shade."];
        }
    }
    if (_camera.canFocusNear) {
        [picture addObject:@{@"cell": [self switchCell:@"Near focus" on:options.nearFocus action:@selector(nearFocusChanged:)]}];
        [pictureNotes addObject:@"Near focus looks for close subjects first."];
    }
    [sections addObject:@{@"header": @"Picture", @"rows": picture, @"footer": [pictureNotes componentsJoinedByString:@" "]}];

    NSMutableArray<NSDictionary *> *bitRates = [NSMutableArray array];
    [bitRates addObject:@{
        @"cell": [self choiceCell:@"No limit" detail:nil checked:options.maxBitRate == 0],
        @"select": [^(CameraOptions *changed) { changed.maxBitRate = 0; } copy],
    }];
    for (NSNumber *bitRate in [CameraOptions maxBitRates]) {
        NSString *title = [NSString stringWithFormat:@"%d Mbps", bitRate.intValue / 1000000];
        [bitRates addObject:@{
            @"cell": [self choiceCell:title detail:nil checked:options.maxBitRate == bitRate.intValue],
            @"select": [^(CameraOptions *changed) { changed.maxBitRate = bitRate.intValue; } copy],
        }];
    }
    [sections addObject:@{@"header": @"Max bitrate", @"rows": bitRates}];

    _sections = sections;
    [self.tableView reloadData];
}

- (void)exposureChanged:(UISlider *)slider {
    float bias = roundf(slider.value * 10) / 10;
    if (bias == 0) bias = 0;  // +0, so the label never shows "-0.0 EV"
    if (bias == _camera.options.exposureBias) return;
    CameraOptions *options = [_camera.options copy];
    options.exposureBias = bias;
    [_camera setOptions:options];
    _exposureLabel.text = ExposureText(bias);
}

- (void)whiteBalanceChanged:(UISlider *)slider {
    int kelvins = (int)lroundf(slider.value / 100) * 100;
    if (kelvins == _camera.options.whiteBalance) return;
    CameraOptions *options = [_camera.options copy];
    options.whiteBalance = kelvins;
    [_camera setOptions:options];
    _whiteBalanceLabel.text = WhiteBalanceText(kelvins);
}

- (void)autoWhiteBalanceChanged:(UISwitch *)control {
    CameraOptions *options = [_camera.options copy];
    options.whiteBalance = control.on ? 0 : kDefaultWhiteBalance;
    [_camera setOptions:options];
    [self rebuild];
}

- (void)nearFocusChanged:(UISwitch *)control {
    CameraOptions *options = [_camera.options copy];
    options.nearFocus = control.on;
    [_camera setOptions:options];
}

- (UITableViewCell *)choiceCell:(NSString *)title detail:(NSString *)detail checked:(BOOL)checked {
    UITableViewCell *cell = [[UITableViewCell alloc]
          initWithStyle:detail ? UITableViewCellStyleSubtitle : UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text = title;
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = [UIColor grayColor];
    cell.accessoryType = checked ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (UITableViewCell *)switchCell:(NSString *)title on:(BOOL)on action:(SEL)action {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = title;
    UISwitch *control = [UISwitch new];
    control.on = on;
    [control addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = control;
    return cell;
}

/// A title and its value on one line, and the slider below them.
- (UITableViewCell *)sliderCell:(NSString *)title valueLabel:(UILabel *)valueLabel slider:(UISlider *)slider {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UILabel *titleLabel = [UILabel new];
    titleLabel.text = title;
    [titleLabel setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    valueLabel.textColor = [UIColor grayColor];
    valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:17 weight:UIFontWeightRegular];
    UIStackView *line = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, valueLabel]];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[line, slider]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:stack];
    UILayoutGuide *margins = cell.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:margins.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],
    ]];
    return cell;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return _sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [_sections[section][@"rows"] count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    return _sections[indexPath.section][@"rows"][indexPath.row][@"cell"];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return _sections[section][@"header"];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    NSString *footer = _sections[section][@"footer"];
    return footer.length ? footer : nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    void (^select)(CameraOptions *) = _sections[indexPath.section][@"rows"][indexPath.row][@"select"];
    if (!select) return;
    CameraOptions *options = [_camera.options copy];
    select(options);
    [_camera setOptions:options];
    [self rebuild];
}

@end
