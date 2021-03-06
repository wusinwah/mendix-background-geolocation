//
//  MAURPostLocationTask.m
//  BackgroundGeolocation
//
//  Created by Marian Hello on 27/04/2018.
//  Copyright © 2018 mauron85. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "Reachability.h"
#import "MAURSQLiteLocationDAO.h"
#import "MAURBackgroundSync.h"
#import "MAURConfig.h"
#import "MAURLogging.h"
#import "MAURPostLocationTask.h"
#import "MAURSQLiteLocationDAO.h"


#import <UIKit/UIKit.h>


static NSString * const TAG = @"MAURPostLocationTask";

@interface MAURPostLocationTask() <MAURBackgroundSyncDelegate>
{
    
}
@end

@implementation MAURPostLocationTask
{
    Reachability *reach;
    MAURBackgroundSync *uploader;
    BOOL hasConnectivity;
    
    
    UILocalNotification *localNotification;
}

static MAURLocationTransform s_locationTransform = nil;

- (instancetype) init
{
    self = [super init];

    if (self == nil) {
        return self;
    }

    hasConnectivity = YES;

    uploader = [[MAURBackgroundSync alloc] init];
    uploader.delegate = self;
    
    localNotification = [[UILocalNotification alloc] init];
    localNotification.timeZone = [NSTimeZone defaultTimeZone];
    
    reach = [Reachability reachabilityWithHostname:@"www.google.com"];
    reach.reachableBlock = ^(Reachability *_reach) {
        // keep in mind this is called on a background thread
        // and if you are updating the UI it needs to happen
        // on the main thread:
        hasConnectivity = YES;
        [_reach stopNotifier];
    };
    
    reach.unreachableBlock = ^(Reachability *reach) {
        hasConnectivity = NO;
    };

    return self;
}

- (void) start
{
    hasConnectivity = YES;
    [reach startNotifier];
}

- (void) stop
{
    [reach stopNotifier];
}

- (void) notify:(NSString*)message
{
    NSData * data = [message dataUsingEncoding:NSUTF8StringEncoding];
    NSError *jserror;
    NSArray *arr = [NSJSONSerialization JSONObjectWithData:[message dataUsingEncoding:NSUTF8StringEncoding] options:kNilOptions error:&jserror];
    
        for(int i=0;i<arr.count;i++){
            NSDictionary * dict = arr[i];
            NSLog(@"MY DATA....%@",dict[@"title"]);
            localNotification.fireDate = [NSDate date];
            localNotification.alertTitle = dict[@"title"];
            localNotification.alertBody = dict[@"message"];
            [[UIApplication sharedApplication] scheduleLocalNotification:localNotification];

        
        }
}

- (NSString * _Nullable) add:(MAURLocation * _Nonnull)inLocation
{
    // Take this variable on the main thread to be safe
    MAURLocationTransform locationTransform = s_locationTransform;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        
        MAURLocation *location = inLocation;
        
        if (locationTransform != nil) {
            location = locationTransform(location);
            
            if (location == nil) {
                return;
            }
        }
        
        MAURSQLiteLocationDAO *locationDAO = [MAURSQLiteLocationDAO sharedInstance];
        // TODO: investigate location id always 0
        NSNumber *locationId = [locationDAO persistLocation:location limitRows:_config.maxLocations.integerValue];
        
        if (hasConnectivity && [self.config hasValidUrl]) {
            NSError *error = nil;
            NSString *ret = [self post:location toUrl:self.config.url withTemplate:self.config._template withHttpHeaders:self.config.httpHeaders error:&error];
            
            
            
            if (ret != nil) {
                DDLogDebug(@"RECEIVED %@", ret);
                
                if([ret hasPrefix:@"NOTIFY:"]){
                    
                    [self notify:[ret substringFromIndex:7 ]];
                }
                
                if (locationId != nil) {
                    [locationDAO deleteLocation:locationId error:nil];
                }
            }
        }

        if ([self.config hasValidSyncUrl]) {
            NSNumber *locationsCount = [locationDAO getLocationsForSyncCount];
            if (locationsCount && [locationsCount integerValue] >= self.config.syncThreshold.integerValue) {
                DDLogDebug(@"%@ Attempt to sync locations: %@ threshold: %@", TAG, locationsCount, self.config.syncThreshold);
                [self sync];
            }
        }
    });
    return nil;
}

