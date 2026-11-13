// What the Brighter Shores client asks of AppKit and QuartzCore beyond Tolkara's
// AppKit adapter (docs/client-analysis.md, "The application's shape"):
//
// - NSPasteboard (copy and paste in the game's text fields) on UIPasteboard;
// - NSWorkspace -openURL: (links the game opens in a browser) on UIApplication,
//   web and mail links only;
// - the named NSCursor class methods and +[NSBitmapImageRep imageRepWithData:],
//   which the client uses to build its own pointer images;
// - -[CAMetalLayer setDisplaySyncEnabled:], which macOS has and iOS does not: the
//   setting is kept and reported back, and has no effect (an iOS layer always
//   presents in step with the display);
// - in the iOS Simulator only, -[CAMetalDrawable addPresentedHandler:] and
//   -presentedTime, which the simulator's drawable lacks (its SDK marks them
//   unavailable) and the client asks of every drawable.
//
// Methods are added to existing classes only where the class lacks them, at load,
// so a later Tolkara that implements one keeps its own. The two classes are new
// here; if Tolkara adds either, the duplicate class fails the link loudly.
#import "AppKit.h"
#import "Images.h"
#import <objc/runtime.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

@interface NSPasteboard : AKStubObject
+ (NSPasteboard *)generalPasteboard;
- (NSInteger)clearContents;
- (BOOL)writeObjects:(NSArray *)objects;
- (NSArray *)readObjectsForClasses:(NSArray<Class> *)classes options:(NSDictionary *)options;
@end

@implementation NSPasteboard {
    NSInteger _changes;
}
+ (NSPasteboard *)generalPasteboard {
    static NSPasteboard *general;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ general = [NSPasteboard new]; });
    return general;
}
- (NSInteger)clearContents {
    UIPasteboard.generalPasteboard.items = @[];
    return ++_changes;
}
// Text only: the client writes and reads strings.
- (BOOL)writeObjects:(NSArray *)objects {
    NSMutableArray<NSString *> *strings = [NSMutableArray array];
    for (id object in objects)
        if ([object isKindOfClass:NSString.class]) [strings addObject:object];
    if (!strings.count) return NO;
    UIPasteboard.generalPasteboard.strings = strings;
    _changes++;
    return YES;
}
- (NSArray *)readObjectsForClasses:(NSArray<Class> *)classes options:(NSDictionary *)options {
    (void)options;
    BOOL wantsText = NO;
    for (Class cls in classes) wantsText |= [NSString.class isSubclassOfClass:cls] || [cls isSubclassOfClass:NSString.class];
    if (!wantsText) return @[];
    // Reading asks the person for permission the first time, as any iOS paste does.
    NSString *text = UIPasteboard.generalPasteboard.string;
    return text ? @[text] : @[];
}
@end

@interface NSWorkspace : AKStubObject
+ (NSWorkspace *)sharedWorkspace;
- (BOOL)openURL:(NSURL *)url;
@end

@implementation NSWorkspace
+ (NSWorkspace *)sharedWorkspace {
    static NSWorkspace *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [NSWorkspace new]; });
    return shared;
}
- (BOOL)openURL:(NSURL *)url {
    NSString *scheme = url.scheme.lowercaseString;
    if (![@[@"http", @"https", @"mailto"] containsObject:scheme ?: @""]) {
        AKLog(@"NSWorkspace openURL %@ refused: only web and mail links open", url.scheme);
        return NO;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    });
    return YES;
}
@end

