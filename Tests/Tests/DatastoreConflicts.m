//
//  DatastoreConflicts.m
//  CloudantSync
//
//  Created by Adam Cox on 2014/02/27.
//  Copyright (c) 2014 Cloudant. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import <SenTestingKit/SenTestingKit.h>
#import <Foundation/Foundation.h>

#import "CloudantSyncTests.h"
#import "DatastoreConflictResolvers.h"

#import "CDTDatastoreManager.h"
#import "CDTDatastore+Conflicts.h"
#import "CDTDatastore+Attachments.h"
#import "CDTDatastore+Internal.h"
#import "CDTDocumentBody.h"
#import "CDTDocumentRevision.h"
#import "CDTConflictResolver.h"

#import "FMDatabaseAdditions.h"
#import "FMDatabaseQueue.h"
#import "TDJSON.h"
#import "FMResultSet.h"
#import "TD_Database+Insertion.h"
#import "TD_Revision.h"

#import "TD_Body.h"
#import "CollectionUtils.h"
#import "DBQueryUtils.h"
#import "CDTAttachment.h"
#import <MRDatabaseContentChecker.h>

@interface DatastoreConflicts : CloudantSyncTests
@property (nonatomic,strong) CDTDatastore *datastore;
@property (nonatomic,strong) DBQueryUtils *dbutil;
@end


@implementation DatastoreConflicts

- (void)setUp
{
    [super setUp];
    
    NSError *error;
    self.datastore = [self.factory datastoreNamed:@"conflicttests" error:&error];
    self.dbutil = [[DBQueryUtils alloc] initWithDbPath:[self pathForDBName:self.datastore.name]];
    
    STAssertNotNil(self.datastore, @"datastore is nil");
}

- (void)tearDown
{
    // Tear-down code here.
    
    self.datastore = nil;
    
    [super tearDown];
}

/**
 creates a new document with the following document tree
 
    ----- 2-c (seq 5, deleted = 1)
  /
 1-a (seq 1) --- 2-a (seq 2) --- 3-a (seq 3)
  \
    ---- 2-b (seq 4)
 
 There are only two conflicting revisions, 3-a and 2-b, because 2-c is deleted.
 
 For each revision, the content of the JSON body (the NSDictionary returned by CDTDocumentRevision
 -documentAsDicitionary), will be {fooN.x:barN.x} where N = 1,2,3 and x = a, b, c.
 For example, the JSON body for 1-a is {foo1.a:bar1.a}, and the body for 2-c is {foo2.c:bar2.c}.
 This can be used to check for the content of each revision in the tests.
 
 If withAttachment is YES, an image file is attached to revision 2-a. Note that due to the
 implementation of attaching data to documents, the document body of 2-a will be {foo1.a:bar1.a}.
 
 */
