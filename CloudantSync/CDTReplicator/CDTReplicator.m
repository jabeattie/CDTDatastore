//
//  CDTReplicator.m
//
//
//  Created by Michael Rhodes on 10/12/2013.
//  Copyright (c) 2013 Cloudant. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import "CDTReplicator.h"

#import "CDTReplicatorFactory.h"
#import "CDTDocumentRevision.h"
#import "CDTPullReplication.h"
#import "CDTPushReplication.h"
#import "CDTLogging.h"
#import "CDTDatastoreManager.h"
#import "CDTDatastore.h"

#import "TD_Revision.h"
#import "TD_Database.h"
#import "TD_Body.h"
#import "TDPusher.h"
#import "TDPuller.h"
#import "TD_DatabaseManager.h"
#import "TDStatus.h"
#import "CDTSessionCookieInterceptor.h"

const NSString *CDTReplicatorLog = @"CDTReplicator";
static NSString *const CDTReplicatorErrorDomain = @"CDTReplicatorErrorDomain";

@interface CDTReplicator ()

@property (nonatomic, strong) TD_DatabaseManager *dbManager;
@property (nonatomic, strong) TDReplicator *tdReplicator;
@property (nonatomic, copy) CDTAbstractReplication *cdtReplication;
// private readwrite properties
// the state property should be protected from multiple threads
@property (nonatomic, readwrite) CDTReplicatorState state;
@property (nonatomic, readwrite) NSInteger changesProcessed;
@property (nonatomic, readwrite) NSInteger changesTotal;
@property (nonatomic, readwrite) NSError *error;
@property (nonatomic, nullable, readwrite) CDTReplicator* retainedSelf;

@property (nonatomic, copy) CDTFilterBlock pushFilter;
@property (nonatomic) BOOL started;

@end
/*
    The CDTReplicator class is "fire and forget". This is so that an application
    can choose not to maintain a reference to an instance of CDTReplicator
    without the instance being immediately deallocated (and so failing to complete
    its replication).

    This is implemented by each instance retaining itself by assigning to its
    own retainedSelf property when replication is started. Care must be taken to ensure
    that this extra retain is released when the replication is complete.

    This is implemented by retaining and releasing at the points noted in
    the lifecycle table below:

     |----------------------------+------------+--------------------|
     | Method                     | State(s)   | Action(s)          |
     |----------------------------+------------+--------------------|
     | -startWithTaskGroup:error: | .Started   | start TDReplicator |
     |                            |            | retain self        |
     |                            |            | return             |
     |----------------------------+------------+--------------------|
     | -stop                      | .Stopping  | stop TDReplicator  |
     |                            |            | return             |
     |----------------------------+------------+--------------------|
     | -replicatorStopped         | .Stopped   | release self       |
     |                            | .Completed | return             |
     |                            | .Error     |                    |
     |----------------------------+------------+--------------------|


    The replicator **must only** release itself when the TDReplicator has stopped, which
   CDTReplicator
    is notified of via NSNotificationCenter, doing so before the replicator has been stopped
   **will**
    cause issues, the main one being incomplete replication, which if the checkpoint document hasn't
    been written means that the replicator will need to start again reducing performance. The
   datastore
    will also be in a unexpected state, for example documents may be missing from the local replica.
    User applications may be affected if they are waiting for state notifications to be received.
 */
@implementation CDTReplicator

+ (NSString *)stringForReplicatorState:(CDTReplicatorState)state
{
    switch (state) {
        case CDTReplicatorStatePending:
            return @"CDTReplicatorStatePending";
        case CDTReplicatorStateStarted:
            return @"CDTReplicatorStateStarted";
        case CDTReplicatorStateStopped:
            return @"CDTReplicatorStateStopped";
        case CDTReplicatorStateStopping:
            return @"CDTReplicatorStateStopping";
        case CDTReplicatorStateComplete:
            return @"CDTReplicatorStateComplete";
        case CDTReplicatorStateError:
            return @"CDTReplicatorStateError";
    }
}

#pragma mark Initialise

