//
//  CDEPersistentStoreEnsemble.m
//  Ensembles
//
//  Created by Drew McCormack on 4/11/13.
//  Copyright (c) 2013 Drew McCormack. All rights reserved.
//

#import "CDEPersistentStoreEnsemble.h"
#import "CDECloudManager.h"
#import "CDEPersistentStoreImporter.h"
#import "CDEEventStore.h"
#import "CDEDefines.h"
#import "CDEAsynchronousTaskQueue.h"
#import "CDECloudFile.h"
#import "CDECloudDirectory.h"
#import "CDECloudFileSystem.h"
#import "CDESaveMonitor.h"
#import "CDEEventIntegrator.h"
#import "CDEEventBuilder.h"
#import "CDEBaselineConsolidator.h"
#import "CDERebaser.h"

static NSString * const kCDEIdentityTokenContext = @"kCDEIdentityTokenContext";

static NSString * const kCDEStoreIdentifierKey = @"storeIdentifier";
static NSString * const kCDELeechDate = @"leechDate";

static NSString * const kCDEMergeTaskInfo = @"Merge";

NSString * const CDEMonitoredManagedObjectContextWillSaveNotification = @"CDEMonitoredManagedObjectContextWillSaveNotification";
NSString * const CDEMonitoredManagedObjectContextDidSaveNotification = @"CDEMonitoredManagedObjectContextDidSaveNotification";
NSString * const CDEPersistentStoreEnsembleDidSaveMergeChangesNotification = @"CDEPersistentStoreEnsembleDidSaveMergeChangesNotification";

NSString * const CDEManagedObjectContextSaveNotificationKey = @"managedObjectContextSaveNotification";


@interface CDEPersistentStoreEnsemble ()

@property (nonatomic, strong, readwrite) CDECloudManager *cloudManager;
@property (nonatomic, strong, readwrite) id <CDECloudFileSystem> cloudFileSystem;
@property (nonatomic, strong, readwrite) NSString *ensembleIdentifier;
@property (nonatomic, strong, readwrite) NSString *storePath;
@property (nonatomic, strong, readwrite) NSManagedObjectModel *managedObjectModel;
@property (nonatomic, strong, readwrite) NSURL *managedObjectModelURL;
@property (nonatomic, assign, readwrite, getter = isLeeched) BOOL leeched;
@property (nonatomic, assign, readwrite, getter = isMerging) BOOL merging;
@property (nonatomic, strong, readwrite) CDEEventStore *eventStore;
@property (nonatomic, strong, readwrite) CDESaveMonitor *saveMonitor;
@property (nonatomic, strong, readwrite) CDEEventIntegrator *eventIntegrator;
@property (nonatomic, strong, readwrite) CDEBaselineConsolidator *baselineConsolidator;
@property (nonatomic, strong, readwrite) CDERebaser *rebaser;

@end


@implementation CDEPersistentStoreEnsemble {
    BOOL saveOccurredDuringImport;
    NSOperationQueue *operationQueue;
    BOOL observingIdentityToken;
}

@synthesize cloudFileSystem = cloudFileSystem;
@synthesize ensembleIdentifier = ensembleIdentifier;
@synthesize storePath = storePath;
@synthesize leeched = leeched;
@synthesize merging = merging;
@synthesize cloudManager = cloudManager;
@synthesize eventStore = eventStore;
@synthesize saveMonitor = saveMonitor;
@synthesize eventIntegrator = eventIntegrator;
@synthesize managedObjectModel = managedObjectModel;
@synthesize managedObjectModelURL = managedObjectModelURL;
@synthesize baselineConsolidator = baselineConsolidator;
@synthesize rebaser = rebaser;

#pragma mark - Initialization and Deallocation