-(void) addConflictingDocumentWithId:(NSString *)anId
                         toDatastore:(CDTDatastore*)datastore
                      withAttachment:(BOOL)attach
{
    
    
    STAssertNotNil(anId, @"ID string is nil");
    
    NSError *error;
    CDTDocumentBody *body = [[CDTDocumentBody alloc] initWithDictionary:@{@"foo1.a":@"bar1.a"}];
    CDTDocumentRevision *rev1;
    rev1 = [datastore createDocumentWithId:anId
                                      body:body
                                     error:&error];
    
    error = nil;
    CDTDocumentRevision *rev2a = nil;
    if (attach) {
        
        NSBundle *bundle = [NSBundle bundleForClass:[self class]];
        NSString *imagePath = [bundle pathForResource:@"bonsai-boston" ofType:@"jpg"];
        NSData *data = [NSData dataWithContentsOfFile:imagePath];
        
        CDTAttachment *attachment = [[CDTUnsavedDataAttachment alloc] initWithData:data
                                                                              name:@"bonsai-boston"
                                                                              type:@"image/jpg"];
        
        rev2a = [self.datastore updateAttachments:@[attachment]
                                           forRev:rev1
                                            error:nil];
        
    }
    else{
        body = [[CDTDocumentBody alloc] initWithDictionary:@{@"foo2.a":@"bar2.a"}];
        rev2a = [datastore updateDocumentWithId:rev1.docId
                                        prevRev:rev1.revId
                                           body:body
                                          error:&error];
    }
    
    error = nil;
    body = [[CDTDocumentBody alloc] initWithDictionary:@{@"foo3.a":@"bar3.a"}];
    [datastore updateDocumentWithId:rev2a.docId
                            prevRev:rev2a.revId
                               body:body
                              error:&error];
    
    error = nil;
    TD_Body *tdbody = [[TD_Body alloc] initWithProperties:@{@"foo2.b":@"bar2.b"}];
    TD_Database *tdstore = datastore.database;
    TD_Revision *revision = [[TD_Revision alloc] initWithDocID:rev1.docId
                                                         revID:nil
                                                       deleted:NO];
    revision.body = tdbody;
    
    TDStatus status;
    TD_Revision *td_rev = [tdstore putRevision:revision
                                prevRevisionID:rev1.revId
                                 allowConflict:YES
                                        status:&status];
    if (TDStatusIsError(status)) {
        error = TDStatusToNSError(status, nil);
    }
    STAssertNil(error, @"Error creating conflict %@", error);
    CDTDocumentRevision *rev2b = [[CDTDocumentRevision alloc] initWithTDRevision:td_rev];
    STAssertNotNil(rev2b, @"CDTDocumentRevision object was nil");
    
    error = nil;
    tdbody = [[TD_Body alloc] initWithProperties:@{@"foo2.c":@"bar2.c"}];
    revision = [[TD_Revision alloc] initWithDocID:rev1.docId
                                            revID:nil
                                          deleted:YES];
    revision.body = tdbody;
    
    td_rev = [tdstore putRevision:revision
                   prevRevisionID:rev1.revId
                    allowConflict:YES
                           status:&status];
    if (TDStatusIsError(status)) {
        error = TDStatusToNSError(status, nil);
    }
    STAssertNil(error, @"Error creating conflict %@", error);
    CDTDocumentRevision *rev2c = [[CDTDocumentRevision alloc] initWithTDRevision:td_rev];
    STAssertNotNil(rev2c, @"CDTDocumentRevision object was nil");
    
    
}

/**
 creates a new document with the following document tree
 
    ----- 2-c (seq 5, deleted = 1)
  /
 1-a (seq 1) --- 2-a (seq 2) --- 3-a (seq 3)
  \
    ---- 2-b (seq 4)
 
 There are only two conflicting revisions, 3-a and 2-b, because 2-c is deleted.
 
 For each revision, the content of the JSON body is {fooN.x:barN.x} where
 N = 1,2,3 and x = a, b, c. For example, the JSON body for 1-a is {foo1.a:bar1.a},
 and the body for 2-c is {foo2.c:bar2.c}. This can be used to check for the
 content of each revision in the tests.
 */
-(void) addConflictingDocumentWithId:(NSString *)anId
                         toDatastore:(CDTDatastore*)datastore
{
    
    [self addConflictingDocumentWithId:anId toDatastore:datastore withAttachment:NO];
}



- (CDTDocumentRevision*)addNonConflictingDocumentWithBody:(NSDictionary*)body
                                              toDatastore:(CDTDatastore*)datastore
{
    NSError *error;
    CDTDocumentBody *docBody = [[CDTDocumentBody alloc] initWithDictionary:body];
    CDTDocumentRevision *rev = [self.datastore createDocumentWithBody:docBody error:&error];
    
    STAssertNil(error, @"Error creating document");
    STAssertNotNil(rev, @"CDTDocumentRevision object was nil");
    
    return rev;
}

-(void)testCreateConflict
{
    [self addConflictingDocumentWithId:@"doc0" toDatastore:self.datastore];
}

