//
//  CrosswireShellUI.m
//  Crosswire shell integration — AppKit stage.
//
//  This file is part of Crosswire.
//
//  Crosswire is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Loaded by CrosswireShell.dylib inside engine processes that start a Cocoa
//  application (i.e. show Windows windows). Responsibilities:
//
//  1. Dock icons. winemac.drv hands the raw Windows icon to
//     -[NSApplication setApplicationIconImage:], which the Dock draws edge to
//     edge as a hard square. Every image is re-rendered onto the macOS icon
//     grid (824pt rounded "squircle" body on a 1024pt canvas, drop shadow).
//     Full-bleed artwork is clipped to the shape; artwork with transparency is
//     placed on a light tile. Processes with no icon at all (console windows,
//     helpers) get a real icon instead of the generic "exec" document.
//
//  2. App name. The engine process otherwise shows up as "wine" in Cmd-Tab,
//     Force Quit and Activity Monitor. CROSSWIRE_APP_NAME (scoped to
//     CROSSWIRE_APP_EXE) names it. (The Dock tile label of an unbundled
//     process is its executable file name and cannot be changed this way.)
//
//  3. Own Space for games. With CROSSWIRE_OWN_SPACE=1 the game's main window
//     enters native macOS full screen, which gives it its own Space next to
//     the current desktop: three/four-finger swipe or Ctrl-arrow switches
//     between the game and the desktop. If the user leaves full screen, the
//     choice is respected for the rest of the session.
//

#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <crt_externs.h>
#include <math.h>
#include <stdlib.h>

#pragma mark - Logging

#include <dlfcn.h>
typedef void (*CWLogFn)(NSString *format, ...);
#define CWLog(...) do { \
    static CWLogFn fn; static dispatch_once_t once; \
    dispatch_once(&once, ^{ fn = (CWLogFn)dlsym(RTLD_DEFAULT, "CWShellLog"); }); \
    if (fn) fn(__VA_ARGS__); \
} while (0)

#pragma mark - Process identity

static NSString *CWEnv(const char *key)
{
    const char *value = getenv(key);
    if (!value || !value[0]) return nil;
    return [NSString stringWithUTF8String:value];
}

/// The Windows executable file name of this process, lowercased
/// ("among us.exe", "conhost.exe"). Wine rewrites argv[0] to the Windows path.
static NSString *CWProcessExeName(void)
{
    static NSString *name;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        char **argv = *_NSGetArgv();
        NSString *raw = (argv && argv[0]) ? [NSString stringWithUTF8String:argv[0]] : nil;
        if (!raw.length) raw = [NSString stringWithUTF8String:getprogname()];
        NSRange slash = [raw rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\\/"]
                                             options:NSBackwardsSearch];
        if (slash.location != NSNotFound) raw = [raw substringFromIndex:slash.location + 1];
        name = raw.lowercaseString ?: @"";
    });
    return name;
}

static BOOL CWIsConsoleHost(void)
{
    NSString *exe = CWProcessExeName();
    return [exe isEqualToString:@"conhost.exe"] || [exe isEqualToString:@"wineconsole.exe"];
}

static BOOL CWIsShellHelper(void)
{
    NSString *exe = CWProcessExeName();
    return CWIsConsoleHost() || [exe isEqualToString:@"explorer.exe"] || [exe isEqualToString:@"start.exe"]
        || [exe isEqualToString:@"cmd.exe"] || [exe hasPrefix:@"unitycrashhandler"];
}

