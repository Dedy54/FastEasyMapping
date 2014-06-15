// Copyright (c) 2014 Lucas Medeiros.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "FEMManagedObjectDeserializer.h"

#import <CoreData/CoreData.h>

#import "FEMManagedObjectMapping.h"
#import "FEMAttributeMapping.h"
#import "FEMTypeIntrospection.h"
#import "NSArray+FEMPropertyRepresentation.h"
#import "FEMAttributeMapping+Extension.h"
#import "FEMRelationshipMapping.h"
#import "FEMCache.h"
#import "FEMAssignmentPolicyMetadata.h"

@implementation FEMManagedObjectDeserializer

#pragma mark - Deserialization

+ (id)_deserializeObjectRepresentation:(NSDictionary *)representation usingMapping:(FEMManagedObjectMapping *)mapping context:(NSManagedObjectContext *)context {
	id object = [EMKLookupCacheGetCurrent() existingObjectForRepresentation:representation mapping:mapping];
	if (!object) {
		object = [NSEntityDescription insertNewObjectForEntityForName:mapping.entityName inManagedObjectContext:context];
	}

	[self _fillObject:object fromRepresentation:representation usingMapping:mapping];

	if ([object isInserted] && mapping.primaryKey) {
		[EMKLookupCacheGetCurrent() addExistingObject:object usingMapping:mapping];
	}

	return object;
}

+ (id)_deserializeObjectExternalRepresentation:(NSDictionary *)externalRepresentation
                                  usingMapping:(FEMManagedObjectMapping *)mapping
			                           context:(NSManagedObjectContext *)context {
	id objectRepresentation = [mapping extractRootFromExternalRepresentation:externalRepresentation];
	return [self _deserializeObjectRepresentation:objectRepresentation usingMapping:mapping context:context];
}


+ (id)deserializeObjectExternalRepresentation:(NSDictionary *)externalRepresentation
                                 usingMapping:(FEMManagedObjectMapping *)mapping
			                          context:(NSManagedObjectContext *)context {
	FEMCache *cache = [[FEMCache alloc] initWithMapping:mapping
	                                         externalRepresentation:externalRepresentation
						                                    context:context];
	EMKLookupCacheSetCurrent(cache);
	id object = [self _deserializeObjectExternalRepresentation:externalRepresentation usingMapping:mapping context:context];
	EMKLookupCacheRemoveCurrent();

	return object;
}

+ (id)_fillObject:(NSManagedObject *)object fromRepresentation:(NSDictionary *)representation usingMapping:(FEMManagedObjectMapping *)mapping {
	for (FEMAttributeMapping *attributeMapping in mapping.attributeMappings) {
		[attributeMapping mapValueToObject:object fromRepresentation:representation];
	}

	NSManagedObjectContext *context = object.managedObjectContext;
	for (FEMRelationshipMapping *relationshipMapping in mapping.relationshipMappings) {
        FEMAssignmentPolicyMetadata *metadata = [FEMAssignmentPolicyMetadata new];
        [metadata setContext:context];
        [metadata setExistingValue:[object valueForKey:relationshipMapping.property]];

        id relationshipRepresentation = [relationshipMapping extractRootFromExternalRepresentation:representation];
		if (relationshipMapping.isToMany) {
			NSArray *newValue = [self _deserializeCollectionRepresentation:relationshipRepresentation
                                                                              usingMapping:relationshipMapping.objectMapping
                                                                                   context:context];

            objc_property_t property = class_getProperty([object class], [relationshipMapping.property UTF8String]);
            [metadata setTargetValue:[newValue fem_propertyRepresentation:property]];
		} else {
            id newValue = [self _deserializeObjectRepresentation:relationshipRepresentation
                                                    usingMapping:relationshipMapping.objectMapping
                                                         context:context];
            [metadata setTargetValue:newValue];
		}

        [object setValue:relationshipMapping.assignmentPolicy(metadata) forKey:relationshipMapping.property];
	}

	return object;
}