- (instancetype)initWithEnsembleIdentifier:(NSString *)identifier persistentStorePath:(NSString *)path managedObjectModelURL:(NSURL *)modelURL cloudFileSystem:(id <CDECloudFileSystem>)newCloudFileSystem localDataRootDirectory:(NSString *)eventDataRoot
{
    self = [super init];
    if (self) {
        operationQueue = [[NSOperationQueue alloc] init];
        operationQueue.maxConcurrentOperationCount = 1;
        
        observingIdentityToken = NO;
        
        self.ensembleIdentifier = identifier;
        self.storePath = path;
        self.managedObjectModelURL = modelURL;
        self.managedObjectModel = [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL];
        self.cloudFileSystem = newCloudFileSystem;
    
        self.eventStore = [[CDEEventStore alloc] initWithEnsembleIdentifier:self.ensembleIdentifier pathToEventDataRootDirectory:eventDataRoot];
        self.leeched = eventStore.containsEventData;
        if (self.leeched) [self.eventStore removeUnusedDataWithCompletion:NULL];
        
        [self initializeEventIntegrator];
        
        self.saveMonitor = [[CDESaveMonitor alloc] initWithStorePath:path];
        self.saveMonitor.ensemble = self;
        self.saveMonitor.eventStore = eventStore;
        self.saveMonitor.eventIntegrator = self.eventIntegrator;
        
        self.cloudManager = [[CDECloudManager alloc] initWithEventStore:self.eventStore cloudFileSystem:self.cloudFileSystem];
        
        self.baselineConsolidator = [[CDEBaselineConsolidator alloc] initWithEventStore:self.eventStore];
        self.rebaser = [[CDERebaser alloc] initWithEventStore:self.eventStore];
        
        [self performInitialChecks];
    }
    return self;
}

- (instancetype)initWithEnsembleIdentifier:(NSString *)identifier persistentStorePath:(NSString *)path managedObjectModelURL:(NSURL *)modelURL cloudFileSystem:(id <CDECloudFileSystem>)newCloudFileSystem
{
    return [self initWithEnsembleIdentifier:identifier persistentStorePath:path managedObjectModelURL:modelURL cloudFileSystem:newCloudFileSystem localDataRootDirectory:nil];
}

- (void)initializeEventIntegrator
{
    NSURL *url = [NSURL fileURLWithPath:self.storePath];
    self.eventIntegrator = [[CDEEventIntegrator alloc] initWithStoreURL:url managedObjectModel:self.managedObjectModel eventStore:self.eventStore];
    self.eventIntegrator.ensemble = self;
    
    __weak typeof(self) weakSelf = self;
    self.eventIntegrator.shouldSaveBlock = ^(NSManagedObjectContext *savingContext, NSManagedObjectContext *reparationContext) {
        BOOL result = YES;
        __strong typeof(self) strongSelf = weakSelf;
        if ([strongSelf.delegate respondsToSelector:@selector(persistentStoreEnsemble:shouldSaveMergedChangesInManagedObjectContext:reparationManagedObjectContext:)]) {
            result = [strongSelf.delegate persistentStoreEnsemble:strongSelf shouldSaveMergedChangesInManagedObjectContext:savingContext reparationManagedObjectContext:reparationContext];
        }
        return result;
    };
    
    self.eventIntegrator.failedSaveBlock = ^(NSManagedObjectContext *savingContext, NSError *error, NSManagedObjectContext *reparationContext) {
        __strong typeof(self) strongSelf = weakSelf;
        if ([strongSelf.delegate respondsToSelector:@selector(persistentStoreEnsemble:didFailToSaveMergedChangesInManagedObjectContext:error:reparationManagedObjectContext:)]) {
            return [strongSelf.delegate persistentStoreEnsemble:strongSelf didFailToSaveMergedChangesInManagedObjectContext:savingContext error:error reparationManagedObjectContext:reparationContext];
        }
        return NO;
    };
    
    self.eventIntegrator.didSaveBlock = ^(NSManagedObjectContext *context, NSDictionary *info) {
        __strong typeof(self) strongSelf = weakSelf;
        NSNotification *notification = [NSNotification notificationWithName:NSManagedObjectContextDidSaveNotification object:context userInfo:info];
        if ([strongSelf.delegate respondsToSelector:@selector(persistentStoreEnsemble:didSaveMergeChangesWithNotification:)]) {
            [strongSelf.delegate persistentStoreEnsemble:strongSelf didSaveMergeChangesWithNotification:notification];
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:CDEPersistentStoreEnsembleDidSaveMergeChangesNotification object:strongSelf userInfo:@{CDEManagedObjectContextSaveNotificationKey : notification}];
    };
}

- (void)dealloc
{
    if (observingIdentityToken) [(id)self.cloudFileSystem removeObserver:self forKeyPath:@"identityToken"];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [saveMonitor stopMonitoring];
}

#pragma mark - Initial Checks