/// Name for the Dock tooltip, Cmd-Tab and menu bar.
static NSString *CWDisplayName(void)
{
    NSString *appName = CWEnv("CROSSWIRE_APP_NAME");
    NSString *appExe = CWEnv("CROSSWIRE_APP_EXE").lowercaseString;
    NSString *exe = CWProcessExeName();

    if (CWIsConsoleHost())
        return appName ? [appName stringByAppendingString:@" Console"] : @"Console";
    if (appName && (!appExe || [appExe isEqualToString:exe]))
        return appName;
    if ([exe hasSuffix:@".exe"]) exe = [exe substringToIndex:exe.length - 4];
    if (!exe.length) return appName;

    // Prefer the on-disk casing from argv when available.
    char **argv = *_NSGetArgv();
    if (argv && argv[0]) {
        NSString *raw = [NSString stringWithUTF8String:argv[0]].lastPathComponent;
        NSRange slash = [raw rangeOfString:@"\\" options:NSBackwardsSearch];
        if (slash.location != NSNotFound) raw = [raw substringFromIndex:slash.location + 1];
        if ([raw.lowercaseString hasSuffix:@".exe"]) raw = [raw substringToIndex:raw.length - 4];
        if ([raw.lowercaseString isEqualToString:exe]) return raw;
    }
    return exe;
}

/// LaunchServices display name for this process (what the Dock and Cmd-Tab
/// show). Uses the same private LaunchServices entry points Chromium uses for
/// its helper processes; resolved dynamically so a missing symbol is a no-op.
static void CWApplyDisplayName(void)
{
    static BOOL applied = NO;
    if (applied) return;
    applied = YES;

    NSString *name = CWDisplayName();
    if (!name.length) return;

    CFBundleRef ls = CFBundleGetBundleWithIdentifier(CFSTR("com.apple.LaunchServices"));
    if (!ls) return;
    typedef CFTypeRef (*GetASN)(void);
    typedef OSStatus (*SetItem)(int, CFTypeRef, CFStringRef, CFStringRef, CFDictionaryRef *);
    GetASN getASN = (GetASN)CFBundleGetFunctionPointerForName(ls, CFSTR("_LSGetCurrentApplicationASN"));
    SetItem setItem = (SetItem)CFBundleGetFunctionPointerForName(ls, CFSTR("_LSSetApplicationInformationItem"));
    CFStringRef *key = (CFStringRef *)CFBundleGetDataPointerForName(ls, CFSTR("_kLSDisplayNameKey"));
    if (!getASN || !setItem || !key || !*key) {
        CWLog(@"display name: LaunchServices SPI unavailable (%p %p %p)", getASN, setItem, key);
        return;
    }
    CFTypeRef asn = getASN();
    if (!asn) { CWLog(@"display name: no ASN yet"); applied = NO; return; }
    OSStatus status = setItem(-2 /* kLSDefaultSessionID */, asn, *key, (__bridge CFStringRef)name, NULL);
    CWLog(@"display name '%@' -> %d", name, (int)status);
}

#pragma mark - Icon rendering

static const CGFloat kCanvas = 1024.0;
static const CGFloat kBodyInset = 100.0;    // 824pt body, Apple icon grid
static char kStyledKey;

/// Continuous-curvature rounded square (superellipse, n = 5), the shape macOS
/// uses for app icons. NSBezierPath's rounded rect has circular corners, which
/// reads as "not quite right" next to native icons.
static NSBezierPath *CWSquircle(NSRect rect)
{
    const CGFloat n = 5.0;
    const int steps = 360;
    NSBezierPath *path = [NSBezierPath bezierPath];
    CGFloat cx = NSMidX(rect), cy = NSMidY(rect);
    CGFloat a = NSWidth(rect) / 2.0, b = NSHeight(rect) / 2.0;
    for (int i = 0; i <= steps; i++) {
        CGFloat t = (CGFloat)i / steps * 2.0 * M_PI;
        CGFloat ct = cos(t), st = sin(t);
        CGFloat x = cx + a * copysign(pow(fabs(ct), 2.0 / n), ct);
        CGFloat y = cy + b * copysign(pow(fabs(st), 2.0 / n), st);
        if (i == 0) [path moveToPoint:NSMakePoint(x, y)];
        else [path lineToPoint:NSMakePoint(x, y)];
    }
    [path closePath];
    return path;
}

