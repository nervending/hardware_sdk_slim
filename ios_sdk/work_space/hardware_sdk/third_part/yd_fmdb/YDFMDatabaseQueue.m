//
//  YDFMDatabaseQueue.m
//  fmdb
//
//  Created by August Mueller on 6/22/11.
//  Copyright 2011 Flying Meat Inc. All rights reserved.
//

#import "YDFMDatabaseQueue.h"
#import "YDFMDatabase.h"

#if YDFMDB_SQLITE_STANDALONE
#import <sqlite3/sqlite3.h>
#else
#import <sqlite3.h>
#endif

/*
 
 Note: we call [self retain]; before using dispatch_sync, just incase 
 YDFMDatabaseQueue is released on another thread and we're in the middle of doing
 something in dispatch_sync
 
 */

/*
 * A key used to associate the YDFMDatabaseQueue object with the dispatch_queue_t it uses.
 * This in turn is used for deadlock detection by seeing if inDatabase: is called on
 * the queue's dispatch queue, which should not happen and causes a deadlock.
 */
static const void * const kDispatchQueueSpecificKey = &kDispatchQueueSpecificKey;
 
@implementation YDFMDatabaseQueue

@synthesize path = _path;
@synthesize openFlags = _openFlags;

+ (instancetype)databaseQueueWithPath:(NSString*)aPath {
    
    YDFMDatabaseQueue *q = [[self alloc] initWithPath:aPath];
    
    YDFMDBAutorelease(q);
    
    return q;
}

+ (instancetype)databaseQueueWithPath:(NSString*)aPath flags:(int)openFlags {
    
    YDFMDatabaseQueue *q = [[self alloc] initWithPath:aPath flags:openFlags];
    
    YDFMDBAutorelease(q);
    
    return q;
}

+ (Class)databaseClass {
    return [YDFMDatabase class];
}

- (instancetype)initWithPath:(NSString*)aPath flags:(int)openFlags vfs:(NSString *)vfsName {
    
    self = [super init];
    
    if (self != nil) {
        
        _db = [[[self class] databaseClass] databaseWithPath:aPath];
        YDFMDBRetain(_db);
        
#if SQLITE_VERSION_NUMBER >= 3005000
        BOOL success = [_db openWithFlags:openFlags vfs:vfsName];
#else
        BOOL success = [_db open];
#endif
        if (!success) {
            NSLog(@"Could not create database queue for path %@", aPath);
            YDFMDBRelease(self);
            return 0x00;
        }
        
        _path = YDFMDBReturnRetained(aPath);
        
        _queue = dispatch_queue_create([[NSString stringWithFormat:@"fmdb.%@", self] UTF8String], NULL);
        dispatch_queue_set_specific(_queue, kDispatchQueueSpecificKey, (__bridge void *)self, NULL);
        _openFlags = openFlags;
    }
    
    return self;
}

- (instancetype)initWithPath:(NSString*)aPath flags:(int)openFlags {
    return [self initWithPath:aPath flags:openFlags vfs:nil];
}

- (instancetype)initWithPath:(NSString*)aPath {
    
    // default flags for sqlite3_open
    return [self initWithPath:aPath flags:SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE vfs:nil];
}

- (instancetype)init {
    return [self initWithPath:nil];
}

    
- (void)dealloc {
    
    YDFMDBRelease(_db);
    YDFMDBRelease(_path);
    
    if (_queue) {
        YDFMDBDispatchQueueRelease(_queue);
        _queue = 0x00;
    }
#if ! __has_feature(objc_arc)
    [super dealloc];
#endif
}

- (void)close {
    YDFMDBRetain(self);
    dispatch_sync(_queue, ^() {
        [self->_db close];
        YDFMDBRelease(_db);
        self->_db = 0x00;
    });
    YDFMDBRelease(self);
}