- (id)initWithTDDatabaseManager:(TD_DatabaseManager *)dbManager
                      replication:(CDTAbstractReplication *)replication
            sessionConfigDelegate:(NSObject<CDTNSURLSessionConfigurationDelegate> *)delegate
                            error:(NSError *__autoreleasing *)error
{
    if (dbManager == nil || replication == nil) {
        return nil;
    }

    self = [super init];
    if (self) {
        _dbManager = dbManager;
        _cdtReplication = [replication copy];

        if (![CDTAbstractReplication validateOptionalHeaders:_cdtReplication.optionalHeaders error:error]) {
            return nil;
        }

        _state = CDTReplicatorStatePending;
        _started = NO;
        _sessionConfigDelegate = delegate;
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSString*) description
{
    NSString *replicationType;
    NSString *source;
    NSString *target;
    
    if ( self.tdReplicator.isPush ) {
        replicationType = @"push" ;
        source = self.tdReplicator.db.name;
        target = TDCleanURLtoString(self.tdReplicator.remote);
        
    }
    else {
        replicationType = @"pull" ;
        source = TDCleanURLtoString(self.tdReplicator.remote);
        target = self.tdReplicator.db.name;
    }
    
    NSString *fullinfo = [NSString stringWithFormat: @"CDTReplicator %@, source: %@, target: %@ "
                          @"filter name: %@, filter parameters %@, unique replication session "
                          @"ID: %@", replicationType, source, target, self.tdReplicator.filterName,
                          self.tdReplicator.filterParameters, self.tdReplicator.sessionID];
    
    return fullinfo;
}


#pragma mark Lifecycle
- (BOOL)startWithError:(NSError *__autoreleasing *)error {
    return [self startWithTaskGroup:nil error:error];
}

- (BOOL)startWithTaskGroup:(dispatch_group_t)taskGroup error:(NSError *__autoreleasing *)error;
{
    @synchronized(self)
    {
        // check both self.started and self.state. While unlikely, it is possible for -stop to
        // be called before -startWithTaskGroup:error:. If -stop is called first on a particular
        // instance, the resulting state will be 'stopped' and the object can no longer be started
        // at that point.
        if (self.started || self.state != CDTReplicatorStatePending) {
            CDTLogInfo(CDTREPLICATION_LOG_CONTEXT,
                       @"-startWithTaskGroup:error: CDTReplicator can only be started "
                       @"once and only from its initial state, CDTReplicatorStatePending. "
                       @"Current State: %@",
                       [CDTReplicator stringForReplicatorState:self.state]);

            if (error) {
                NSDictionary *userInfo = @{
                    NSLocalizedDescriptionKey : NSLocalizedString(@"Data sync failed.", nil)
                };
                *error = [NSError errorWithDomain:CDTReplicatorErrorDomain
                                             code:CDTReplicatorErrorAlreadyStarted
                                         userInfo:userInfo];
            }
            // do not change self.state or set self.error here. This is a non-fatal error since
            // the caller has previously called -startWithTaskGroup:error:.

            return NO;
        }

        self.started = YES;
        
        // In order for the replicator to be "fire and forget" we need to create a retain cycle,
        // the retain cycle needs to be ended when the replicator stops, whether that is from a
        // successful run or not. The point where this should be released is in the
        // -replicatorStopped: method.
        self.retainedSelf = self;

        // doing this inside @synchronized lets us be certain that self.tdReplicator is either
        // created or nil throughout the rest of the code (especially in -stop)
        NSError *localError;
        self.tdReplicator =
            [self buildTDReplicatorFromConfiguration:&localError];

        // Pass the CDTNSURLSessionConfigurationDelegate onto the TDReplicator so that the
        // NSURLSession can be custom configured.
        self.tdReplicator.sessionConfigDelegate = self.sessionConfigDelegate;

        if (!self.tdReplicator) {
            self.state = CDTReplicatorStateError;

            // report the error to the Log
            CDTLogWarn(CDTREPLICATION_LOG_CONTEXT, @"CDTReplicator -start: Unable to instantiate "
                       @"TDReplicator. TD Error: %@ Current State: %@",
                       localError, [CDTReplicator stringForReplicatorState:self.state]);

            if (error) {
                // build a CDT error
                NSDictionary *userInfo = @{
                    NSLocalizedDescriptionKey : NSLocalizedString(@"Data sync failed.", nil)
                };
                *error = [NSError errorWithDomain:CDTReplicatorErrorDomain
                                             code:CDTReplicatorErrorTDReplicatorNil
                                         userInfo:userInfo];
            }
            return NO;
        }
    }

    // create TD_FilterBlock that wraps the CDTFilterBlock and set the TDPusher.filter property.
    if ([self.cdtReplication isKindOfClass:[CDTPushReplication class]]) {
        CDTPushReplication *pushRep = (CDTPushReplication *)self.cdtReplication;
        if (pushRep.filter) {
            TDPusher *tdpusher = (TDPusher *)self.tdReplicator;
            CDTFilterBlock cdtfilter = [pushRep.filter copy];

            tdpusher.filter = ^(TD_Revision *rev, NSDictionary *params) {
                return cdtfilter([[CDTDocumentRevision alloc] initWithDocId:rev.docID
                                                                 revisionId:rev.revID
                                                                       body:rev.body.properties
                                                                    deleted:rev.deleted
                                                                attachments:@{}
                                                                   sequence:rev.sequence],
                                 params);
            };
        }
    }

    self.changesTotal = self.changesProcessed = 0;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(replicatorStopped:)
                                                 name:TDReplicatorStoppedNotification
                                               object:self.tdReplicator];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(replicatorProgressChanged:)
                                                 name:TDReplicatorProgressChangedNotification
                                               object:self.tdReplicator];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(replicatorStarted:)
                                                 name:TDReplicatorStartedNotification
                                               object:self.tdReplicator];

    [self.tdReplicator startWithTaskGroup:taskGroup];
    
    CDTLogInfo(CDTREPLICATION_LOG_CONTEXT, @"start: Replicator starting %@, sessionID %@",
          [self.tdReplicator class], self.tdReplicator.sessionID);

    return YES;
}

