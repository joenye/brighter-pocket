// What the Brighter Shores client asks of AppKit and QuartzCore beyond Tolkara's
// AppKit adapter (docs/client-analysis.md, "AppKit"):
//
// - NSPasteboard (copy and paste in the game's text fields) on UIPasteboard;
// - NSWorkspace -openURL: (links the game opens in a browser) on UIApplication,
//   web and mail links only;
// - the named NSCursor class methods and +[NSBitmapImageRep imageRepWithData:],
//   which the client uses to build its own pointer images;
// - -[CAMetalLayer setDisplaySyncEnabled:], which macOS has and iOS does not: the
//   setting is kept and reported back, and has no effect (an iOS layer always
//   presents in step with the display).
//
// Methods are added to existing classes only where the class lacks them, at load,
// so a later Tolkara that implements one keeps its own. The two classes are new
// here; if Tolkara adds either, the duplicate class fails the link loudly.
#import "AppKit.h"
#import "Images.h"
#import <objc/runtime.h>

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
static NSCursor *namedCursor(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return NSCursor.arrowCursor;   // the system pointer: iPadOS has no other shapes to offer
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

__attribute__((constructor)) static void PocketCompatInstall(void) {
    Class cursorMeta = object_getClass(NSCursor.class);
    for (NSString *name in @[@"IBeamCursor", @"crosshairCursor", @"pointingHandCursor", @"operationNotAllowedCursor"])
        addIfMissing(cursorMeta, NSSelectorFromString(name), (IMP)namedCursor, "@@:");
    addIfMissing(object_getClass(NSBitmapImageRep.class), @selector(imageRepWithData:), (IMP)imageRepWithData, "@@:@");
    addIfMissing(CAMetalLayer.class, NSSelectorFromString(@"setDisplaySyncEnabled:"), (IMP)setDisplaySyncEnabled, "v@:B");
    addIfMissing(CAMetalLayer.class, NSSelectorFromString(@"displaySyncEnabled"), (IMP)displaySyncEnabled, "B@:");
}