- (YDFMDatabase*)database {
    if (!_db) {
        _db = YDFMDBReturnRetained([YDFMDatabase databaseWithPath:_path]);
        
#if SQLITE_VERSION_NUMBER >= 3005000
        BOOL success = [_db openWithFlags:_openFlags];
#else
        BOOL success = [_db open];
#endif
        if (!success) {
            NSLog(@"YDFMDatabaseQueue could not reopen database for path %@", _path);
            YDFMDBRelease(_db);
            _db  = 0x00;
            return 0x00;
        }
    }
    
    return _db;
}

- (void)inDatabase:(void (^)(YDFMDatabase *db))block {
    /* Get the currently executing queue (which should probably be nil, but in theory could be another DB queue
     * and then check it against self to make sure we're not about to deadlock. */
    YDFMDatabaseQueue *currentSyncQueue = (__bridge id)dispatch_get_specific(kDispatchQueueSpecificKey);
    assert(currentSyncQueue != self && "inDatabase: was called reentrantly on the same queue, which would lead to a deadlock");
    
    YDFMDBRetain(self);
    
    dispatch_sync(_queue, ^() {
        
        YDFMDatabase *db = [self database];
        block(db);
        
        if ([db hasOpenResultSets]) {
            NSLog(@"Warning: there is at least one open result set around after performing [YDFMDatabaseQueue inDatabase:]");
            
#if defined(DEBUG) && DEBUG
            NSSet *openSetCopy = YDFMDBReturnAutoreleased([[db valueForKey:@"_openResultSets"] copy]);
            for (NSValue *rsInWrappedInATastyValueMeal in openSetCopy) {
                YDFMResultSet *rs = (YDFMResultSet *)[rsInWrappedInATastyValueMeal pointerValue];
                NSLog(@"query: '%@'", [rs query]);
            }
#endif
        }
    });
    
    YDFMDBRelease(self);
}


- (void)beginTransaction:(BOOL)useDeferred withBlock:(void (^)(YDFMDatabase *db, BOOL *rollback))block {
    YDFMDBRetain(self);
    dispatch_sync(_queue, ^() { 
        
        BOOL shouldRollback = NO;
        
        if (useDeferred) {
            [[self database] beginDeferredTransaction];
        }
        else {
            [[self database] beginTransaction];
        }
        
        block([self database], &shouldRollback);
        
        if (shouldRollback) {
            [[self database] rollback];
        }
        else {
            [[self database] commit];
        }
    });
    
    YDFMDBRelease(self);
}

- (void)inDeferredTransaction:(void (^)(YDFMDatabase *db, BOOL *rollback))block {
    [self beginTransaction:YES withBlock:block];
}

- (void)inTransaction:(void (^)(YDFMDatabase *db, BOOL *rollback))block {
    [self beginTransaction:NO withBlock:block];
}

- (NSError*)inSavePoint:(void (^)(YDFMDatabase *db, BOOL *rollback))block {
#if SQLITE_VERSION_NUMBER >= 3007000
    static unsigned long savePointIdx = 0;
    __block NSError *err = 0x00;
    YDFMDBRetain(self);
    dispatch_sync(_queue, ^() { 
        
        NSString *name = [NSString stringWithFormat:@"savePoint%ld", savePointIdx++];
        
        BOOL shouldRollback = NO;
        
        if ([[self database] startSavePointWithName:name error:&err]) {
            
            block([self database], &shouldRollback);
            
            if (shouldRollback) {
                // We need to rollback and release this savepoint to remove it
                [[self database] rollbackToSavePointWithName:name error:&err];
            }
            [[self database] releaseSavePointWithName:name error:&err];
            
        }
    });
    YDFMDBRelease(self);
    return err;
#else
    NSString *errorMessage = NSLocalizedString(@"Save point functions require SQLite 3.7", nil);
    if (self.logsErrors) NSLog(@"%@", errorMessage);
    return [NSError errorWithDomain:@"YDFMDatabase" code:0 userInfo:@{NSLocalizedDescriptionKey : errorMessage}];
#endif
}

@end