/**
 Builds a TDReplicator object from a CDTPush/PullReplication configuration.
 */
- (TDReplicator *)buildTDReplicatorFromConfiguration:(NSError *__autoreleasing *)error
{
    BOOL push = NO;
    CDTDatastore *db;
    NSURL *remote;
    BOOL continuous = NO;  // we don't support continuous
    if ([self.cdtReplication isKindOfClass:[CDTPullReplication class]]) {
        push = NO;
        CDTPullReplication *shadowConfig = (CDTPullReplication *)self.cdtReplication;
        db = shadowConfig.target;
        remote = shadowConfig.source;
    } else if ([self.cdtReplication isKindOfClass:[CDTPushReplication class]]) {
        push = YES;
        CDTPushReplication *shadowConfig = (CDTPushReplication *)self.cdtReplication;
        db = shadowConfig.source;
        remote = shadowConfig.target;
    }
    
    NSMutableArray<id<CDTHTTPInterceptor>>* interceptors = [self.cdtReplication.httpInterceptors mutableCopy];
    if (self.cdtReplication.username && self.cdtReplication.password) {
        CDTSessionCookieInterceptor* cookieInterceptor = [[CDTSessionCookieInterceptor alloc] initWithUsername:self.cdtReplication.username
                                                                                                      password: self.cdtReplication.password];
        [interceptors addObject:cookieInterceptor];
    }
    
    TDReplicator *repl = [[TDReplicator alloc] initWithDB:db.database remote:remote push:push continuous:continuous
                                             interceptors:interceptors];
    if (!repl) {
        if (error) {
            NSString *msg = [NSString
                             stringWithFormat:@"Could not initialise replicator object between %@ and %@.",
                             db.name, [remote absoluteString]];
            NSDictionary *userInfo = @{NSLocalizedDescriptionKey : NSLocalizedString(msg, nil)};
            *error = [NSError errorWithDomain:CDTReplicationErrorDomain
                                         code:CDTReplicationErrorUndefinedSource
                                     userInfo:userInfo];
        }
        return nil;
    }
    
    //Set default value for reset to NO
    //More details: http://docs.couchdb.org/en/latest/query-server/protocol.html
    repl.reset = NO;
    //Cloudant's default value is no heartbeat
    //More details: https://console.bluemix.net/docs/services/Cloudant/api/replication.html#replication
    repl.heartbeat = nil;
    
    // Headers are validated before being put in properties
    repl.requestHeaders = self.cdtReplication.optionalHeaders;
    
    // Push and pull replications can have filters assigned.
    if (!push) {
        CDTPullReplication *shadowConfig = (CDTPullReplication *)self.cdtReplication;
        repl.filterName = shadowConfig.filter;
        repl.filterParameters = shadowConfig.filterParams;
    } else {
        CDTPushReplication *shadowConfig = (CDTPushReplication *)self.cdtReplication;
        ((TDPusher *)repl).createTarget = NO;
        repl.filterParameters = shadowConfig.filterParams;
    }

    return repl;
}