-(void)testCreateConflictWithAttachment
{
    [self addConflictingDocumentWithId:@"doc0" toDatastore:self.datastore withAttachment:YES];
}

-(void)testFindAllConflicts
{
    [self addConflictingDocumentWithId:@"doc0" toDatastore:self.datastore];
    
    __block NSArray *revsArray;
    [self.datastore.database inTransaction:^TDStatus(FMDatabase *db) {
        revsArray = [self.datastore activeRevisionsForDocumentId:@"doc0" database:db];
        return kTDStatusOK;
    }];
    
    for (CDTDocumentRevision *aRev in revsArray) {
        
        switch ([TD_Revision generationFromRevID:aRev.revId]) {
            case 2:
                STAssertEqualObjects(aRev.documentAsDictionary,
                                     @{@"foo2.b":@"bar2.b"},
                                     @"unexpected document: %@", aRev.documentAsDictionary);
                break;
                
            case 3:
                STAssertEqualObjects(aRev.documentAsDictionary,
                                     @{@"foo3.a":@"bar3.a"},
                                     @"unexpected document: %@", aRev.documentAsDictionary);
                break;
                
            default:
                STFail(@"invalid revision generation: %@", aRev.revId);
                break;
        }
        
    }
}


-(void)testCreateMultipleConflictingDocuments
{
    //add a non-conflicting document
    CDTDocumentRevision *rev = [self addNonConflictingDocumentWithBody:@{@"conflict":@"no way!"}
                                                           toDatastore:self.datastore];
    
    NSSet *setOfConflictedDocIds = [NSSet setWithArray:@[@"doc0", @"doc1", @"doc2", @"doc3"]];
    for (NSString *docId in setOfConflictedDocIds) {
        [self addConflictingDocumentWithId:docId toDatastore:self.datastore];
    }
    
    //add another non-conflicting document
    CDTDocumentRevision *rev2 = [self addNonConflictingDocumentWithBody:@{@"conflict":@"no way!"}
                                                            toDatastore:self.datastore];

    
    NSSet *foundConflictedDocIds = [NSSet setWithArray:[self.datastore getConflictedDocumentIds]];
    STAssertTrue([foundConflictedDocIds isEqualToSet:setOfConflictedDocIds],
                 @"foundSet: %@", foundConflictedDocIds);
    
    STAssertFalse([foundConflictedDocIds containsObject:rev.docId],
                  @"conflicts set (%@) contained non-conflicting doc %@",
                  foundConflictedDocIds, rev.docId );
    STAssertFalse([foundConflictedDocIds containsObject:rev2.docId],
                  @"conflicts set (%@) contained non-conflicting doc %@",
                  foundConflictedDocIds, rev2.docId );
    
}

-(void) testEnumerateConflicts
{
    //add a non-conflicting document
    [self addNonConflictingDocumentWithBody:@{@"conflict":@"no way!"} toDatastore:self.datastore];
    
    NSMutableSet *setOfConflictedDocIds = [[NSMutableSet alloc] init];
    for (unsigned int i = 0; i < 100; i++) {
        NSString *docId = [NSString stringWithFormat:@"doc%i", i];
        [setOfConflictedDocIds addObject:docId];
        [self addConflictingDocumentWithId:docId toDatastore:self.datastore];
    }
    
    //add another non-conflicting document
    [self addNonConflictingDocumentWithBody:@{@"conflict":@"no way!"} toDatastore:self.datastore];
    
    NSSet *foundConflictedDocIds = [NSSet setWithArray:[self.datastore getConflictedDocumentIds]];

    STAssertTrue([foundConflictedDocIds isEqualToSet:setOfConflictedDocIds],
                 @"foundSet: %@", foundConflictedDocIds);
    
    //add another set of conflicted docs to test
    for (unsigned int i = 100; i < 200; i++) {
        NSString *docId = [NSString stringWithFormat:@"doc%i", i];
        [setOfConflictedDocIds addObject:docId];
        [self addConflictingDocumentWithId:docId toDatastore:self.datastore];
    }
    
    foundConflictedDocIds = [NSSet setWithArray:[self.datastore getConflictedDocumentIds]];
    
    STAssertTrue([foundConflictedDocIds isEqualToSet:setOfConflictedDocIds],
                 @"foundSet: %@", foundConflictedDocIds);
}