+ (id)fillObject:(NSManagedObject *)object fromExternalRepresentation:(NSDictionary *)externalRepresentation usingMapping:(FEMManagedObjectMapping *)mapping {
	id objectRepresentation = [mapping extractRootFromExternalRepresentation:externalRepresentation];
	return [self _fillObject:object fromRepresentation:objectRepresentation usingMapping:mapping];
}

+ (NSArray *)_deserializeCollectionRepresentation:(NSArray *)representation
                                     usingMapping:(FEMManagedObjectMapping *)mapping
			                              context:(NSManagedObjectContext *)context {
	NSMutableArray *output = [NSMutableArray array];
	for (id objectRepresentation in representation) {
		@autoreleasepool {
			[output addObject:[self _deserializeObjectRepresentation:objectRepresentation
			                                            usingMapping:mapping
						                                     context:context]];
		}
	}
	return [output copy];
}

+ (NSArray *)_deserializeCollectionExternalRepresentation:(NSArray *)externalRepresentation
                                             usingMapping:(FEMManagedObjectMapping *)mapping
			                                      context:(NSManagedObjectContext *)context {
	id representation = [mapping extractRootFromExternalRepresentation:externalRepresentation];
	return [self _deserializeCollectionRepresentation:representation usingMapping:mapping context:context];
}

+ (NSArray *)deserializeCollectionExternalRepresentation:(NSArray *)externalRepresentation
                                            usingMapping:(FEMManagedObjectMapping *)mapping
			                                     context:(NSManagedObjectContext *)context {
	FEMCache *cache = [[FEMCache alloc] initWithMapping:mapping
	                                         externalRepresentation:externalRepresentation
						                                    context:context];
	EMKLookupCacheSetCurrent(cache);
	NSArray *output = [self _deserializeCollectionExternalRepresentation:externalRepresentation
	                                                        usingMapping:mapping
				                                                 context:context];
	EMKLookupCacheRemoveCurrent();

	return output;
}

// unused
+ (NSArray *)syncArrayOfObjectsFromExternalRepresentation:(NSArray *)externalRepresentation
                                              withMapping:(FEMManagedObjectMapping *)mapping
		                                     fetchRequest:(NSFetchRequest *)fetchRequest
					               inManagedObjectContext:(NSManagedObjectContext *)moc {
	NSAssert(mapping.primaryKey, @"A objectMapping with a primary key is required");
	FEMAttributeMapping *primaryKeyFieldMapping = [mapping primaryKeyMapping];

	// Create a dictionary that maps primary keys to existing objects
	NSArray *existing = [moc executeFetchRequest:fetchRequest error:NULL];
	NSDictionary *existingByPK = [NSDictionary dictionaryWithObjects:existing
	                                                         forKeys:[existing valueForKey:primaryKeyFieldMapping.property]];

	NSMutableArray *array = [NSMutableArray array];
	for (NSDictionary *representation in externalRepresentation) {
		// Look up the object by its primary key

		id primaryKeyValue = [primaryKeyFieldMapping mapValue:[externalRepresentation valueForKeyPath:primaryKeyFieldMapping.keyPath]];
		id object = [existingByPK objectForKey:primaryKeyValue];

		// Create a new object if necessary
		if (!object) {
					object = [NSEntityDescription insertNewObjectForEntityForName:mapping.entityName
					                                       inManagedObjectContext:moc];
		}

		[self fillObject:object fromExternalRepresentation:representation usingMapping:mapping];
		[array addObject:object];
	}

	// Any object returned by the fetch request not in the external represntation has to be deleted
	NSMutableSet *toDelete = [NSMutableSet setWithArray:existing];
	[toDelete minusSet:[NSSet setWithArray:array]];
	for (NSManagedObject *o in toDelete) {
			[moc deleteObject:o];
	}

	return [NSArray arrayWithArray:array];
}

@end