/// Largest bitmap representation of `image`, rasterising if needed.
static NSBitmapImageRep *CWBestBitmap(NSImage *image)
{
    NSBitmapImageRep *best = nil;
    for (NSImageRep *rep in image.representations) {
        if (![rep isKindOfClass:[NSBitmapImageRep class]]) continue;
        if (!best || rep.pixelsWide * rep.pixelsHigh > best.pixelsWide * best.pixelsHigh)
            best = (NSBitmapImageRep *)rep;
    }
    if (best) return best;

    CGImageRef cg = [image CGImageForProposedRect:NULL context:nil hints:nil];
    return cg ? [[NSBitmapImageRep alloc] initWithCGImage:cg] : nil;
}

static CGFloat CWAlphaAt(NSBitmapImageRep *rep, NSInteger x, NSInteger y)
{
    NSColor *c = [rep colorAtX:x y:y];
    return c ? c.alphaComponent : 0.0;
}

/// True when the artwork fills its square (game box art, photos, most
/// modern Windows icons). Samples the middle half of each edge so artwork
/// that already has rounded corners still counts as full-bleed.
static BOOL CWIsFullBleed(NSBitmapImageRep *rep)
{
    NSInteger w = rep.pixelsWide, h = rep.pixelsHigh;
    if (w < 4 || h < 4) return NO;
    NSInteger opaque = 0, total = 0;
    for (int i = 0; i < 16; i++) {
        CGFloat f = 0.25 + 0.5 * i / 15.0;
        NSInteger x = (NSInteger)(f * (w - 1)), y = (NSInteger)(f * (h - 1));
        NSInteger samples[4][2] = { {x, 0}, {x, h - 1}, {0, y}, {w - 1, y} };
        for (int s = 0; s < 4; s++) {
            total++;
            if (CWAlphaAt(rep, samples[s][0], samples[s][1]) > 0.9) opaque++;
        }
    }
    return opaque >= total * 0.85;
}

/// Bounding box (in unit coordinates, origin bottom-left) of pixels that are
/// not transparent, so padded artwork is not shrunk twice.
static NSRect CWOpaqueBounds(NSBitmapImageRep *rep)
{
    NSInteger w = rep.pixelsWide, h = rep.pixelsHigh;
    NSInteger step = MAX(1, MIN(w, h) / 64);
    NSInteger minX = w, minY = h, maxX = -1, maxY = -1;
    for (NSInteger y = 0; y < h; y += step) {
        for (NSInteger x = 0; x < w; x += step) {
            if (CWAlphaAt(rep, x, y) > 0.08) {
                minX = MIN(minX, x); maxX = MAX(maxX, x);
                minY = MIN(minY, y); maxY = MAX(maxY, y);
            }
        }
    }
    if (maxX < 0) return NSMakeRect(0, 0, 1, 1);
    // colorAtX:y: uses a top-left origin; flip to bottom-left.
    CGFloat x0 = (CGFloat)minX / w, x1 = (CGFloat)MIN(w, maxX + step) / w;
    CGFloat yTop = (CGFloat)minY / h, yBottom = (CGFloat)MIN(h, maxY + step) / h;
    return NSMakeRect(x0, 1.0 - yBottom, x1 - x0, yBottom - yTop);
}

static NSImage *CWMarkStyled(NSImage *image)
{
    objc_setAssociatedObject(image, &kStyledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return image;
}

static void CWDrawBodyShadowed(NSBezierPath *body, void (^fill)(void))
{
    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.30];
    shadow.shadowOffset = NSMakeSize(0, -10);
    shadow.shadowBlurRadius = 22;
    [shadow set];
    [[NSColor blackColor] setFill];
    [body fill];
    [NSGraphicsContext restoreGraphicsState];
    [NSGraphicsContext saveGraphicsState];
    [body addClip];
    fill();
    [NSGraphicsContext restoreGraphicsState];
}