- (void)performInitialChecks
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self checkIncompleteEvents]) return;
        [self checkCloudFileSystemIdentityWithCompletion:^(NSError *error) {
            if (!error) {
                observingIdentityToken = YES;
                [(id)self.cloudFileSystem addObserver:self forKeyPath:@"identityToken" options:0 context:(__bridge void *)kCDEIdentityTokenContext];
            }
        }];
    });
}

- (BOOL)checkIncompleteEvents
{
    BOOL succeeded = YES;
    if (eventStore.incompleteMandatoryEventIdentifiers.count > 0) {
        succeeded = NO;
        [self deleechPersistentStoreWithCompletion:^(NSError *error) {
            if (!error) {
                if ([self.delegate respondsToSelector:@selector(persistentStoreEnsemble:didDeleechWithError:)]) {
                    NSError *deleechError = [NSError errorWithDomain:CDEErrorDomain code:CDEErrorCodeDataCorruptionDetected userInfo:nil];
                    [self.delegate persistentStoreEnsemble:self didDeleechWithError:deleechError];
                }
            }
            else {
                CDELog(CDELoggingLevelError, @"Could not deleech after failing incomplete event check: %@", error);
            }
        }];
    }
    else {
        NSManagedObjectContext *context = eventStore.managedObjectContext;
        for (NSString *eventId in eventStore.incompleteEventIdentifiers) {
            [context performBlock:^{
                CDEStoreModificationEvent *event = [CDEStoreModificationEvent fetchStoreModificationEventWithUniqueIdentifier:eventId inManagedObjectContext:context];
                if (!event) return;
                
                [context deleteObject:event];
                
                NSError *error;
                if ([context save:&error]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [eventStore deregisterIncompleteEventIdentifier:eventId];
                    });
                }
                else {
                    CDELog(CDELoggingLevelError, @"Could not save after deleting incomplete event: %@", error);
                }
            }];
        }
    }
    return succeeded;
}

#pragma mark - Completing Operations

- (void)dispatchCompletion:(CDECompletionBlock)completion withError:(NSError *)error
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) completion(error);
    });
}

#pragma mark - Key Value Observing

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context == (__bridge void *)kCDEIdentityTokenContext) {
        [self checkCloudFileSystemIdentityWithCompletion:NULL];
    }
}

#pragma mark - Leeching and Deleeching Stores

