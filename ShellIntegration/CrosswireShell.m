//
//  CrosswireShell.m
//  Crosswire shell integration — loader stage.
//
//  This file is part of Crosswire.
//
//  Crosswire is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Injected into engine processes with DYLD_INSERT_LIBRARIES by Wine.runProcess.
//  It is deliberately tiny and links Foundation only: most engine processes
//  (wineserver, services.exe, winedevice.exe, ...) never create a window, so
//  they must not pay for AppKit. The AppKit half (CrosswireShellUI.dylib) is
//  loaded only when winemac.drv starts the Cocoa application, which it does
//  with -[NSApplication run] — that posts NSApplicationWillFinishLaunching on
//  the main thread before any window or Dock icon exists.
//

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

void CWShellLog(NSString *format, ...)
{
    const char *path = getenv("CROSSWIRE_SHELL_LOG");
    if (!path || !path[0]) return;
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    FILE *f = fopen(path, "a");
    if (!f) return;
    fprintf(f, "[%d %s] %s\n", getpid(), getprogname(), line.UTF8String);
    fclose(f);
}

static void CWShellLoadUI(void)
{
    static BOOL attempted = NO;
    if (attempted) return;
    attempted = YES;

    Dl_info info;
    if (!dladdr((const void *)CWShellLoadUI, &info) || !info.dli_fname) return;

    NSString *dir = [[NSString stringWithUTF8String:info.dli_fname] stringByDeletingLastPathComponent];
    NSString *ui = [dir stringByAppendingPathComponent:@"CrosswireShellUI.dylib"];
    void *handle = dlopen(ui.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        CWShellLog(@"could not load UI stage: %s", dlerror());
        return;
    }
    void (*install)(void) = (void (*)(void))dlsym(handle, "CrosswireShellUIInstall");
    CWShellLog(@"UI stage loaded (install=%p)", install);
    if (install) install();
}

__attribute__((constructor))
static void CWShellInit(void)
{
    const char *disabled = getenv("CROSSWIRE_SHELL_DISABLE");
    if (disabled && disabled[0] == '1') return;

    const char *name = getprogname();
    if (name && strstr(name, "wineserver")) return;

    @autoreleasepool {
        NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
        CWShellLog(@"loader active argv=%@", [args componentsJoinedByString:@" | "]);
    }

    @autoreleasepool {
        [[NSNotificationCenter defaultCenter]
            addObserverForName:@"NSApplicationWillFinishLaunchingNotification"
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
                        (void)note;
                        CWShellLoadUI();
                    }];
    }
}
