// The loading screen (PocketLoadingView.h).
//
// Progress: the runtime log (Documents/native-guest.log) grows steadily while the game starts,
// about 1100 to 1200 lines from its opening to the line saying the game's window is on screen.
// The bar shows the lines so far over the count the last start reached there (kept in
// NSUserDefaults when the window appears; 1150 until then), held at 97% until it does. The game
// holds the main thread for long stretches meanwhile, so the bar, its percentage and the step
// are Core Animation layers changed from a background queue in explicit transactions, flushed
// there, as Tolkara's startup activity is (launcher/App/StartupActivity.m).
#import "PocketLoadingView.h"
#import "PocketGameUpdates.h"
#import <QuartzCore/QuartzCore.h>
#include <stdatomic.h>
#include <string.h>

static NSString *const LogLinesKey = @"PocketLoadingLogLines";   // lines up to the game's window, last start
static const NSInteger DefaultLogLines = 1150;
static const double ProgressCap = 0.97;
static const char WindowMarker[] = "window 'Brighter Shores' on screen";

// A view whose sublayers take its bounds (the step's and the percentage's text layers).
@interface PocketLayerHost : UIView
@property(nonatomic) CGFloat height;
@property(nonatomic, copy, nullable) void (^laidOut)(CGRect bounds);
@end
@implementation PocketLayerHost
- (CGSize)intrinsicContentSize { return CGSizeMake(UIViewNoIntrinsicMetric, self.height); }
- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer *layer in self.layer.sublayers) layer.frame = self.bounds;
    [CATransaction commit];
    if (self.laidOut) self.laidOut(self.bounds);
}
@end

// The launcher's status label: tells the screen what it now says.
@interface PocketStatusLabel : UILabel
@property(nonatomic, weak) PocketLoadingView *screen;
@end
@interface PocketLoadingView ()
- (void)statusChanged:(nullable NSString *)text;
@end
@implementation PocketStatusLabel
- (void)setText:(NSString *)text {
    [super setText:text];
    [self.screen statusChanged:text];
}
@end

// What a status line of the launcher (or of the Steam sign-in) means for the player; nil for
// one it does not know.
static NSString *PlainStep(NSString *status) {
    NSString *line = [status componentsSeparatedByString:@"\n"].firstObject ?: @"";
    for (NSString *plain in @[@"Signing in", @"Checking", @"Waiting for", @"Getting your", @"Reconnecting"])
        if ([line hasPrefix:plain]) return line;
    if ([status containsString:@"execution memory"]) return @"Getting the game's memory ready… This can take a few minutes.";
    if ([line hasPrefix:@"Synchronizing Steam Cloud"]) return @"Syncing your saves with Steam Cloud…";
    if ([line hasPrefix:@"Signing "] && [line containsString:@"for this device"]) return @"Signing the game for this device…";
    if ([line hasPrefix:@"Preparing"]) return @"Getting ready…";
    if ([line hasPrefix:@"Starting"]) return @"Starting Brighter Shores…";
    if ([line hasPrefix:@"Loading"]) return @"Loading the game…";
    return nil;
}
// A start that ended, in plain words; the launcher's own text stays in Details.
static NSString *PlainFailure(NSString *status) {
    NSString *again = @"Close Brighter Pocket in the app switcher and open it again to try again.";
    if ([status hasPrefix:@"Native startup stopped"])
        return [NSString stringWithFormat:@"The game stopped while it was starting. %@ If it happens again, Details has the log to share.", again];
    if ([status hasPrefix:@"Steam Cloud sync failed"])
        return [NSString stringWithFormat:@"Your saves couldn't be synced with Steam Cloud, so the game didn't start. Your saves are kept "
                                          @"on this device. Check the internet connection, then %@", again.lowercaseString];
    if ([status hasPrefix:@"Cannot open native runtime log"])
        return @"Brighter Pocket couldn't write its log. Free some storage space on this device, then open the app again.";
    if ([status hasPrefix:@"Local launch could not prepare"] || [status hasPrefix:@"Developer service could not prepare"])
        return [NSString stringWithFormat:@"The game's memory couldn't be prepared. %@", again];
    if ([status hasPrefix:@"Local signing could not start"])
        return [NSString stringWithFormat:@"This device's copy of the game couldn't be started. %@", again];
    return status;
}

