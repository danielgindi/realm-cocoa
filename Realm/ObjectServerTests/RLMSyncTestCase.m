////////////////////////////////////////////////////////////////////////////
//
// Copyright 2016 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

#import "RLMSyncTestCase.h"

#import <XCTest/XCTest.h>
#import <Realm/Realm.h>

#import "RLMSyncManager+ObjectServerTests.h"
#import "RLMSyncUser+ObjectServerTests.h"

#if !TARGET_OS_MAC
#error These tests can only be run on a macOS host.
#endif

@interface RLMSyncManager ()
+ (void)_setCustomBundleID:(NSString *)customBundleID;
- (instancetype)initWithCustomRootDirectory:(NSURL *)rootDirectory;
@end

@interface RLMSyncTestCase ()
@property (nonatomic) NSTask *task;
@end

@implementation SyncObject
@end

static NSTask *s_task;
static RLMSyncManager *s_managerForTest;

static NSURL *syncDirectoryForChildProcess() {
    NSString *path = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES)[0];
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *bundleIdentifier = bundle.bundleIdentifier ?: bundle.executablePath.lastPathComponent;
    path = [path stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-child", bundleIdentifier]];
    [[NSFileManager defaultManager] createDirectoryAtPath:path
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return [NSURL fileURLWithPath:path isDirectory:YES];
}

@implementation RLMSyncTestCase

+ (RLMSyncManager *)managerForCurrentTest {
    return s_managerForTest;
}

#pragma mark - Helper methods

+ (NSURL *)rootRealmCocoaURL {
    return [[[[NSURL fileURLWithPath:@(__FILE__)]
              URLByDeletingLastPathComponent]
             URLByDeletingLastPathComponent]
            URLByDeletingLastPathComponent];
}

+ (NSURL *)authServerURL {
    return [NSURL URLWithString:@"http://127.0.0.1:9080"];
}

+ (RLMSyncCredentials *)basicCredentialsWithName:(NSString *)name register:(BOOL)shouldRegister {
    return [RLMSyncCredentials credentialsWithUsername:name
                                              password:@"a"
                                              register:shouldRegister];
}

- (void)addSyncObjectsToRealm:(RLMRealm *)realm descriptions:(NSArray<NSString *> *)descriptions {
    [realm beginWriteTransaction];
    for (NSString *desc in descriptions) {
        [realm addObject:[[SyncObject alloc] initWithValue:@[desc]]];
    }
    [realm commitWriteTransaction];
}

- (void)waitForDownloadsForUser:(RLMSyncUser *)user
                         realms:(NSArray<RLMRealm *> *)realms
                      realmURLs:(NSArray<NSURL *> *)realmURLs
                 expectedCounts:(NSArray<NSNumber *> *)counts {
    NSAssert(realms.count == counts.count && realms.count == realmURLs.count,
             @"Test logic error: all array arguments must be the same size.");
    for (NSUInteger i = 0; i < realms.count; i++) {
        WAIT_FOR_DOWNLOAD(user, realmURLs[i]);
        [realms[i] refresh];
        CHECK_COUNT([counts[i] integerValue], SyncObject, realms[i]);
    }
}

- (RLMRealm *)openRealmForURL:(NSURL *)url user:(RLMSyncUser *)user {
    NSError *error = nil;
    const NSTimeInterval timeout = 4;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    RLMSyncBasicErrorReportingBlock basicBlock = ^(NSError *error) {
        if (error) {
            XCTFail(@"Received an asynchronous error: %@ (process: %@)", error, self.isParent ? @"parent" : @"child");
        }
        dispatch_semaphore_signal(sema);
    };
    [[RLMSyncManager sharedManager] setSessionCompletionNotifier:basicBlock];
    RLMRealmConfiguration *c = [[RLMRealmConfiguration defaultConfiguration] copy];
    c.syncConfiguration = [[RLMSyncConfiguration alloc] initWithUser:user realmURL:url];
    RLMRealm *realm = [RLMRealm realmWithConfiguration:c error:&error];
    // Wait for login to succeed or fail.
    XCTAssert(dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) == 0,
              @"Timed out while trying to asynchronously open Realm for URL: %@", url);
    return realm;
}

- (RLMRealm *)managementRealmForUser:(RLMSyncUser *)user {
    NSError *error = nil;
    RLMRealm *managementRealm = [user managementRealmWithError:&error];

    XCTAssertNotNil(managementRealm);
    XCTAssertNil(error, @"Error when opening management Realm: %@", error);

    return managementRealm;
}