- (void)leechPersistentStoreWithCompletion:(CDECompletionBlock)completion;
{
    NSAssert(self.cloudFileSystem, @"No cloud file system set");
    NSAssert([NSThread isMainThread], @"leech method called off main thread");
    
    if (self.isLeeched) {
        NSError *error = [[NSError alloc] initWithDomain:CDEErrorDomain code:CDEErrorCodeDisallowedStateChange userInfo:nil];
        [self dispatchCompletion:completion withError:error];
        return;
    }

    NSMutableArray *tasks = [NSMutableArray array];
    
    CDEAsynchronousTaskBlock connectTask = ^(CDEAsynchronousTaskCallbackBlock next) {
        [self.cloudFileSystem connect:^(NSError *error) {
            next(error, NO);
        }];
    };
    [tasks addObject:connectTask];
    
    if ([self.cloudFileSystem respondsToSelector:@selector(performInitialPreparation:)]) {
        CDEAsynchronousTaskBlock initialPrepTask = ^(CDEAsynchronousTaskCallbackBlock next) {
            [self.cloudFileSystem performInitialPreparation:^(NSError *error) {
                next(error, NO);
            }];
        };
        [tasks addObject:initialPrepTask];
    }

    CDEAsynchronousTaskBlock remoteStructureTask = ^(CDEAsynchronousTaskCallbackBlock next) {
        [self.cloudManager createRemoteDirectoryStructureWithCompletion:^(NSError *error) {
            next(error, NO);
        }];
    };
    [tasks addObject:remoteStructureTask];
    
    CDEAsynchronousTaskBlock eventStoreTask = ^(CDEAsynchronousTaskCallbackBlock next) {
        [self setupEventStoreWithCompletion:^(NSError *error) {
            next(error, NO);
        }];
    };
    [tasks addObject:eventStoreTask];
    
    CDEAsynchronousTaskBlock importTask = ^(CDEAsynchronousTaskCallbackBlock next) {
        // Listen for save notifications, and fail if a save to the store happens during the import
        saveOccurredDuringImport = NO;
        [self beginObservingSaveNotifications];
        
        // Inform delegate of import
        if ([self.delegate respondsToSelector:@selector(persistentStoreEnsembleWillImportStore:)]) {
            [self.delegate persistentStoreEnsembleWillImportStore:self];
        }
        
        CDEPersistentStoreImporter *importer = [[CDEPersistentStoreImporter alloc] initWithPersistentStoreAtPath:self.storePath managedObjectModel:self.managedObjectModel eventStore:self.eventStore];
        importer.ensemble = self;
        [importer importWithCompletion:^(NSError *error) {
            [self endObservingSaveNotifications];
            
            if (nil == error) {
                // Store baseline
                self.eventStore.identifierOfBaselineUsedToConstructStore = [self.eventStore currentBaselineIdentifier];
                
                // Inform delegate
                if ([self.delegate respondsToSelector:@selector(persistentStoreEnsembleDidImportStore:)]) {
                    [self.delegate persistentStoreEnsembleDidImportStore:self];
                }
            }
            
            next(error, NO);
        }];
    };
    [tasks addObject:importTask];
    
    CDEAsynchronousTaskBlock snapshotRemoteFilesTask = ^(CDEAsynchronousTaskCallbackBlock next) {
        [self.cloudManager snapshotRemoteFilesWithCompletion:^(NSError *error) {
            next(error, NO);
        }];
    };
    [tasks addObject:snapshotRemoteFilesTask];
    
    CDEAsynchronousTaskBlock exportDataFilesTask = ^(CDEAsynchronousTaskCallbackBlock next) {
        [self.cloudManager exportDataFilesWithCompletion:^(NSError *error) {
            next(error, NO);
        }];
    };
    [tasks addObject:exportDataFilesTask];
    
    CDEAsynchronousTaskBlock exportBaselinesTask = ^(CDEAsynchronousTaskCallbackBlock next) {
        [self.cloudManager exportNewLocalBaselineWithCompletion:^(NSError *error) {
            if (error) CDELog(CDELoggingLevelError, @"Failed to export baseline file during leech. Continuing regardless.");
            next(nil, NO); // If the export fails, continue regardless. Not essential.
        }];
    };
    [tasks addObject:exportBaselinesTask];
    
    CDEAsynchronousTaskBlock completeLeechTask = ^(CDEAsynchronousTaskCallbackBlock next) {
        // Deleech if a save occurred during import
        if (saveOccurredDuringImport) {
            NSError *error = nil;
            error = [NSError errorWithDomain:CDEErrorDomain code:CDEErrorCodeSaveOccurredDuringLeeching userInfo:nil];
            [self performSelector:@selector(forceDeleechDueToError:) withObject:error afterDelay:0.0];
            next(error, NO);
            return;
        }
        
        // Register in cloud
        NSDictionary *info = @{kCDEStoreIdentifierKey: self.eventStore.persistentStoreIdentifier, kCDELeechDate: [NSDate date]};
        [self.cloudManager setRegistrationInfo:info forStoreWithIdentifier:self.eventStore.persistentStoreIdentifier completion:^(NSError *error) {
            next(error, NO);
        }];
    };
    [tasks addObject:completeLeechTask];
    
    CDEAsynchronousTaskQueue *taskQueue = [[CDEAsynchronousTaskQueue alloc] initWithTasks:tasks terminationPolicy:CDETaskQueueTerminationPolicyStopOnError completion:^(NSError *error) {
        [self dispatchCompletion:completion withError:error];
    }];
    
    [operationQueue addOperation:taskQueue];
}

- (void)setupEventStoreWithCompletion:(CDECompletionBlock)completion
{    
    NSError *error = nil;
    eventStore.cloudFileSystemIdentityToken = self.cloudFileSystem.identityToken;
    BOOL success = [eventStore prepareNewEventStore:&error];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.leeched = success;
        if (completion) completion(error);
    });
}