- (void) testResolveConflictWithBiggestRev
{
    
    [self addConflictingDocumentWithId:@"doc0" toDatastore:self.datastore];
    
    CDTTestBiggestRevResolver *myResolver = [[CDTTestBiggestRevResolver alloc] init];
    
    NSArray *conflictedDocs = [self.datastore getConflictedDocumentIds];
    STAssertEquals(conflictedDocs.count, (NSUInteger)1, @"");
    
    for (NSString *docId in conflictedDocs) {
        NSError *error;
        STAssertTrue([self.datastore resolveConflictsForDocument:docId
                                                        resolver:myResolver
                                                           error:&error],
                     @"resolve failure: %@", docId);
        STAssertNil(error, @"Error resolving document. %@", error);
    }
    
    //make sure there are no more conflicting documents
    conflictedDocs = [self.datastore getConflictedDocumentIds];
    STAssertEquals(conflictedDocs.count, (NSUInteger)0, @"");
    
    //make sure that doc0 has the proper rev and content
    //They should have rev prefixes of 3-
    NSError *error = nil;
    CDTDocumentRevision *rev = [self.datastore getDocumentWithId:@"doc0" error:&error];
    STAssertNil(error, @"Error getting document");
    STAssertNotNil(rev, @"CDTDocumentRevision object was nil");
    STAssertEquals([TD_Revision generationFromRevID:rev.revId], (unsigned)3,
                   @"Unexpected RevId: %@", rev.revId);
    STAssertTrue([[rev documentAsDictionary] isEqualToDictionary:myResolver.resolvedDocumentAsDictionary],
                 @"Unexpected document: %@", [rev documentAsDictionary]);

}

//
//commented out until it's possible to delete documents within conflict resolution framework
//
//- (void) testResolveByAnnihilation
//{
//    //add a non-conflicting document
//    [self addNonConflictingDocumentWithBody:@{@"conflict":@"no"} toDatastore:self.datastore];
//    
//    NSSet *setOfConflictedDocIds = [NSSet setWithArray:@[@"doc0", @"doc1", @"doc2", @"doc3"]];
//    for (NSString *docId in setOfConflictedDocIds) {
//        [self addConflictingDocumentWithId:docId toDatastore:self.datastore];
//    }
//    
//    //add another non-conflicting document
//    [self addNonConflictingDocumentWithBody:@{@"conflict":@"no"} toDatastore:self.datastore];
//    
//    CDTTestDeleteConflictedDocResolver *myResolver = [[CDTTestDeleteConflictedDocResolver alloc] init];
//    
//    for (NSString *docId in [self.datastore getConflictedDocumentIds]) {
//        NSError *error;
//        STAssertTrue([self.datastore resolveConflictsForDocument:docId
//                                                        resolver:myResolver
//                                                           error:&error],
//                     @"resolve failure: %@", docId);
//        STAssertNil(error, @"Error resolving document. %@", error);
//    }
//    
//    //make sure there are no more conflicting documents
//    NSArray *conflictedDocs = [self.datastore getConflictedDocumentIds];
//    STAssertEquals(conflictedDocs.count, (NSUInteger)0, @"");
//    
//    //make sure that doc0, doc1, doc2 and doc3 cannot be retrieved
//    for (NSString *docId in setOfConflictedDocIds) {
//        
//        NSError *error = nil;
//        CDTDocumentRevision *rev = [self.datastore getDocumentWithId:docId error:&error];
//        STAssertNotNil(error, @"No Error getting document");
//        STAssertEquals(error.code, (NSInteger)404, @"Error %@", error);
//        STAssertNil(rev, @"CDTDocumentRevision object was not nil even though it was deleted.");
//        
//    }
//}