@implementation PocketLoadingView {
    PocketStatusLabel *_status;
    UIStackView *_stack;
    CATextLayer *_step, *_percent;
    UIView *_progress;
    CALayer *_fill;
    UILabel *_message;
    UIButton *_detailsButton;
    UIView *_details;
    PocketLayerHost *_stepHost;
    UITraitCollection *_traits;   // for the layers' colours, which the background queue sets too
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    _Atomic double _trackWidth, _fraction;
    BOOL _watching, _stopped, _problem;
}

static const CGFloat BarHeight = 4;

static CATextLayer *TextLayer(UIFont *font) {
    CATextLayer *text = [CATextLayer layer];
    text.font = (__bridge CFTypeRef)font;
    text.fontSize = font.pointSize;
    text.alignmentMode = kCAAlignmentCenter;
    text.wrapped = YES;
    text.truncationMode = kCATruncationEnd;
    text.contentsScale = UIScreen.mainScreen.scale;
    return text;
}

- (instancetype)initWithDetails:(NSArray<UIView *> *)details diagnostics:(UIButton *)diagnostics {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    self.backgroundColor = UIColor.systemBackgroundColor;
    _traits = self.traitCollection;
    _queue = dispatch_queue_create("pocket.loading-progress", DISPATCH_QUEUE_SERIAL);
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(launchProgress:) name:PocketLaunchProgressNotification object:nil];
    __weak PocketLoadingView *weakSelf = self;
    [self registerForTraitChanges:@[UITraitUserInterfaceStyle.class] withHandler:^(__unused id<UITraitEnvironment> environment, __unused UITraitCollection *previous) {
        [weakSelf coloursChanged];
    }];

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = NO;
    scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;   // the constraints below keep to the safe area
    [self addSubview:scroll];
    UIView *page = [UIView new];
    page.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:page];
    _stack = [UIStackView new];
    _stack.axis = UILayoutConstraintAxisVertical;
    _stack.alignment = UIStackViewAlignmentCenter;
    _stack.spacing = 12;
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    [page addSubview:_stack];

    // The app's lockup, as brighteratlas.com/pocket shows it (tools/make_icons.py draws it, light
    // and dark): at its own size, smaller only on a screen too narrow for it. The name in bold
    // in a build without it.
    UIImage *lockup = [UIImage imageNamed:@"PocketLockup"];
    UIView *title;
    if (lockup) {
        UIImageView *image = [[UIImageView alloc] initWithImage:lockup];
        image.contentMode = UIViewContentModeScaleAspectFit;
        [image setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        [image.heightAnchor constraintEqualToAnchor:image.widthAnchor multiplier:lockup.size.height / lockup.size.width].active = YES;
        title = image;
    } else {
        UILabel *name = [UILabel new];
        name.text = @"Brighter Pocket";
        UIFontDescriptor *bold = [[UIFontDescriptor preferredFontDescriptorWithTextStyle:UIFontTextStyleLargeTitle]
                                  fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold];
        name.font = [UIFont fontWithDescriptor:bold size:0];
        name.adjustsFontSizeToFitWidth = YES;
        name.minimumScaleFactor = 0.5;
        title = name;
    }
    title.isAccessibilityElement = YES;
    title.accessibilityLabel = @"Brighter Pocket";
    title.accessibilityTraits = UIAccessibilityTraitHeader;
    [_stack addArrangedSubview:title];
    [_stack setCustomSpacing:24 afterView:title];

    // What is happening, then the bar and its percentage: layers, which the background queue
    // changes while the game holds the main thread.
    UIFont *stepFont = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    PocketLayerHost *step = _stepHost = [PocketLayerHost new];
    step.height = ceil(stepFont.lineHeight * 2) + 4;
    _step = TextLayer(stepFont);
    [step.layer addSublayer:_step];
    step.isAccessibilityElement = YES;
    [_stack addArrangedSubview:step];
    [_stack setCustomSpacing:4 afterView:step];

    _progress = [UIView new];
    _progress.hidden = YES;
    UIView *track = [UIView new];
    track.translatesAutoresizingMaskIntoConstraints = NO;
    track.backgroundColor = UIColor.tertiarySystemFillColor;
    track.layer.cornerRadius = BarHeight / 2;
    track.clipsToBounds = YES;
    [_progress addSubview:track];
    // The fill sits in a plain layer over the track (trackHost sizes it), never in a view's own
    // layer: its size changes from the background queue then dirty no view's layout, which a
    // commit there would otherwise run off the main thread.
    _fill = [CALayer layer];
    _fill.anchorPoint = CGPointZero;
    _fill.cornerRadius = BarHeight / 2;
    CALayer *fillHost = [CALayer layer];
    [fillHost addSublayer:_fill];
    PocketLayerHost *trackHost = [PocketLayerHost new];
    trackHost.translatesAutoresizingMaskIntoConstraints = NO;
    trackHost.userInteractionEnabled = NO;
    [trackHost.layer addSublayer:fillHost];
    trackHost.laidOut = ^(CGRect bounds) { [weakSelf trackWidthChanged:bounds.size.width]; };
    [_progress addSubview:trackHost];
    UIFont *percentFont = [UIFont monospacedDigitSystemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote].pointSize
                                                          weight:UIFontWeightRegular];
    PocketLayerHost *percent = [PocketLayerHost new];
    percent.translatesAutoresizingMaskIntoConstraints = NO;
    percent.height = ceil(percentFont.lineHeight) + 2;
    _percent = TextLayer(percentFont);
    [percent.layer addSublayer:_percent];
    [_progress addSubview:percent];
    [NSLayoutConstraint activateConstraints:@[
        [track.heightAnchor constraintEqualToConstant:BarHeight],
        [track.topAnchor constraintEqualToAnchor:_progress.topAnchor],
        [track.leadingAnchor constraintEqualToAnchor:_progress.leadingAnchor],
        [track.trailingAnchor constraintEqualToAnchor:_progress.trailingAnchor],
        [trackHost.leadingAnchor constraintEqualToAnchor:track.leadingAnchor],
        [trackHost.trailingAnchor constraintEqualToAnchor:track.trailingAnchor],
        [trackHost.topAnchor constraintEqualToAnchor:track.topAnchor],
        [trackHost.bottomAnchor constraintEqualToAnchor:track.bottomAnchor],
        [percent.topAnchor constraintEqualToAnchor:track.bottomAnchor constant:8],
        [percent.leadingAnchor constraintEqualToAnchor:_progress.leadingAnchor],
        [percent.trailingAnchor constraintEqualToAnchor:_progress.trailingAnchor],
        [percent.bottomAnchor constraintEqualToAnchor:_progress.bottomAnchor],
    ]];
    [_stack addArrangedSubview:_progress];

    // A message: a failure in full, or what the launcher said that has no plain form.
    _message = [UILabel new];
    _message.numberOfLines = 0;
    _message.textAlignment = NSTextAlignmentCenter;
    _message.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _message.textColor = UIColor.secondaryLabelColor;
    _message.hidden = YES;
    [_stack addArrangedSubview:_message];

    // Details: the launcher's own status, its elapsed time and activity, Diagnostics.
    UIButtonConfiguration *plain = [UIButtonConfiguration plainButtonConfiguration];
    plain.imagePlacement = NSDirectionalRectEdgeTrailing;
    plain.imagePadding = 4;
    plain.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleFootnote];
    _detailsButton = [UIButton buttonWithConfiguration:plain primaryAction:nil];
    [_detailsButton addTarget:self action:@selector(toggleDetails) forControlEvents:UIControlEventTouchUpInside];
    [_stack addArrangedSubview:_detailsButton];
    [_stack setCustomSpacing:4 afterView:_detailsButton];

    _status = [PocketStatusLabel new];
    _status.screen = self;
    _status.numberOfLines = 0;
    _status.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    _status.textColor = UIColor.secondaryLabelColor;
    UIStackView *inner = [[UIStackView alloc] initWithArrangedSubviews:[[@[_status] arrayByAddingObjectsFromArray:details]
                                                                          arrayByAddingObject:diagnostics]];
    inner.axis = UILayoutConstraintAxisVertical;
    inner.spacing = 12;
    inner.translatesAutoresizingMaskIntoConstraints = NO;
    inner.layoutMargins = UIEdgeInsetsMake(14, 16, 14, 16);
    inner.layoutMarginsRelativeArrangement = YES;
    _details = [UIView new];
    _details.backgroundColor = UIColor.secondarySystemBackgroundColor;
    _details.layer.cornerRadius = 10;
    _details.layer.cornerCurve = kCACornerCurveContinuous;
    _details.hidden = YES;
    [_details addSubview:inner];
    [_stack addArrangedSubview:_details];
    [self setDetailsTitle];

    // Across the whole width and centred on the screen, not on the safe area: a screen whose
    // camera is at a side (an iPhone in landscape, the iPhone Duo's outer screen upright) has a
    // safe area to one side only, which pushed everything off centre. The content keeps clear
    // of that side all the same, narrowing rather than moving where it must.
    UILayoutGuide *safe = self.safeAreaLayoutGuide;
    NSLayoutConstraint *fitPage = [page.heightAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.heightAnchor];
    fitPage.priority = UILayoutPriorityDefaultLow;
    NSLayoutConstraint *wide = [_stack.widthAnchor constraintEqualToAnchor:page.widthAnchor constant:-48];
    wide.priority = UILayoutPriorityDefaultHigh;
    NSLayoutConstraint *centred = [_stack.centerXAnchor constraintEqualToAnchor:self.centerXAnchor];
    centred.priority = UILayoutPriorityDefaultHigh + 10;
    NSLayoutConstraint *inPage = [_stack.centerXAnchor constraintEqualToAnchor:page.centerXAnchor];
    inPage.priority = UILayoutPriorityDefaultLow;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [page.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [page.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [page.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [page.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [page.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
        [page.heightAnchor constraintGreaterThanOrEqualToAnchor:scroll.frameLayoutGuide.heightAnchor], fitPage,
        centred, inPage,
        [_stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:16],
        [_stack.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-16],
        [_stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:page.leadingAnchor constant:24],
        [_stack.trailingAnchor constraintLessThanOrEqualToAnchor:page.trailingAnchor constant:-24],
        [_stack.centerYAnchor constraintEqualToAnchor:page.centerYAnchor],
        [_stack.topAnchor constraintGreaterThanOrEqualToAnchor:page.topAnchor constant:24],
        [_stack.bottomAnchor constraintLessThanOrEqualToAnchor:page.bottomAnchor constant:-24],
        [_stack.widthAnchor constraintLessThanOrEqualToConstant:560], wide,
        [title.widthAnchor constraintLessThanOrEqualToAnchor:_stack.widthAnchor],
        [step.widthAnchor constraintEqualToAnchor:_stack.widthAnchor],
        [_progress.widthAnchor constraintEqualToAnchor:_stack.widthAnchor],
        [_message.widthAnchor constraintEqualToAnchor:_stack.widthAnchor],
        [_details.widthAnchor constraintEqualToAnchor:_stack.widthAnchor],
        [inner.leadingAnchor constraintEqualToAnchor:_details.leadingAnchor],
        [inner.trailingAnchor constraintEqualToAnchor:_details.trailingAnchor],
        [inner.topAnchor constraintEqualToAnchor:_details.topAnchor],
        [inner.bottomAnchor constraintEqualToAnchor:_details.bottomAnchor],
    ]];
    [self coloursChanged];
    [self setStep:@"Getting ready…" problem:NO];
    return self;
}

// The layers' colours, resolved for the light or dark appearance (a layer takes no dynamic colour).
- (void)coloursChanged {
    _traits = self.traitCollection;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fill.backgroundColor = [self.tintColor resolvedColorWithTraitCollection:_traits].CGColor;
    _percent.foregroundColor = [UIColor.secondaryLabelColor resolvedColorWithTraitCollection:_traits].CGColor;
    _step.foregroundColor = [(_problem ? UIColor.systemRedColor : UIColor.labelColor) resolvedColorWithTraitCollection:_traits].CGColor;
    [CATransaction commit];
}
- (void)tintColorDidChange {
    [super tintColorDidChange];
    [self coloursChanged];
}

- (UILabel *)status { return _status; }

// Any thread: the step's words (a problem in red), the bar and its percentage, committed and
// flushed at once.
- (void)setStep:(NSString *)text problem:(BOOL)problem {
    _problem = problem;
    UIColor *color = [(problem ? UIColor.systemRedColor : UIColor.labelColor) resolvedColorWithTraitCollection:_traits];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _step.string = text;
    _step.foregroundColor = color.CGColor;
    [CATransaction commit];
    if (NSThread.isMainThread) _stepHost.accessibilityLabel = text;
    else [CATransaction flush];
}
- (void)showFraction:(double)fraction {
    atomic_store(&_fraction, fraction);
    // No animation: one added from here may not run while the main thread is held; four steps a
    // second move the bar smoothly enough.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fill.bounds = CGRectMake(0, 0, atomic_load(&_trackWidth) * MAX(0, MIN(1, fraction)), BarHeight);
    _percent.string = [NSString stringWithFormat:@"%d%%", (int)floor(fraction * 100)];
    [CATransaction commit];
    if (!NSThread.isMainThread) [CATransaction flush];
}
- (void)trackWidthChanged:(CGFloat)width {
    atomic_store(&_trackWidth, width);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fill.bounds = CGRectMake(0, 0, width * MAX(0, MIN(1, atomic_load(&_fraction))), BarHeight);
    [CATransaction commit];
}

- (void)setDetailsTitle {
    UIButtonConfiguration *configuration = _detailsButton.configuration;
    configuration.title = _details.hidden ? (_stopped ? @"Details and Logs" : @"Details") : @"Hide Details";
    configuration.image = [UIImage systemImageNamed:_details.hidden ? @"chevron.down" : @"chevron.up"];
    _detailsButton.configuration = configuration;
}
- (void)toggleDetails {
    _details.hidden = !_details.hidden;
    [self setDetailsTitle];
}

- (void)statusChanged:(NSString *)text {
    if (_stopped) { [self showStopped]; return; }
    if (_watching || !text.length) return;
    NSString *plain = PlainStep(text);
    if (plain) [self setStep:plain problem:NO];
    _message.text = plain ? nil : text;
    _message.hidden = plain != nil;
}

// A step before the game's own start (an update): its words, and its bar when it has one.
- (void)launchProgress:(NSNotification *)notification {
    if (_watching || _stopped) return;
    NSString *text = notification.userInfo[@"text"];
    NSNumber *fraction = notification.userInfo[@"fraction"];
    if (text) [self setStep:text problem:NO];
    _message.hidden = YES;
    _progress.hidden = fraction == nil;
    if (fraction) [self showFraction:fraction.doubleValue];
}

- (void)watchLog:(NSString *)path {
    if (_watching || _stopped) return;
    _watching = YES;
    _message.hidden = YES;
    _progress.hidden = NO;
    [self setStep:@"Loading the game…" problem:NO];
    [self showFraction:0];
    // The game holds the main thread from here: lay out and commit now.
    [self layoutIfNeeded];
    [CATransaction flush];
    NSInteger kept = [NSUserDefaults.standardUserDefaults integerForKey:LogLinesKey];
    double expected = kept >= 20 ? kept : DefaultLogLines;   // the iOS Simulator's start logs far fewer lines
    __weak PocketLoadingView *weakSelf = self;
    __block NSFileHandle *log = nil;
    __block NSMutableData *partial = [NSMutableData data];
    __block NSInteger lines = 0;
    size_t markerLength = strlen(WindowMarker);
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    // The first look a moment from now, once the launcher has gone on into the game.
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), NSEC_PER_SEC / 4, NSEC_PER_SEC / 20);
    dispatch_source_set_event_handler(_timer, ^{ @autoreleasepool {
        PocketLoadingView *view = weakSelf;
        if (!view) return;
        log = log ?: [NSFileHandle fileHandleForReadingAtPath:path];
        NSData *chunk = [log readDataToEndOfFileAndReturnError:NULL];
        if (!chunk.length) return;
        [partial appendData:chunk];
        const char *bytes = partial.bytes, *end = bytes + partial.length, *line = bytes;
        BOOL up = NO;
        for (const char *newline; !up && (newline = memchr(line, '\n', (size_t)(end - line))); line = newline + 1) {
            lines++;
            up = memmem(line, (size_t)(newline - line), WindowMarker, markerLength) != NULL;
        }
        [partial replaceBytesInRange:NSMakeRange(0, (NSUInteger)(line - bytes)) withBytes:NULL length:0];
        if (up) {
            [NSUserDefaults.standardUserDefaults setInteger:lines forKey:LogLinesKey];
            [view showFraction:1];
            [view setStep:@"Brighter Shores is ready." problem:NO];
            [view stopWatching];
            return;
        }
        [view showFraction:MIN(ProgressCap, lines / expected)];
    }});
    dispatch_resume(_timer);
}
- (void)stopWatching {
    dispatch_source_t timer;
    @synchronized (self) {
        timer = _timer;
        _timer = nil;
    }
    if (timer) dispatch_source_cancel(timer);
}

- (void)showStopped {
    _stopped = YES;
    [self stopWatching];
    NSString *text = _status.text ?: @"";
    _progress.hidden = YES;
    if ([text hasSuffix:@" closed."]) {
        [self setStep:@"Brighter Shores closed." problem:NO];
        _message.hidden = YES;
    } else {
        [self setStep:@"Brighter Shores couldn't start" problem:YES];
        _message.text = PlainFailure(text);
        _message.hidden = !_message.text.length;
    }
    [self setDetailsTitle];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (_timer) dispatch_source_cancel(_timer);
}
@end