- (void)deleechPersistentStoreWithCompletion:(CDECompletionBlock)completion
{
    NSAssert([NSThread isMainThread], @"Deleech method called off main thread");
    
    CDEAsynchronousTaskBlock deleechTask = ^(CDEAsynchronousTaskCallbackBlock next) {
        if (!self.isLeeched) {
            [eventStore removeEventStore];
            NSError *error = [[NSError alloc] initWithDomain:CDEErrorDomain code:CDEErrorCodeDisallowedStateChange userInfo:nil];
            next(error, NO);
            return;
        }
        
        BOOL removedStore = [eventStore removeEventStore];
        self.leeched = eventStore.containsEventData;
        
        NSError *error = nil;
        if (!removedStore) error = [NSError errorWithDomain:CDEErrorDomain code:CDEErrorCodeUnknown userInfo:nil];
        next(error, NO);
    };
    
    CDEAsynchronousTaskQueue *deleechQueue = [[CDEAsynchronousTaskQueue alloc] initWithTask:deleechTask completion:^(NSError *error) {
        [self dispatchCompletion:completion withError:error];
    }];
    
    [operationQueue cancelAllOperations];
    [operationQueue addOperation:deleechQueue];
}

#pragma mark Observing saves during import

- (void)beginObservingSaveNotifications
{
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(managedObjectContextWillSave:) name:NSManagedObjectContextWillSaveNotification object:nil];
}

- (void)endObservingSaveNotifications
{
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSManagedObjectContextWillSaveNotification object:nil];
}

- (void)managedObjectContextWillSave:(NSNotification *)notif
{
    NSManagedObjectContext *context = notif.object;
    NSArray *stores = context.persistentStoreCoordinator.persistentStores;
    for (NSPersistentStore *store in stores) {
        if ([self.storePath isEqualToString:store.URL.path]) {
            saveOccurredDuringImport = YES;
            break;
        }
    }
}

#pragma mark Checks

- (void)forceDeleechDueToError:(NSError *)deleechError
{
    [self deleechPersistentStoreWithCompletion:^(NSError *error) {
        if (!error) {
            if ([self.delegate respondsToSelector:@selector(persistentStoreEnsemble:didDeleechWithError:)]) {
                [self.delegate persistentStoreEnsemble:self didDeleechWithError:deleechError];
            }
        }
        else {
            CDELog(CDELoggingLevelError, @"Could not force deleech");
        }
    }];
}

- (void)checkCloudFileSystemIdentityWithCompletion:(CDECompletionBlock)completion
{
    BOOL identityValid = [self.cloudFileSystem.identityToken isEqual:self.eventStore.cloudFileSystemIdentityToken];
    if (self.leeched && !identityValid) {
        NSError *deleechError = [NSError errorWithDomain:CDEErrorDomain code:CDEErrorCodeCloudIdentityChanged userInfo:nil];
        [self performSelector:@selector(forceDeleechDueToError:) withObject:deleechError afterDelay:0.0];
        if (completion) completion(deleechError);
    }
    else {
        [self dispatchCompletion:completion withError:nil];
    }
}

- (void)checkStoreRegistrationInCloudWithCompletion:(CDECompletionBlock)completion
{
    if (!self.eventStore.verifiesStoreRegistrationInCloud) {
        [self dispatchCompletion:completion withError:nil];
        return;
    }
    
    NSString *storeId = self.eventStore.persistentStoreIdentifier;
    [self.cloudManager retrieveRegistrationInfoForStoreWithIdentifier:storeId completion:^(NSDictionary *info, NSError *error) {
        if (!error && !info) {
            NSError *unregisteredError = [NSError errorWithDomain:CDEErrorDomain code:CDEErrorCodeStoreUnregistered userInfo:nil];
            [self performSelector:@selector(forceDeleechDueToError:) withObject:unregisteredError afterDelay:0.0];
            if (completion) completion(unregisteredError);
        }
        else {
            // If there was an error, can't conclude anything about registration state. Assume registered.
            // Don't want to deleech for no good reason.
            [self dispatchCompletion:completion withError:nil];
        }
    }];
}

#pragma mark Accessors

- (NSString *)localDataRootDirectory
{
    return self.eventStore.pathToEventDataRootDirectory;
}

#pragma mark Merging Changes