static void CWDrawBodyEdge(NSBezierPath *body)
{
    [NSGraphicsContext saveGraphicsState];
    [body addClip];
    body.lineWidth = 4;
    [[NSColor colorWithWhite:1 alpha:0.18] setStroke];
    [body stroke];
    [NSGraphicsContext restoreGraphicsState];
}

static NSImage *CWStyledIcon(NSImage *source)
{
    if (!source || objc_getAssociatedObject(source, &kStyledKey)) return source;
    NSBitmapImageRep *rep = CWBestBitmap(source);
    if (!rep) return source;

    BOOL fullBleed = CWIsFullBleed(rep);
    NSRect opaque = fullBleed ? NSMakeRect(0, 0, 1, 1) : CWOpaqueBounds(rep);
    NSImage *art = [[NSImage alloc] initWithSize:NSMakeSize(rep.pixelsWide, rep.pixelsHigh)];
    [art addRepresentation:rep];

    NSImage *styled = [NSImage imageWithSize:NSMakeSize(kCanvas, kCanvas) flipped:NO drawingHandler:^BOOL(NSRect dst) {
        CGFloat scale = NSWidth(dst) / kCanvas;
        NSRect bodyRect = NSInsetRect(dst, kBodyInset * scale, kBodyInset * scale);
        NSBezierPath *body = CWSquircle(bodyRect);
        [NSGraphicsContext currentContext].imageInterpolation = NSImageInterpolationHigh;

        if (fullBleed) {
            CWDrawBodyShadowed(body, ^{
                [art drawInRect:bodyRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
                       fraction:1.0 respectFlipped:YES hints:nil];
            });
        } else {
            CWDrawBodyShadowed(body, ^{
                NSGradient *tile = [[NSGradient alloc]
                    initWithStartingColor:[NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:1]
                              endingColor:[NSColor colorWithSRGBRed:0.90 green:0.90 blue:0.92 alpha:1]];
                [tile drawInRect:bodyRect angle:-90];

                // Fit the visible part of the artwork into ~72% of the body.
                NSSize pixels = NSMakeSize(rep.pixelsWide, rep.pixelsHigh);
                NSRect from = NSMakeRect(opaque.origin.x * pixels.width, opaque.origin.y * pixels.height,
                                         opaque.size.width * pixels.width, opaque.size.height * pixels.height);
                CGFloat box = NSWidth(bodyRect) * 0.72;
                CGFloat fit = box / MAX(NSWidth(from), NSHeight(from));
                NSSize size = NSMakeSize(NSWidth(from) * fit, NSHeight(from) * fit);
                NSRect to = NSMakeRect(NSMidX(bodyRect) - size.width / 2, NSMidY(bodyRect) - size.height / 2,
                                       size.width, size.height);

                [NSGraphicsContext saveGraphicsState];
                NSShadow *glyph = [[NSShadow alloc] init];
                glyph.shadowColor = [NSColor colorWithWhite:0 alpha:0.22];
                glyph.shadowOffset = NSMakeSize(0, -6 * scale);
                glyph.shadowBlurRadius = 14 * scale;
                [glyph set];
                [art drawInRect:to fromRect:from operation:NSCompositingOperationSourceOver
                       fraction:1.0 respectFlipped:YES hints:nil];
                [NSGraphicsContext restoreGraphicsState];
            });
        }
        CWDrawBodyEdge(body);
        return YES;
    }];
    return CWMarkStyled(styled);
}