- (void) testNoResolution
{
    //add a non-conflicting document
    [self addNonConflictingDocumentWithBody:@{@"conflict":@"no"} toDatastore:self.datastore];
    
    NSSet *setOfConflictedDocIds = [NSSet setWithArray:@[@"doc0", @"doc1", @"doc2", @"doc3"]];
    for (NSString *docId in setOfConflictedDocIds) {
        [self addConflictingDocumentWithId:docId toDatastore:self.datastore];
    }
    
    //add another non-conflicting document
    [self addNonConflictingDocumentWithBody:@{@"conflict":@"no"} toDatastore:self.datastore];
    
    CDTTestDoesNoResolutionResolver *myResolver = [[CDTTestDoesNoResolutionResolver alloc] init];
    
    for (NSString *docId in [self.datastore getConflictedDocumentIds]) {
        NSError *error;
        STAssertTrue([self.datastore resolveConflictsForDocument:docId
                                                        resolver:myResolver
                                                           error:&error],
                     @"resolve failure: %@", docId);
        STAssertNil(error, @"Error resolving document. %@", error);
    }
    
    //make sure there are the correct number of conflicting documents
    NSArray *conflictedDocs = [self.datastore getConflictedDocumentIds];
    STAssertEquals(conflictedDocs.count, setOfConflictedDocIds.count, @"");
    
    //make sure that doc0, doc1, doc2 and doc3 are still retrieved
    for (NSString *docId in setOfConflictedDocIds) {
        
        NSError *error = nil;
        CDTDocumentRevision *rev = [self.datastore getDocumentWithId:docId error:&error];
        STAssertNil(error, @"Error getting document");
        STAssertNotNil(rev, @"CDTDocumentRevision object was nil.");
        
    }
}

- (void) testResolveSubset
{
    //add a non-conflicting document
    [self addNonConflictingDocumentWithBody:@{@"conflict":@"no"} toDatastore:self.datastore];
    
    NSSet *setOfConflictedDocIds = [NSSet setWithArray:@[@"doc0", @"doc1", @"doc2", @"doc3"]];
    for (NSString *docId in setOfConflictedDocIds) {
        [self addConflictingDocumentWithId:docId toDatastore:self.datastore];
    }
    
    //add another non-conflicting document
    [self addNonConflictingDocumentWithBody:@{@"conflict":@"no"} toDatastore:self.datastore];
    
    NSSet* resolvedDocs = [NSSet setWithArray:@[@"doc0",@"doc1"]];
    CDTTestParticularDocBiggestResolver *myResolver = [[CDTTestParticularDocBiggestResolver alloc]
                                                       initWithDocsToResolve:resolvedDocs];
        
    for (NSString *docId in [self.datastore getConflictedDocumentIds]) {
        NSError *error;
        STAssertTrue([self.datastore resolveConflictsForDocument:docId resolver:myResolver error:&error],
                     @"resolve failure: %@", docId);
        STAssertNil(error, @"Error resolving document. %@", error);
    }
    
    //check conflicting documents
    NSArray *conflictedDocs = [self.datastore getConflictedDocumentIds];
    STAssertEquals(conflictedDocs.count, (NSUInteger)2, @"");
    
    NSSet *stillConflicted = [NSSet setWithArray:@[@"doc2", @"doc3"]];
    STAssertTrue([stillConflicted isEqualToSet:[NSSet setWithArray:conflictedDocs]],
                 @"unequal sets. expected: %@, found: %@", stillConflicted, conflictedDocs);
    
    for (NSString *docId in resolvedDocs) {
        
        NSError *error = nil;
        CDTDocumentRevision *rev = [self.datastore getDocumentWithId:docId error:&error];
        STAssertNil(error, @"Error getting document");
        STAssertNotNil(rev, @"CDTDocumentRevision object was nil");
        STAssertEquals([TD_Revision generationFromRevID:rev.revId], (unsigned)3,
                       @"Unexpected RevId: %@", rev.revId);
        STAssertTrue([[rev documentAsDictionary] isEqualToDictionary: myResolver.resolvedDocumentAsDictionary],
                     @"Unexpected document: %@", [rev documentAsDictionary]);
    }
}