// --- methods added where missing ------------------------------------------------------
// The named cursors as the game sets them (a pointing hand over what it can click, an I-beam
// over text): drawn from SF Symbols, white with a dark edge as on a Mac, each with its hot spot.
// The touch cursor (cursor input) and a connected mouse's pointer both take the current cursor.
static NSCursor *symbolCursor(NSString *symbol, CGPoint hotSpot) {
    const CGFloat side = 26;
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightSemibold];
    UIImage *glyph = [UIImage systemImageNamed:symbol withConfiguration:configuration];
    if (!glyph) return NSCursor.arrowCursor;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    UIImage *drawn = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        (void)context;
        CGRect box = CGRectMake((side - glyph.size.width) / 2, (side - glyph.size.height) / 2, glyph.size.width, glyph.size.height);
        UIImage *edge = [glyph imageWithTintColor:UIColor.blackColor renderingMode:UIImageRenderingModeAlwaysOriginal];
        for (int dx = -1; dx <= 1; dx++)
            for (int dy = -1; dy <= 1; dy++) [edge drawInRect:CGRectOffset(box, dx * 1.2, dy * 1.2)];
        [[glyph imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal] drawInRect:box];
    }];
    NSImage *image = [[NSImage alloc] initWithCGImage:drawn.CGImage size:CGSizeMake(side, side)];
    return [[NSCursor alloc] initWithImage:image hotSpot:hotSpot];
}
static NSCursor *namedCursor(id self, SEL _cmd) {
    (void)self;
    static NSMutableDictionary<NSString *, NSCursor *> *cursors;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cursors = [NSMutableDictionary dictionary]; });
    NSString *name = NSStringFromSelector(_cmd);
    @synchronized (cursors) {
        NSCursor *cursor = cursors[name];
        if (cursor) return cursor;
        if ([name isEqualToString:@"pointingHandCursor"]) cursor = symbolCursor(@"hand.point.up.left.fill", CGPointMake(9, 3));
        else if ([name isEqualToString:@"IBeamCursor"]) cursor = symbolCursor(@"character.cursor.ibeam", CGPointMake(13, 13));
        else if ([name isEqualToString:@"crosshairCursor"]) cursor = symbolCursor(@"plus", CGPointMake(13, 13));
        else if ([name isEqualToString:@"operationNotAllowedCursor"]) cursor = symbolCursor(@"nosign", CGPointMake(13, 13));
        else cursor = NSCursor.arrowCursor;
        cursors[name] = cursor;
        return cursor;
    }
}

static id imageRepWithData(id self, SEL _cmd, NSData *data) {
    (void)self; (void)_cmd;
    UIImage *image = data ? [UIImage imageWithData:data] : nil;
    return image.CGImage ? [[NSBitmapImageRep alloc] initWithCGImage:image.CGImage] : nil;
}