- (void)mergeWithCompletion:(CDECompletionBlock)completion
{
    NSAssert([NSThread isMainThread], @"Merge method called off main thread");
    
    if (!self.leeched) {
        NSError *error = [[NSError alloc] initWithDomain:CDEErrorDomain code:CDEErrorCodeDisallowedStateChange userInfo:@{NSLocalizedDescriptionKey : @"Attempt to merge a store that is not leeched."}];
        [self dispatchCompletion:completion withError:error];
        return;
    }
    
    if (self.merging) {
        NSError *error = [[NSError alloc] initWithDomain:CDEErrorDomain code:CDEErrorCodeDisallowedStateChange userInfo:@{NSLocalizedDescriptionKey : @"Attempt to merge when merge is already underway."}];
        [self dispatchCompletion:completion withError:error];
        return;
    }
    
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    if (![fileManager fileExistsAtPath:storePath]) {
        NSError *error = nil;
        error = [NSError errorWithDomain:CDEErrorDomain code:CDEErrorCodeMissingStore userInfo:nil];
        [self dispatchCompletion:completion withError:error];
        return;
    }
    
    self.merging = YES;
    [self.eventIntegrator startMonitoringSaves]; // Will cancel merge if save occurs

    NSMutableArray *tasks = [NSMutableArray array];
    
    CDEAsynchronousTaskBlock checkIdentityTask = ^(CDEAsynchronousTaskCallbackBlock next) {
        [self checkCloudFileSystemIdentityWithCompletion:^(NSError *error) {
            next(error, NO);
        }];
    };
    [tasks addObject:checkIdentityTask];
    
    CDEAsynchronousTaskBlock checkRegistrationTask = ^(CDEAsynchronousTaskCallbackBlock next) {
        [self checkStoreRegistrationInCloudWithCompletion:^(NSError *error) {
            next(error, NO);
        }];
    };
    [tasks addObject:checkRegistrationTask];
    
    CDEAsynchronousTaskBlock processChangesTask = ^(CDEAsynchronousTaskCallbackBlock next) {
        NSError *error = nil;
        [eventStore flush:&error];
        next(error, NO);
    };
    [tasks addObject:processChangesTask];
    
    CDEAsynchronousTaskBlock remoteStructureTask = ^(CDEAsynchronousTaskCallbackBlock next) {
        [self.cloudManager createRemoteDirectoryStructureWithCompletion:^(NSError *error) {
            next(error, NO);
        }];
    };
    [tasks addObject:remoteStructureTask];
    
    CDEAsynchronousTaskBlock snapshotRemoteFilesTask = ^(CDEAsynchronousTaskCallbackBlock next) {
        [self.cloudManager snapshotRemoteFilesWithCompletion:^(NSError *error) {
            next(error, NO);
        }];
    };
    [tasks addObject:snapshotRemoteFilesTask];
    
    CDEAsynchronousTaskBlock importDataFilesTask = ^(CDEAsynchronousTaskCallbackBlock next) {
        [self.cloudManager importNewDataFilesWithCompletion:^(NSError *error) {
            next(error, NO);
        }];
    };
    [tasks addObject:importDataFilesTask];

    CDEAsynchronousTaskBlock importBaselinesTask = ^(CDEAsynchronousTaskCallbackBlock next) {
        [self.cloudManager importNewBaselineEventsWithCompletion:^(NSError *error) {
            if (nil == error) {
                // Check if store has been 'left behind'. If so, need full integration later
                if ([self.baselineConsolidator persistentStoreHasBeenAbandoned]) {
                    self.eventStore.identifierOfBaselineUsedToConstructStore = nil;
                }
            }
            next(error, NO);
        }];
    };
    [tasks addObject:importBaselinesTask];
    
    CDEAsynchronousTaskBlock mergeBaselinesTask = ^(CDEAsynchronousTaskCallbackBlock next) {
        [self.baselineConsolidator consolidateBaselineWithCompletion:^(NSError *error) {
            next(error, NO);
        }];
    };
    [tasks addObject:mergeBaselinesTask];
    
    CDEAsynchronousTaskBlock importRemoteEventsTask = ^(CDEAsynchronousTaskCallbackBlock next) {
        [self.cloudManager importNewRemoteNonBaselineEventsWithCompletion:^(NSError *error) {
            next(error, NO);
        }];
    };
    [tasks addObject:importRemoteEventsTask];
    
    CDEAsynchronousTaskBlock removeOutdatedEventsTask = ^(CDEAsynchronousTaskCallbackBlock next) {
        [self.rebaser deleteEventsPreceedingBaselineWithCompletion:^(NSError *error) {
            next(error, NO);
        }];
    };
    [tasks addObject:removeOutdatedEventsTask];
    
    CDEAsynchronousTaskBlock rebaseTask = ^(CDEAsynchronousTaskCallbackBlock next) {
        if ([self.rebaser shouldRebase]) {
            [self.rebaser rebaseWithCompletion:^(NSError *error) {
                next(error, NO);
            }];
        }
        else {
            next(nil, NO);
        }
    };
    [tasks addObject:rebaseTask];
    
    CDEAsynchronousTaskBlock mergeEventsTask = ^(CDEAsynchronousTaskCallbackBlock next) {
        [self.eventIntegrator mergeEventsWithCompletion:^(NSError *error) {
            // Store baseline id if everything went well
            if (nil == error) self.eventStore.identifierOfBaselineUsedToConstructStore = [self.eventStore currentBaselineIdentifier];
            next(error, NO);
        }];
    };
    [tasks addObject:mergeEventsTask];
    
    CDEAsynchronousTaskBlock exportDataFilesTask = ^(CDEAsynchronousTaskCallbackBlock next) {
        [self.eventStore removeUnreferencedDataFiles];
        [self.cloudManager exportDataFilesWithCompletion:^(NSError *error) {
            next(error, NO);
        }];
    };
    [tasks addObject:exportDataFilesTask];
    
    CDEAsynchronousTaskBlock exportBaselinesTask = ^(CDEAsynchronousTaskCallbackBlock next) {
        [self.cloudManager exportNewLocalBaselineWithCompletion:^(NSError *error) {
            next(error, NO);
        }];
    };
    [tasks addObject:exportBaselinesTask];
    
    CDEAsynchronousTaskBlock exportEventsTask = ^(CDEAsynchronousTaskCallbackBlock next) {
        [self.cloudManager exportNewLocalNonBaselineEventsWithCompletion:^(NSError *error) {
            next(error, NO);
        }];
    };
    [tasks addObject:exportEventsTask];
    
    CDEAsynchronousTaskBlock removeRemoteFiles = ^(CDEAsynchronousTaskCallbackBlock next) {
        [self.cloudManager removeOutdatedRemoteFilesWithCompletion:^(NSError *error) {
            next(error, NO);
        }];
    };
    [tasks addObject:removeRemoteFiles];
    
    CDEAsynchronousTaskQueue *taskQueue = [[CDEAsynchronousTaskQueue alloc] initWithTasks:tasks terminationPolicy:CDETaskQueueTerminationPolicyStopOnError completion:^(NSError *error) {
        [self dispatchCompletion:completion withError:error];
        [self.eventIntegrator stopMonitoringSaves];
        self.merging = NO;
    }];
    
    taskQueue.info = kCDEMergeTaskInfo;
    [operationQueue addOperation:taskQueue];
}