/// Icon for console windows: a dark tile with a prompt, like Terminal.
static NSImage *CWConsoleIcon(void)
{
    NSImage *icon = [NSImage imageWithSize:NSMakeSize(kCanvas, kCanvas) flipped:NO drawingHandler:^BOOL(NSRect dst) {
        CGFloat scale = NSWidth(dst) / kCanvas;
        NSRect bodyRect = NSInsetRect(dst, kBodyInset * scale, kBodyInset * scale);
        NSBezierPath *body = CWSquircle(bodyRect);
        CWDrawBodyShadowed(body, ^{
            NSGradient *tile = [[NSGradient alloc]
                initWithStartingColor:[NSColor colorWithSRGBRed:0.20 green:0.21 blue:0.23 alpha:1]
                          endingColor:[NSColor colorWithSRGBRed:0.08 green:0.08 blue:0.09 alpha:1]];
            [tile drawInRect:bodyRect angle:-90];
            NSFont *font = [NSFont monospacedSystemFontOfSize:260 * scale weight:NSFontWeightBold];
            NSDictionary *attrs = @{ NSFontAttributeName: font,
                                     NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.55 green:0.93
                                                                                          blue:0.62 alpha:1] };
            NSString *prompt = @">_";
            NSSize size = [prompt sizeWithAttributes:attrs];
            [prompt drawAtPoint:NSMakePoint(NSMinX(bodyRect) + 110 * scale,
                                            NSMaxY(bodyRect) - size.height - 90 * scale)
                 withAttributes:attrs];
        });
        CWDrawBodyEdge(body);
        return YES;
    }];
    return CWMarkStyled(icon);
}

/// Icon for windowed processes that ship no icon of their own.
static NSImage *CWFallbackIcon(void)
{
    if (CWIsConsoleHost()) return CWConsoleIcon();

    NSString *path = CWEnv("CROSSWIRE_FALLBACK_ICON");
    NSImage *image = path ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
    // The Crosswire app icon is already a finished macOS icon.
    if (image && [path.pathExtension.lowercaseString isEqualToString:@"icns"]) return CWMarkStyled(image);
    return image ? CWStyledIcon(image) : CWConsoleIcon();
}

static IMP gOriginalSetIcon;

static void CWSetApplicationIconImage(id self, SEL _cmd, NSImage *image)
{
    CWApplyDisplayName();
    NSImage *styled = image ? CWStyledIcon(image) : CWFallbackIcon();
    CWLog(@"dock icon set (%@, source %@)", CWDisplayName(), image ? NSStringFromSize(image.size) : @"none");
    ((void (*)(id, SEL, NSImage *))gOriginalSetIcon)(self, _cmd, styled);
}

static IMP gOriginalSetActivationPolicy;

/// The Dock reads an app's name when it turns into a regular (Dock-visible)
/// app, so the display name must be in place before winemac.drv flips the
/// activation policy.
static BOOL CWSetActivationPolicy(id self, SEL _cmd, NSApplicationActivationPolicy policy)
{
    if (policy == NSApplicationActivationPolicyRegular) CWApplyDisplayName();
    return ((BOOL (*)(id, SEL, NSApplicationActivationPolicy))gOriginalSetActivationPolicy)(self, _cmd, policy);
}

static void CWInstallIconHook(void)
{
    Method icon = class_getInstanceMethod([NSApplication class], @selector(setApplicationIconImage:));
    if (icon) gOriginalSetIcon = method_setImplementation(icon, (IMP)CWSetApplicationIconImage);
    Method policy = class_getInstanceMethod([NSApplication class], @selector(setActivationPolicy:));
    if (policy) gOriginalSetActivationPolicy = method_setImplementation(policy, (IMP)CWSetActivationPolicy);
}

#pragma mark - Own Space for games
//
// Pick the game's main window and put it into native macOS full screen, which
// gives it its own Space next to the current desktop. Swipe with three
// fingers (or Control-arrow) to move between the game and the desktop.
//
// On a notched Mac a full-screen window would normally be placed below the
// camera (1512x949 on a 1512x982 display), while a borderless game insists on
// the whole display. Unity would resize the window back, macOS would shrink
// it again, and DXVK rebuilt its swap chain every frame: the screen flickered.
// The per-app bundle sets NSPrefersDisplaySafeAreaCompatibilityMode=YES, so
// full screen covers the whole display (1512x982) and nothing fights over
// the window size.

typedef NS_ENUM(NSInteger, CWSpaceState) {
    CWSpaceSearching,
    CWSpaceActive,
    CWSpaceOptedOut,
};

