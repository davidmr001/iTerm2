//
//  iTermAPIScriptLauncher.m
//  iTerm2SharedARC
//
//  Created by George Nachman on 4/19/18.
//

#import "iTermAPIScriptLauncher.h"

#import "DebugLogging.h"
#import "iTermAPIConnectionIdentifierController.h"
#import "iTermScriptConsole.h"
#import "iTermScriptHistory.h"
#import "iTermWebSocketCookieJar.h"
#import "NSStringITerm.h"
#import "PTYTask.h"

@implementation iTermAPIScriptLauncher

+ (void)launchScript:(NSString *)filename {
    [self launchScript:filename withVirtualEnv:nil];
}

+ (void)launchScript:(NSString *)filename withVirtualEnv:(NSString *)virtualenv {
    NSString *key = [[NSUUID UUID] UUIDString];
    iTermScriptHistoryEntry *entry;
    if ([[iTermScriptConsole sharedInstance] isWindowLoaded] &&
        [[[iTermScriptConsole sharedInstance] window] isVisible]) {
        NSString *name = [[filename lastPathComponent] stringByDeletingPathExtension];
        if ([self isScriptWithEnvironment:[filename stringByDeletingLastPathComponent]]) {
            name = [[[filename stringByDeletingLastPathComponent] pathComponents] lastObject];
        }
        entry = [[iTermScriptHistoryEntry alloc] initWithName:name
                                                   identifier:[[iTermAPIConnectionIdentifierController sharedInstance] identifierForKey:key]];
        [[iTermScriptHistory sharedInstance] addHistoryEntry:entry];
    }
    @try {
        [self tryLaunchScript:filename historyEntry:entry key:key withVirtualEnv:virtualenv];
    }
    @catch (NSException *e) {
        [[iTermScriptHistory sharedInstance] addHistoryEntry:entry];
        [entry addOutput:[NSString stringWithFormat:@"ERROR: Failed to launch: %@", e.reason]];
        [self didFailToLaunchScript:filename withException:e];
    }
}

// THROWS
+ (void)tryLaunchScript:(NSString *)filename historyEntry:(iTermScriptHistoryEntry *)entry key:(NSString *)key withVirtualEnv:(NSString *)virtualenv {
    NSTask *task = [[NSTask alloc] init];
    NSString *shell = [PTYTask userShell];

    task.launchPath = shell;
    task.arguments = [self argumentsToRunScript:filename withVirtualEnv:virtualenv];
    NSString *cookie = [[iTermWebSocketCookieJar sharedInstance] newCookie];
    task.environment = [self environmentFromEnvironment:task.environment shell:shell cookie:cookie key:key];

    NSPipe *pipe = [[NSPipe alloc] init];
    [task setStandardOutput:pipe];
    [task setStandardError:pipe];

    [entry addOutput:[NSString stringWithFormat:@"%@ %@\n", task.launchPath, [task.arguments componentsJoinedByString:@" "]]];
    [task launch];   // This can throw

    [self waitForTask:task readFromPipe:pipe historyEntry:entry];
}

+ (NSDictionary *)environmentFromEnvironment:(NSDictionary *)initialEnvironment
                                       shell:(NSString *)shell
                                      cookie:(NSString *)cookie
                                         key:(NSString *)key {
    NSMutableDictionary *environment = [initialEnvironment ?: @{} mutableCopy];

    environment[@"ITERM2_COOKIE"] = cookie;
    environment[@"ITERM2_KEY"] = key;
    environment[@"HOME"] = NSHomeDirectory();
    environment[@"SHELL"] = shell;
    return environment;
}

+ (NSArray *)argumentsToRunScript:(NSString *)filename withVirtualEnv:(NSString *)providedVirtualEnv {
    NSString *wrapper = [[NSBundle mainBundle] pathForResource:@"it2_api_wrapper" ofType:@"sh"];
    NSString *virtualEnv = providedVirtualEnv ?: [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"iterm2env"];
    NSString *command = [NSString stringWithFormat:@"%@ %@ %@",
                         [wrapper stringWithEscapedShellCharactersExceptTabAndNewline],
                         [virtualEnv stringWithEscapedShellCharactersExceptTabAndNewline],
                         [filename stringWithEscapedShellCharactersExceptTabAndNewline]];
    return @[ @"-c", command ];
}

+ (void)waitForTask:(NSTask *)task readFromPipe:(NSPipe *)pipe historyEntry:(iTermScriptHistoryEntry *)entry {
    static NSMutableArray<dispatch_queue_t> *queues;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queues = [NSMutableArray array];
    });
    dispatch_queue_t q = dispatch_queue_create("com.iterm2.script", NULL);
    [queues addObject:q];
    dispatch_async(q, ^{
        NSFileHandle *readHandle = [pipe fileHandleForReading];
        NSData *inData = [readHandle availableData];
        while (inData.length) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [entry addOutput:[[NSString alloc] initWithData:inData encoding:NSUTF8StringEncoding]];
            });
            inData = [readHandle availableData];
        }

        [task waitUntilExit];
        dispatch_async(dispatch_get_main_queue(), ^{
            [entry stopRunning];
        });
        [queues removeObject:q];
    });
}

+ (void)didFailToLaunchScript:(NSString *)filename withException:(NSException *)e {
    ELog(@"Expection occurred %@", e);
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Error running script";
    alert.informativeText = [NSString stringWithFormat:@"Script at \"%@\" failed.\n\n%@",
                             filename, e.reason];
    [alert runModal];
}

+ (BOOL)isScriptWithEnvironment:(NSString *)path {
    // Scripts that need their own virtual env must have a hierarchy like this:
    // iTerm2/Scripts/MyScript/main.py
    // iTerm2/Scripts/MyScript/env/... (virtualenv goes here)
    NSString *env = [path stringByAppendingPathComponent:@"env"];
    NSString *python = [[env stringByAppendingPathComponent:@"bin"] stringByAppendingPathComponent:@"python"];
    return ([[NSFileManager defaultManager] fileExistsAtPath:[path stringByAppendingPathComponent:@"main.py"] isDirectory:nil] &&
            [[NSFileManager defaultManager] fileExistsAtPath:python isDirectory:nil]);

}

@end