static const void *displaySyncKey = &displaySyncKey;
static void setDisplaySyncEnabled(id self, SEL _cmd, BOOL enabled) {
    (void)_cmd;
    objc_setAssociatedObject(self, displaySyncKey, @(enabled), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static BOOL displaySyncEnabled(id self, SEL _cmd) {
    (void)_cmd;
    NSNumber *value = objc_getAssociatedObject(self, displaySyncKey);
    return value ? value.boolValue : YES;
}

static void addIfMissing(Class cls, SEL selector, IMP implementation, const char *types) {
    if (class_addMethod(cls, selector, implementation, types))
        AKLog(@"added %c[%s %s]", class_isMetaClass(cls) ? '+' : '-', class_getName(cls), sel_getName(selector));
}

#if TARGET_OS_SIMULATOR
// --- presentation in the simulator ------------------------------------------------------
// A drawable presented with -present, -presentAtTime: or -presentAfterMinimumDuration:
// (which a command buffer's presentDrawable: also ends in) takes that moment, a display
// frame (1/60 s) later, as its presentedTime and runs its handlers then, once; a drawable
// never presented runs none. A drawable that already has the methods (a device's) is
// left alone.
typedef void (^PresentedHandler)(id drawable);
static const void *handlersKey = &handlersKey, *presentedKey = &presentedKey;
static void (*systemPresent)(id, SEL);
static void (*systemPresentAtTime)(id, SEL, CFTimeInterval);
static void (*systemPresentAfter)(id, SEL, CFTimeInterval);

static void addPresentedHandler(id self, SEL _cmd, PresentedHandler handler) {
    (void)_cmd;
    if (!handler) return;
    @synchronized (self) {
        NSMutableArray *handlers = objc_getAssociatedObject(self, handlersKey);
        if (!handlers) {
            handlers = [NSMutableArray array];
            objc_setAssociatedObject(self, handlersKey, handlers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [handlers addObject:[handler copy]];
    }
}
static CFTimeInterval presentedTime(id self, SEL _cmd) {
    (void)_cmd;
    @synchronized (self) {
        return [objc_getAssociatedObject(self, presentedKey) doubleValue];
    }
}
static void presented(id drawable) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 60), dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        NSArray *handlers;
        @synchronized (drawable) {
            if (objc_getAssociatedObject(drawable, presentedKey)) return;   // presented once only
            objc_setAssociatedObject(drawable, presentedKey, @(CACurrentMediaTime()), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            handlers = [objc_getAssociatedObject(drawable, handlersKey) copy];
            objc_setAssociatedObject(drawable, handlersKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        for (PresentedHandler handler in handlers) handler(drawable);
    });
}
static void present(id self, SEL _cmd) {
    systemPresent(self, _cmd);
    presented(self);
}
static void presentAtTime(id self, SEL _cmd, CFTimeInterval time) {
    systemPresentAtTime(self, _cmd, time);
    presented(self);
}
static void presentAfter(id self, SEL _cmd, CFTimeInterval duration) {
    systemPresentAfter(self, _cmd, duration);
    presented(self);
}
static void *replaceMethod(Class cls, SEL selector, IMP implementation) {
    Method method = class_getInstanceMethod(cls, selector);
    return method ? (void *)method_setImplementation(method, implementation) : NULL;
}

// The simulator's command buffer lacks -presentDrawable:afterMinimumDuration: (its SDK marks
// it unavailable). It presents as -presentDrawable: does: when the command buffer is
// scheduled, the drawable is presented with the next display frame, which an iOS layer keeps
// to anyway. Either way the drawable counts as presented once the command buffer is scheduled.
static void (*systemPresentDrawable)(id, SEL, id);
static void presentDrawable(id self, SEL _cmd, id drawable) {
    if (drawable) [self addScheduledHandler:^(__unused id buffer) { presented(drawable); }];
    systemPresentDrawable(self, _cmd, drawable);
}
static void presentDrawableAfter(id self, SEL _cmd, id drawable, CFTimeInterval duration) {
    (void)_cmd; (void)duration;
    presentDrawable(self, @selector(presentDrawable:), drawable);
}

// The command buffer's class (MTLSimCommandBuffer) exists once the simulator's Metal driver has
// made a device. Asking for one in this library's constructor can deadlock (the constructor runs
// under dyld's lock, which the driver needs), so the class is learnt from the game's own layer,
// at its first -nextDrawable, before anything is presented.
static void installSimulatorCommandBuffer(id<MTLDevice> device) {
    Class command = [[[device newCommandQueue] commandBuffer] class];
    if (!command) {
        AKLog(@"simulator: no Metal command buffer; -presentDrawable:afterMinimumDuration: is not added");
    } else if (!class_getInstanceMethod(command, @selector(presentDrawable:afterMinimumDuration:))) {
        systemPresentDrawable = (void (*)(id, SEL, id))replaceMethod(command, @selector(presentDrawable:), (IMP)presentDrawable);
        if (systemPresentDrawable)
            addIfMissing(command, @selector(presentDrawable:afterMinimumDuration:), (IMP)presentDrawableAfter, "v@:@d");
        else
            AKLog(@"simulator: %s has no -presentDrawable:; -presentDrawable:afterMinimumDuration: is not added", class_getName(command));
    }
}
static id (*systemNextDrawable)(id, SEL);
static id nextDrawable(CAMetalLayer *self, SEL _cmd) {
    static dispatch_once_t once;
    id<MTLDevice> device = self.device;
    if (device) dispatch_once(&once, ^{ installSimulatorCommandBuffer(device); });
    return systemNextDrawable(self, _cmd);
}
static void installSimulatorPresentation(void) {
    Class drawable = NSClassFromString(@"CAMetalDrawable");
    if (drawable && !class_getInstanceMethod(drawable, @selector(addPresentedHandler:))) {
        systemPresent = (void (*)(id, SEL))replaceMethod(drawable, @selector(present), (IMP)present);
        systemPresentAtTime = (void (*)(id, SEL, CFTimeInterval))replaceMethod(drawable, @selector(presentAtTime:), (IMP)presentAtTime);
        systemPresentAfter = (void (*)(id, SEL, CFTimeInterval))replaceMethod(drawable, @selector(presentAfterMinimumDuration:), (IMP)presentAfter);
        addIfMissing(drawable, @selector(addPresentedHandler:), (IMP)addPresentedHandler, "v@:@?");
        addIfMissing(drawable, @selector(presentedTime), (IMP)presentedTime, "d@:");
    }
    systemNextDrawable = (id (*)(id, SEL))replaceMethod(CAMetalLayer.class, @selector(nextDrawable), (IMP)nextDrawable);
}
#endif

__attribute__((constructor)) static void PocketCompatInstall(void) {
    Class cursorMeta = object_getClass(NSCursor.class);
    for (NSString *name in @[@"IBeamCursor", @"crosshairCursor", @"pointingHandCursor", @"operationNotAllowedCursor"])
        addIfMissing(cursorMeta, NSSelectorFromString(name), (IMP)namedCursor, "@@:");
    addIfMissing(object_getClass(NSBitmapImageRep.class), @selector(imageRepWithData:), (IMP)imageRepWithData, "@@:@");
    addIfMissing(CAMetalLayer.class, NSSelectorFromString(@"setDisplaySyncEnabled:"), (IMP)setDisplaySyncEnabled, "v@:B");
    addIfMissing(CAMetalLayer.class, NSSelectorFromString(@"displaySyncEnabled"), (IMP)displaySyncEnabled, "B@:");
#if TARGET_OS_SIMULATOR
    installSimulatorPresentation();
#endif
}