- (void) testResolveConflictWithSmallestRev
{
    
    [self addConflictingDocumentWithId:@"doc0" toDatastore:self.datastore];
    
    CDTTestSmallestRevResolver *myResolver = [[CDTTestSmallestRevResolver alloc] init];
    
    NSArray *conflictedDocs = [self.datastore getConflictedDocumentIds];
    STAssertEquals(conflictedDocs.count, (NSUInteger)1, @"");
    
    for (NSString *docId in conflictedDocs) {
        NSError *error;
        STAssertTrue([self.datastore resolveConflictsForDocument:docId
                                                        resolver:myResolver
                                                           error:&error],
                     @"resolve failure: %@", docId);
        STAssertNil(error, @"Error resolving document. %@", error);
    }
    
    //make sure there are no more conflicting documents
    conflictedDocs = [self.datastore getConflictedDocumentIds];
    STAssertEquals(conflictedDocs.count, (NSUInteger)0, @"");
    
    //make sure that doc0 has the proper rev and content
    //They should have rev prefixes of 2-
    NSError *error = nil;
    CDTDocumentRevision *rev = [self.datastore getDocumentWithId:@"doc0" error:&error];
    STAssertNil(error, @"Error getting document");
    STAssertNotNil(rev, @"CDTDocumentRevision object was nil");
    STAssertEquals([TD_Revision generationFromRevID:rev.revId], (unsigned)2,
                   @"Unexpected RevId: %@", rev.revId);
    STAssertTrue([[rev documentAsDictionary] isEqualToDictionary:myResolver.resolvedDocumentAsDictionary],
                 @"Unexpected document: %@", [rev documentAsDictionary]);
    
}

- (void) testCannotResolveWithNewRevision
{
    //this test ensures that when a CDTConflictResolver returns a CDTDocumentRevision
    //that is not in the conflicts array, the resolveConflictForDocument fails appropriately
    
    [self addConflictingDocumentWithId:@"doc0" toDatastore:self.datastore];
    
    CDTTestNewRevisionResolver *myResolver = [[CDTTestNewRevisionResolver alloc] init];
    
    NSArray *conflictedDocs = [self.datastore getConflictedDocumentIds];
    STAssertEquals(conflictedDocs.count, (NSUInteger)1, @"");
    
    for (NSString *docId in conflictedDocs) {
        NSError *error;
        STAssertFalse([self.datastore resolveConflictsForDocument:docId
                                                        resolver:myResolver
                                                           error:&error],
                     @"Expected resolve to fail. %@", docId);
        NSError *expectError = TDStatusToNSErrorWithInfo(kTDStatusServerError, nil, nil);
        
        STAssertEquals(error.code, expectError.code, @"Unexpected Error %@. \n Expected %@ \n", error, expectError);
    }
    
    
    //make sure there is still a conflicting document
    conflictedDocs = [self.datastore getConflictedDocumentIds];
    STAssertEquals(conflictedDocs.count, (NSUInteger)1, @"");
    
    //make sure that doc0 still has two conflicting revsions
    __weak DatastoreConflicts  *weakSelf = self;
    [[self.dbutil queue] inDatabase:^(FMDatabase *db) {
        DatastoreConflicts *strongSelf = weakSelf;
        NSArray *revsArray = [strongSelf.datastore activeRevisionsForDocumentId:@"doc0" database:db];
        STAssertEquals(revsArray.count, (NSUInteger)2, @"");
        
    }];
    
    //The winning revision should still have a prefix of 3-
    NSError *error = nil;
    CDTDocumentRevision *rev = [self.datastore getDocumentWithId:@"doc0" error:&error];
    STAssertNil(error, @"Error getting document");
    STAssertNotNil(rev, @"CDTDocumentRevision object was nil");
    STAssertEquals([TD_Revision generationFromRevID:rev.revId], (unsigned)3,
                   @"Unexpected RevId: %@", rev.revId);
    STAssertTrue([[rev documentAsDictionary] isEqualToDictionary:@{@"foo3.a":@"bar3.a"}],
                 @"Unexpected document: %@", [rev documentAsDictionary]);
    
}