- (RLMRealm *)immediatelyOpenRealmForURL:(NSURL *)url user:(RLMSyncUser *)user {
    NSError *error = nil;
    RLMRealmConfiguration *c = [[RLMRealmConfiguration defaultConfiguration] copy];
    c.syncConfiguration = [[RLMSyncConfiguration alloc] initWithUser:user realmURL:url];
    RLMRealm *realm = [RLMRealm realmWithConfiguration:c error:&error];
    XCTAssertNil(error, @"Experienced an error opening the Realm at %@: %@", url, error);
    return realm;
}

- (RLMSyncUser *)logInUserForCredentials:(RLMSyncCredentials *)credentials
                                  server:(NSURL *)url {
    NSString *process = self.isParent ? @"parent" : @"child";
    __block RLMSyncUser *theUser = nil;
    XCTestExpectation *expectation = [self expectationWithDescription:@"Should log in the user properly"];
    [RLMSyncUser logInWithCredentials:credentials
                        authServerURL:url
                         onCompletion:^(RLMSyncUser *user, NSError *error) {
                             XCTAssertNil(error,
                                          @"Error when trying to log in a user: %@ (process: %@)",
                                          error, process);
                             XCTAssertNotNil(user);
                             theUser = user;
                             [expectation fulfill];
                         }];
    [self waitForExpectationsWithTimeout:4.0 handler:nil];
    XCTAssertTrue(theUser.state == RLMSyncUserStateActive,
                  @"User should have been valid, but wasn't. (process: %@)", process);
    return theUser;
}

// FIXME: remove this API once the new token system is implemented.
- (void)primeSyncManagerWithSemaphore:(dispatch_semaphore_t)semaphore {
    if (semaphore == nil) {
        [[RLMSyncManager sharedManager] setSessionCompletionNotifier:^(__unused NSError *error){ }];
        return;
    }
    [[RLMSyncManager sharedManager] setSessionCompletionNotifier:^(NSError *error) {
        XCTAssertNil(error, @"Session completion block returned with an error: %@", error);
        dispatch_semaphore_signal(semaphore);
    }];
}

#pragma mark - XCUnitTest Lifecycle

+ (void)setUp {
    [super setUp];
    NSString *syncDirectory = [[[self rootRealmCocoaURL] URLByAppendingPathComponent:@"sync"] path];
    BOOL isDirectory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:syncDirectory isDirectory:&isDirectory] || !isDirectory) {
        NSLog(@"sync/ directory doesn't exist. You need to run 'build.sh download-object-server' prior to running these tests");
        abort();
    }
}

- (void)lazilyInitializeObjectServer {
    if (!self.isParent || s_task) {
        return;
    }
    [RLMSyncTestCase runResetObjectServer:YES];
    NSTask *task = [[NSTask alloc] init];
    task.currentDirectoryPath = [[RLMSyncTestCase rootRealmCocoaURL] path];
    task.launchPath = @"/bin/sh";
    task.arguments = @[@"build.sh", @"start-object-server"];
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    task.standardOutput = [NSPipe pipe];
    [[task.standardOutput fileHandleForReading] setReadabilityHandler:^(NSFileHandle *file) {
        NSData *data = [file availableData];
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if ([output containsString:@"Received: IDENT"]) {
            dispatch_semaphore_signal(sema);
        }
    }];
    s_task = task;
    [task launch];
    const NSTimeInterval timeout = 60;
    BOOL wait_result = dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) == 0;
    if (!wait_result) {
        s_task = nil;
        XCTFail(@"Server did not start up within the allotted timeout interval.");
    }
}

+ (void)runResetObjectServer:(BOOL)initial {
    NSTask *task = [[NSTask alloc] init];
    task.currentDirectoryPath = [[RLMSyncTestCase rootRealmCocoaURL] path];
    task.launchPath = @"/bin/sh";
    task.arguments = @[@"build.sh", initial ? @"reset-object-server" : @"reset-object-server-between-tests"];
    task.standardOutput = [NSPipe pipe];
    [task launch];
    [task waitUntilExit];
}

- (void)setUp {
    [super setUp];
    self.continueAfterFailure = NO;
    [self lazilyInitializeObjectServer];

    if (self.isParent) {
        XCTAssertNotNil(s_task, @"Test suite setup did not complete: server did not start properly.");
        [RLMSyncTestCase runResetObjectServer:NO];
        s_managerForTest = [[RLMSyncManager alloc] initWithCustomRootDirectory:nil];
    } else {
        // Configure the sync manager to use a different directory than the parent process.
        s_managerForTest = [[RLMSyncManager alloc] initWithCustomRootDirectory:syncDirectoryForChildProcess()];
    }
    [RLMSyncManager sharedManager].logLevel = RLMSyncLogLevelOff;
}

- (void)tearDown {
    [s_managerForTest prepareForDestruction];
    s_managerForTest = nil;
    [super tearDown];
}

@end