- (void)cancelMergeWithCompletion:(CDECompletionBlock)completion
{
    NSAssert([NSThread isMainThread], @"cancel merge method called off main thread");
    for (NSOperation *operation in operationQueue.operations) {
        if ([operation respondsToSelector:@selector(info)] && [[(id)operation info] isEqual:kCDEMergeTaskInfo]) {
            [operation cancel];
        }
    }
    [operationQueue addOperationWithBlock:^{
        [self dispatchCompletion:completion withError:nil];
    }];
}

#pragma mark Prepare for app termination

- (void)processPendingChangesWithCompletion:(CDECompletionBlock)completion
{
    NSAssert([NSThread isMainThread], @"Process pending changes invoked off main thread");
    
    if (!self.leeched) {
        [self dispatchCompletion:completion withError:nil];
        return;
    }
    
    [operationQueue addOperationWithBlock:^{
        NSError *error = nil;
        [eventStore flush:&error];
        [self dispatchCompletion:completion withError:error];
    }];
}

- (void)stopMonitoringSaves
{
    NSAssert([NSThread isMainThread], @"stop monitor method called off main thread");
    [saveMonitor stopMonitoring];
}

#pragma mark Event Builder Delegate

- (NSArray *)globalIdentifiersForManagedObjects:(NSArray *)objects
{
    NSArray *result = nil;
    if ([self.delegate respondsToSelector:@selector(persistentStoreEnsemble:globalIdentifiersForManagedObjects:)]) {
        result = [self.delegate persistentStoreEnsemble:self globalIdentifiersForManagedObjects:objects];
    }
    return result;
}

@end