- (BOOL)stop
{
    CDTReplicatorState oldstate = self.state;
    BOOL informDelegate = YES;
    BOOL stopSuccessful = YES;

    @synchronized(self)
    {
        // can only stop once. If state == 'stopped', 'stopping', 'complete', or 'error'
        // then -stop has either already been called, or the replicator stopped due to
        // completion or error. This is the default case below.

        switch (self.state) {
            case CDTReplicatorStatePending:

                if (self.started) {
                    //-startWithTaskGroup:error: was called and self.tdReplicator was successfully
                    //instantiated (otherwise state == 'error')
                    if ([self.tdReplicator cancelIfNotStarted]) {
                        self.state = CDTReplicatorStateStopped;
                    } else {
                        stopSuccessful = NO;
                    }
                } else {
                    self.state = CDTReplicatorStateStopped;
                }
                break;

            case CDTReplicatorStateStarted:
                self.state = CDTReplicatorStateStopping;
                break;

            // we've already stopped or are about to.
            case CDTReplicatorStateStopped:
            case CDTReplicatorStateStopping:
            case CDTReplicatorStateComplete:
            case CDTReplicatorStateError:
                informDelegate = NO;
                break;
        }
    }

    if (informDelegate) {
        [self recordProgressAndInformDelegateFromOldState:oldstate];
    }

    if (oldstate == CDTReplicatorStateStarted && self.state == CDTReplicatorStateStopping) {
        // self.tdReplicator -stop eventually notifies self.replicatorStopped.
        [self.tdReplicator stop];
    }

    return stopSuccessful;
}

#pragma mark Methods that may be called by TD_Replicator notifications

// Notified that a TDReplicator has stopped:
- (void)replicatorStopped:(NSNotification *)n
{
    // As NSNotificationCenter only has weak references, it appears possible
    // for this instance to be deallocated during the call if we don't take
    // a strong reference.
    CDTReplicator *strongSelf = self;
    if (!strongSelf) {
        return;
    }

    TDReplicator *repl = n.object;

    CDTLogInfo(CDTREPLICATION_LOG_CONTEXT,
               @"replicatorStopped: %@. type: %@ sessionId: %@ CDTstate: %@", n.name, [repl class],
               repl.sessionID, [CDTReplicator stringForReplicatorState:self.state]);

    CDTReplicatorState oldState = strongSelf.state;

    @synchronized(strongSelf)
    {  // lock out other processes from changing state
        switch (strongSelf.state) {
            case CDTReplicatorStatePending:
            case CDTReplicatorStateStopping:

                if (strongSelf.tdReplicator.error) {
                    strongSelf.state = CDTReplicatorStateError;
                    // copy underlying error pointer
                    if (strongSelf.error == nil) {
                        strongSelf.error = strongSelf.tdReplicator.error;
                    }
                } else {
                    strongSelf.state = CDTReplicatorStateStopped;
                }

                break;

            case CDTReplicatorStateStarted:

                if (strongSelf.tdReplicator.error) {
                    strongSelf.state = CDTReplicatorStateError;
                    // copy underlying error pointer
                    if (strongSelf.error == nil) {
                        strongSelf.error = strongSelf.tdReplicator.error;
                    }
                } else {
                    strongSelf.state = CDTReplicatorStateComplete;
                }

            // do nothing if the state is already 'complete' or 'error'.
            default:
                break;
        }
    }

    [strongSelf recordProgressAndInformDelegateFromOldState:oldState];

    [[NSNotificationCenter defaultCenter] removeObserver:strongSelf
                                                    name:nil
                                                  object:strongSelf.tdReplicator];

    // Break the retain cycle created in -startWithTaskGroup:error,
    // it is now safe to deallocate this instance in the "fire and forget"
    // use case
    strongSelf.retainedSelf = nil;
}

// Notified that a TDReplicator has started:
- (void)replicatorStarted:(NSNotification *)n
{
    // As NSNotificationCenter only has weak references, it appears possible
    // for this instance to be deallocated during the call if we don't take
    // a strong reference.
    CDTReplicator *strongSelf = self;
    if (!strongSelf) {
        return;
    }

    TDReplicator *repl = n.object;

    CDTLogInfo(CDTREPLICATION_LOG_CONTEXT, @"replicatorStarted: %@ type: %@ sessionId: %@", n.name,
               [repl class], repl.sessionID);

    CDTReplicatorState oldState = strongSelf.state;
    @synchronized(strongSelf) {  // lock out other processes from changing state. strongSelf.state = CDTReplicatorStateStarted; }

        id<CDTReplicatorDelegate> delegate = strongSelf.delegate;

        BOOL stateChanged = (oldState != strongSelf.state);
        if (stateChanged && [delegate respondsToSelector:@selector(replicatorDidChangeState:)]) {
            [delegate replicatorDidChangeState:strongSelf];
        }
    }
}

/*
 * Called when progress has been reported by the TDReplicator.
 */