-(void) testResolveConflictWithAttachmentWithBiggestRev
{
    //this tests that the conflict resolution retains the revisions association with an attachment
    // before
    //    ----- 2-c (seq 5, deleted = 1)
    //    /
    //    1-a (seq 1) --- 2-a (seq 2, attachment here) --- 3-a (seq 3, attachment here)
    //    \
    //    ---- 2-b (seq 4)
    //
    // after
    //    ----- 2-c (seq 5, deleted = 1)
    //    /
    //    1-a (seq 1) --- 2-a (seq 2, attachment here) --- 3-a (seq 3, attachment here)
    //    \
    //    ---- 2-b (seq 4) -- 3-b(seq 6, deleted = 1)
    //
    // and then we check to ensure that 3-a has the attachment still.
    // this test made more sense when we had different behavior in conflict resolution, but
    // I suppose it's still good to ensure we're not blowing away attachments.
    
    
    //add conflicting document with attachement
    [self addConflictingDocumentWithId:@"doc0" toDatastore:self.datastore withAttachment:YES];
    
    CDTTestBiggestRevResolver *myResolver = [[CDTTestBiggestRevResolver alloc] init];
    
    for (NSString *docId in [self.datastore getConflictedDocumentIds]) {
        NSError *error;
        STAssertTrue([self.datastore resolveConflictsForDocument:docId
                                                        resolver:myResolver
                                                           error:&error],
                     @"resolve failure: %@", docId);
        STAssertNil(error, @"Error resolving document. %@", error);
    }
    
    //make sure there are no more conflicted documents
    NSArray *conflictedDocs = [self.datastore getConflictedDocumentIds];
    STAssertEquals(conflictedDocs.count, (NSUInteger)0, @"");
    
    //make sure that doc0 has the proper rev and content
    //The winning rev should be generation 3 and should have content of {foo3.a:bar3.a}
    //It should also have the bonsai-boston attached image.
    NSError *error = nil;
    CDTDocumentRevision *rev = [self.datastore getDocumentWithId:@"doc0" error:&error];
    STAssertNil(error, @"Error getting document");
    STAssertNotNil(rev, @"CDTDocumentRevision object was nil");
    STAssertEquals([TD_Revision generationFromRevID:rev.revId], (unsigned)3,
                   @"Unexpected RevId: %@", rev.revId);
    STAssertTrue([[rev documentAsDictionary] isEqualToDictionary:myResolver.resolvedDocumentAsDictionary],
                 @"Unexpected document: %@", [rev documentAsDictionary]);
    STAssertTrue([rev.attachments count] == 1,
                 @"Unexpected number of attachments. expected %d, actual %d",
                 1,
                 [rev.attachments count]);
    
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSString *imagePath = [bundle pathForResource:@"bonsai-boston" ofType:@"jpg"];
    NSData *imageData = [NSData dataWithContentsOfFile:imagePath];
    
    [self.dbutil.queue inDatabase:^(FMDatabase *db ) {
        NSArray *expectedRows = @[
                                  @[@"sequence", @"filename", @"type", @"length", @"revpos", @"encoding", @"encoded_length"],
                                  @[@2, @"bonsai-boston", @"image/jpg", @(imageData.length), @2, @0, @(imageData.length)],
                                  @[@3, @"bonsai-boston", @"image/jpg", @(imageData.length), @2, @0, @(imageData.length)]
                                  ];
        
        MRDatabaseContentChecker *dc = [[MRDatabaseContentChecker alloc] init];
        NSError *validationError;
        STAssertTrue([dc checkDatabase:db
                                 table:@"attachments"
                               hasRows:expectedRows
                                 error:&validationError],
                     [dc formattedErrors:validationError]);
    }];
    
}