static CWSpaceState gSpaceState = CWSpaceSearching;
static __weak NSWindow *gTarget;
static __weak NSWindow *gCandidate;
static NSRect gCandidateFrame;
static NSTimeInterval gCandidateSince;
static BOOL gTogglingOurselves;
static char kTargetKey;

static BOOL CWIsTarget(NSWindow *window)
{
    return window && objc_getAssociatedObject(window, &kTargetKey) != nil;
}

static BOOL CWBoolProperty(id object, SEL selector)
{
    if (![object respondsToSelector:selector]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static IMP gOriginalAdjustFullScreen;
static IMP gOriginalToggleFullScreen;

/// winemac.drv only lets resizable windows be "full screen primary" and
/// kicks fixed-size windows out of full screen. Games are usually fixed size
/// or borderless, so the chosen game window is exempt.
static void CWAdjustFullScreenBehavior(id self, SEL _cmd, NSWindowCollectionBehavior behavior)
{
    NSWindow *window = self;
    if (!CWIsTarget(window)) {
        ((void (*)(id, SEL, NSWindowCollectionBehavior))gOriginalAdjustFullScreen)(self, _cmd, behavior);
        return;
    }
    behavior |= NSWindowCollectionBehaviorFullScreenPrimary;
    behavior &= ~NSWindowCollectionBehaviorFullScreenAuxiliary;
    if (behavior != window.collectionBehavior) {
        window.collectionBehavior = behavior;
        if ([window respondsToSelector:@selector(adjustFeaturesForState)])
            ((void (*)(id, SEL))objc_msgSend)(window, @selector(adjustFeaturesForState));
    }
}

/// winemac.drv refuses full screen for "maximized" windows; borderless
/// full-screen games are often maximized from Windows' point of view.
static void CWToggleFullScreen(id self, SEL _cmd, id sender)
{
    if (CWIsTarget(self) && !CWBoolProperty(self, @selector(disabled))) {
        IMP base = class_getMethodImplementation([NSWindow class], _cmd);
        ((void (*)(id, SEL, id))base)(self, _cmd, sender);
        return;
    }
    ((void (*)(id, SEL, id))gOriginalToggleFullScreen)(self, _cmd, sender);
}

static NSString *CWRejectReason(NSWindow *window, Class wineWindow)
{
    if (![window isKindOfClass:wineWindow]) return @"not a WineWindow";
    if (!window.isVisible) return @"hidden";
    if (window.isMiniaturized) return @"minimized";
    if (window.parentWindow) return @"child window";
    if (window.styleMask & (NSWindowStyleMaskFullScreen | NSWindowStyleMaskUtilityWindow)) return @"full screen/utility";
    if (CWBoolProperty(window, @selector(disabled))) return @"disabled (modal)";
    if (!window.canBecomeKeyWindow) return @"cannot become key";

    NSScreen *screen = window.screen ?: NSScreen.mainScreen;
    NSSize size = window.frame.size;
    NSSize screenSize = screen.frame.size;
    if (size.width < 480 || size.height < 320) return @"too small";
    if (size.width * size.height < 0.25 * screenSize.width * screenSize.height) return @"small vs screen";
    return nil;
}

static BOOL CWIsGameWindowCandidate(NSWindow *window, Class wineWindow)
{
    NSString *reason = CWRejectReason(window, wineWindow);
    if (reason) {
        static NSMutableDictionary<NSNumber *, NSString *> *last;
        if (!last) last = [NSMutableDictionary dictionary];
        NSNumber *key = @(window.windowNumber);
        if (![last[key] isEqualToString:reason]) {
            last[key] = reason;
            CWLog(@"window %ld '%@' %@ rejected: %@", (long)window.windowNumber, window.title,
                  NSStringFromRect(window.frame), reason);
        }
        return NO;
    }
    return YES;
}

static void CWEnterOwnSpace(NSWindow *game)
{
    CWLog(@"entering own Space for window %ld '%@' frame=%@", (long)game.windowNumber, game.title,
          NSStringFromRect(game.frame));
    objc_setAssociatedObject(game, &kTargetKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    gTarget = game;
    gSpaceState = CWSpaceActive;

    NSWindowCollectionBehavior behavior = game.collectionBehavior;
    behavior |= NSWindowCollectionBehaviorFullScreenPrimary;
    behavior &= ~NSWindowCollectionBehaviorFullScreenAuxiliary;
    game.collectionBehavior = behavior;

    gTogglingOurselves = YES;
    [game toggleFullScreen:nil];
    gTogglingOurselves = NO;
    CWLog(@"after toggle: style=0x%lx frame=%@", (unsigned long)game.styleMask, NSStringFromRect(game.frame));
}

static void CWSpaceTick(void)
{
    if (gSpaceState == CWSpaceOptedOut) return;
    if (gSpaceState == CWSpaceActive) {
        if (gTarget) return;
        gSpaceState = CWSpaceSearching;  // the game closed its window; watch for the next one
    }

    Class wineWindow = NSClassFromString(@"WineWindow");
    if (!wineWindow) return;

    NSWindow *best = nil;
    CGFloat bestArea = 0;
    for (NSWindow *window in NSApp.windows) {
        if (!CWIsGameWindowCandidate(window, wineWindow)) continue;
        CGFloat area = window.frame.size.width * window.frame.size.height;
        if (area > bestArea) { best = window; bestArea = area; }
    }

    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (!best) { gCandidate = nil; return; }
    if (best != gCandidate || !NSEqualRects(best.frame, gCandidateFrame)) {
        // Games resize and reposition while starting up; wait until settled.
        gCandidate = best;
        gCandidateFrame = best.frame;
        gCandidateSince = now;
        return;
    }
    if (now - gCandidateSince >= 1.5) CWEnterOwnSpace(best);
}

static void CWInstallOwnSpace(void)
{
    Class wineWindow = NSClassFromString(@"WineWindow");
    if (!wineWindow) return;

    Method adjust = class_getInstanceMethod(wineWindow, @selector(adjustFullScreenBehavior:));
    Method toggle = class_getInstanceMethod(wineWindow, @selector(toggleFullScreen:));
    if (!adjust || !toggle) return;
    gOriginalAdjustFullScreen = method_setImplementation(adjust, (IMP)CWAdjustFullScreenBehavior);
    gOriginalToggleFullScreen = method_setImplementation(toggle, (IMP)CWToggleFullScreen);
    CWLog(@"own-Space hooks installed");

    [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidExitFullScreenNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification *note) {
        NSWindow *window = note.object;
        if (CWIsTarget(window) && !gTogglingOurselves) {
            // The user chose to leave the game's Space; don't fight them.
            gSpaceState = CWSpaceOptedOut;
            objc_setAssociatedObject(window, &kTargetKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if ([window respondsToSelector:@selector(adjustFullScreenBehavior:)])
                ((void (*)(id, SEL, NSWindowCollectionBehavior))objc_msgSend)(
                    window, @selector(adjustFullScreenBehavior:), window.collectionBehavior);
        }
    }];

    NSTimer *timer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        (void)t;
        CWSpaceTick();
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}

#pragma mark - Entry point

__attribute__((visibility("default")))
void CrosswireShellUIInstall(void)
{
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;

    @autoreleasepool {
        CWApplyDisplayName();
        CWInstallIconHook();

        const char *ownSpace = getenv("CROSSWIRE_OWN_SPACE");
        if (ownSpace && ownSpace[0] == '1' && !CWIsShellHelper()) {
            // winemac.so (and WineWindow) is loaded by now, but defer one turn
            // of the run loop so the class is fully set up.
            dispatch_async(dispatch_get_main_queue(), ^{ CWInstallOwnSpace(); });
        }
    }
}