- (void)replicatorProgressChanged:(NSNotification *)n
{
    // As NSNotificationCenter only has weak references, it appears possible
    // for this instance to be deallocated during the call if we don't take
    // a strong reference.
    CDTReplicator *strongSelf = self;
    if (!strongSelf) {
        return;
    }

    CDTReplicatorState oldState = strongSelf.state;

    @synchronized(strongSelf)
    {
        if (strongSelf.tdReplicator.running) {
            strongSelf.state = CDTReplicatorStateStarted;
        } else if (self.tdReplicator.error) {
            strongSelf.state = CDTReplicatorStateError;
            // copy underlying error pointer
            if (strongSelf.error == nil) {
                strongSelf.error = strongSelf.tdReplicator.error;
            }
        } else {
            strongSelf.state = CDTReplicatorStateComplete;
        }
    }

    [strongSelf recordProgressAndInformDelegateFromOldState:oldState];
}

#pragma mark Internal methods

- (void)recordProgressAndInformDelegateFromOldState:(CDTReplicatorState)oldState
{
    BOOL progressChanged = [self updateProgress];
    BOOL stateChanged = (oldState != self.state);

    // Lots of possible delegate messages at this point
    id<CDTReplicatorDelegate> delegate = self.delegate;

    if (progressChanged && [delegate respondsToSelector:@selector(replicatorDidChangeProgress:)]) {
        [delegate replicatorDidChangeProgress:self];
    }

    if (stateChanged && [delegate respondsToSelector:@selector(replicatorDidChangeState:)]) {
        [delegate replicatorDidChangeState:self];
    }

    // We're completing this time if we're transitioning from an active state into an inactive
    // non-error state.
    BOOL completingTransition = (stateChanged && self.state != CDTReplicatorStateError &&
                                 [self isActiveState:oldState] && ![self isActiveState:self.state]);
    if (completingTransition && [delegate respondsToSelector:@selector(replicatorDidComplete:)]) {
        [delegate replicatorDidComplete:self];
    }

    // We've errored if we're transitioning from an active state into an error state.
    BOOL erroringTransition =
        (stateChanged && self.state == CDTReplicatorStateError && [self isActiveState:oldState]);
    if (erroringTransition && [delegate respondsToSelector:@selector(replicatorDidError:info:)]) {
        [delegate replicatorDidError:self info:self.error];
    }
}

- (BOOL)updateProgress
{
    BOOL progressChanged = NO;
    if (self.changesProcessed != self.tdReplicator.changesProcessed ||
        self.changesTotal != self.tdReplicator.changesTotal) {
        self.changesProcessed = self.tdReplicator.changesProcessed;
        self.changesTotal = self.tdReplicator.changesTotal;
        progressChanged = YES;
    }
    return progressChanged;
}

#pragma mark Status information

- (BOOL)isActive { return [self isActiveState:self.state]; }

/*
 * Returns whether `state` is an active state for the replicator.
 */
- (BOOL)isActiveState:(CDTReplicatorState)state
{
    return state == CDTReplicatorStatePending || state == CDTReplicatorStateStarted ||
           state == CDTReplicatorStateStopping;
}

- (NSError *)error
{
    // this protects against reporting an error if the replication is still ongoing.
    // according to the TDReplicator documentation, it is possible for TDReplicator to encounter
    // a non-fatal error, which we do not want to report unless the replicator gives up and quits.
    if ([self isActive]) {
        return nil;
    }

    if (!_error && self.tdReplicator.error) {
        // convert TD-level replication errors to CDT level
        NSDictionary *userInfo;

        if ([self.tdReplicator.error.domain isEqualToString:TDInternalErrorDomain]) {
            switch (self.tdReplicator.error.code) {
                
                case TDReplicatorErrorLocalDatabaseDeleted:
                    userInfo =
                    @{NSLocalizedDescriptionKey: NSLocalizedString(@"Data sync failed.", nil)};
                    self.error = [NSError errorWithDomain:CDTReplicatorErrorDomain
                                                     code:CDTReplicatorErrorLocalDatabaseDeleted
                                                 userInfo:userInfo];
                    break;

                default:
                    // just point directly to tdReplicator error if we don't have a conversion
                    self.error = self.tdReplicator.error;
                    break;
            }

        } else {
            self.error = self.tdReplicator.error;
        }
    }

    return _error;
}

-(BOOL) threadExecuting;
{
    return self.tdReplicator.threadExecuting;
}
-(BOOL) threadFinished
{
    return self.tdReplicator.threadFinished;
}
-(BOOL) threadCanceled
{
    return self.tdReplicator.threadCanceled;
}

@end