- (NSString * _Nullable) post:(MAURLocation*)location toUrl:(NSString*)url withTemplate:(id)locationTemplate withHttpHeaders:(NSMutableDictionary*)httpHeaders error:(NSError * __autoreleasing *)outError;
{
    NSArray *locations = [[NSArray alloc] initWithObjects:[location toResultFromTemplate:locationTemplate], nil];
    //    NSArray *jsonArray = [NSJSONSerialization JSONObjectWithData: data options: NSJSONReadingMutableContainers error: &e];
    NSData *data = [NSJSONSerialization dataWithJSONObject:locations options:0 error:outError];
    if (!data) {
        return nil;
    }
    
    NSString *jsonStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
//    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setHTTPMethod:@"POST"];
    if (httpHeaders != nil) {
        for(id key in httpHeaders) {
            id value = [httpHeaders objectForKey:key];
            [request addValue:value forHTTPHeaderField:key];
        }
    }
    [request setHTTPBody:[jsonStr dataUsingEncoding:NSUTF8StringEncoding]];
    
    // Create url connection and fire request
    NSHTTPURLResponse* urlResponse = nil;
    NSData *outData = [NSURLConnection sendSynchronousRequest:request returningResponse:&urlResponse error:outError];
    NSString *outStr = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding];
    NSInteger statusCode = urlResponse.statusCode;
    DDLogDebug(@"Location was sent to the server, ...%@............%ld", outStr, (long)statusCode);
    if (statusCode == 285)
    {
        // Okay, but we don't need to continue sending these
        
        DDLogDebug(@"Location was sent to the server, and received an \"HTTP 285 Updated Not Required\"");
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (_delegate && [_delegate respondsToSelector:@selector(postLocationTaskRequestedAbortUpdates:)])
            {
                [_delegate postLocationTaskRequestedAbortUpdates:self];
            }
        });
    }

    if (statusCode == 401)
    {   
        dispatch_async(dispatch_get_main_queue(), ^{
            if (_delegate && [_delegate respondsToSelector:@selector(postLocationTaskHttpAuthorizationUpdates:)])
            {
                [_delegate postLocationTaskHttpAuthorizationUpdates:self];
            }
        });
    }
    
    // All 2xx statuses are okay
    if (statusCode >= 200 && statusCode < 300)
    {
        return outStr;
    }
    
    if (*outError == nil) {
        DDLogDebug(@"%@ Server error while posting locations responseCode: %ld", TAG, (long)statusCode);
    } else {
        DDLogError(@"%@ Error while posting locations %@", TAG, [*outError localizedDescription]);
    }

    return nil;
}

- (void) sync
{
    if ([self.config hasValidSyncUrl]) {
        [uploader sync:self.config.syncUrl withTemplate:self.config._template withHttpHeaders:self.config.httpHeaders];
    }
}

#pragma mark - Location transform

+ (void) setLocationTransform:(MAURLocationTransform _Nullable)transform
{
    s_locationTransform = transform;
}

+ (MAURLocationTransform _Nullable) locationTransform
{
    return s_locationTransform;
}

#pragma mark - MAURBackgroundSyncDelegate

- (void)backgroundSyncRequestedAbortUpdates:(MAURBackgroundSync *)task
{
    if (_delegate && [_delegate respondsToSelector:@selector(postLocationTaskRequestedAbortUpdates:)])
    {
        [_delegate postLocationTaskRequestedAbortUpdates:self];
    }
}

- (void)backgroundSyncHttpAuthorizationUpdates:(MAURBackgroundSync *)task
{
    if (_delegate && [_delegate respondsToSelector:@selector(postLocationTaskHttpAuthorizationUpdates:)])
    {
        [_delegate postLocationTaskHttpAuthorizationUpdates:self];
    }
}

@end