- (void) testResolveConflictWithAttachmentForRev2b
{
    //this tests that the conflict resolution retains the revision associations with attachments
    // before
    //    ----- 2-c (seq 5, deleted = 1)
    //    /
    //    1-a (seq 1) --- 2-a (seq 2, attachment here) --- 3-a (seq 3, attachment here)
    //    \
    //    ---- 2-b (seq 4)
    //
    // after
    //    ----- 2-c (seq 5, deleted = 1)
    //    /
    //    1-a (seq 1) --- 2-a (seq 2, attachment here) --- 3-a (seq 3, attachment here) --- 4-b (seq 6, deleted=1)
    //    \
    //    ---- 2-b (seq 4)
    //
    // and then we check to ensure that GETing the document returns 2-b without an attachment.

    //add conflicting document with attachement
    [self addConflictingDocumentWithId:@"doc0" toDatastore:self.datastore withAttachment:YES];
    
    CDTTestSpecificJSONDocumentResolver *myResolver = [[CDTTestSpecificJSONDocumentResolver alloc]
                                                       initWithDictionary:@{@"foo2.b":@"bar2.b"}];
    
    for (NSString *docId in [self.datastore getConflictedDocumentIds]) {
        NSError *error;
        STAssertTrue([self.datastore resolveConflictsForDocument:docId
                                                        resolver:myResolver
                                                           error:&error],
                     @"resolve failure: %@", docId);
        STAssertNil(error, @"Error resolving document. %@", error);
    }
    
    
    //make sure there are no more conflicting documents
    NSArray *conflictedDocs = [self.datastore getConflictedDocumentIds];
    STAssertEquals(conflictedDocs.count, (NSUInteger)0, @"");
    
    //make sure that doc0 has the proper rev and content
    //The winning rev should be generation 2 and should have content of {foo2.b:bar2.b}
    //It should NOT have the bonsai-boston attached image.
    NSError *error = nil;
    CDTDocumentRevision *rev = [self.datastore getDocumentWithId:@"doc0" error:&error];
    STAssertNil(error, @"Error getting document");
    STAssertNotNil(rev, @"CDTDocumentRevision object was nil");
    STAssertEquals([TD_Revision generationFromRevID:rev.revId], (unsigned)2,
                   @"Unexpected RevId: %@", rev.revId);
    STAssertTrue([[rev documentAsDictionary] isEqualToDictionary:@{@"foo2.b":@"bar2.b"}],
                 @"Unexpected document: %@", [rev documentAsDictionary]);
    
    NSArray *attachments = [self.datastore attachmentsForRev:rev
                                                       error:nil];
    
    STAssertEquals((NSUInteger)0, [attachments count], @"Wrong number of attachments");
    
    
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSString *imagePath = [bundle pathForResource:@"bonsai-boston" ofType:@"jpg"];
    NSData *imageData = [NSData dataWithContentsOfFile:imagePath];
    
    [self.dbutil.queue inDatabase:^(FMDatabase *db ) {
        NSArray *expectedRows = @[
                                  @[@"sequence", @"filename", @"type", @"length", @"revpos", @"encoding", @"encoded_length"],
                                  @[@2, @"bonsai-boston", @"image/jpg", @(imageData.length), @2, @0, @(imageData.length)],
                                  @[@3, @"bonsai-boston", @"image/jpg", @(imageData.length), @2, @0, @(imageData.length)]
                                  ];
        
        MRDatabaseContentChecker *dc = [[MRDatabaseContentChecker alloc] init];
        NSError *validationError;
        STAssertTrue([dc checkDatabase:db
                                 table:@"attachments"
                               hasRows:expectedRows
                                 error:&validationError],
                     [dc formattedErrors:validationError]);
    }];

    
}



@end
