/*
 Copyright 2009-2011 Urban Airship Inc. All rights reserved.

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:

 1. Redistributions of source code must retain the above copyright notice, this
 list of conditions and the following disclaimer.

 2. Redistributions in binaryform must reproduce the above copyright notice,
 this list of conditions and the following disclaimer in the documentation
 and/or other materials provided withthe distribution.

 THIS SOFTWARE IS PROVIDED BY THE URBAN AIRSHIP INC``AS IS'' AND ANY EXPRESS OR
 IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
 EVENT SHALL URBAN AIRSHIP INC OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
 BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
 OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "PushPlugin.h"
#import "PushPluginFCM.h"
#import "PushPluginSettings.h"
#import "CDVAppDelegate+notification.h"

@interface PushPlugin ()

@property (nonatomic, strong) PushPluginFCM *pushPluginFCM;

@property (nonatomic, strong) NSDictionary *launchNotification;
@property (nonatomic, strong) NSDictionary *notificationMessage;
@property (nonatomic, strong) NSMutableDictionary *handlerObj;

@property (nonatomic, assign) BOOL isInline;
@property (nonatomic, assign) BOOL clearBadge;
@property (nonatomic, assign) BOOL forceShow;
@property (nonatomic, assign) BOOL coldstart;

@property (nonatomic, copy) void (^backgroundTaskcompletionHandler)(UIBackgroundFetchResult);

@end

@implementation PushPlugin

@synthesize callbackId;

- (void)pluginInitialize {
    self.pushPluginFCM = [[PushPluginFCM alloc] initWithGoogleServicePlist];

    if([self.pushPluginFCM isFCMEnabled]) {
        [self.pushPluginFCM configure:self.commandDelegate];
    }

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(didRegisterForRemoteNotificationsWithDeviceToken:)
                                                 name:@"CordovaPluginPushDidRegisterForRemoteNotificationsWithDeviceToken"
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(didFailToRegisterForRemoteNotificationsWithError:)
                                                 name:@"CordovaPluginPushDidFailToRegisterForRemoteNotificationsWithError"
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(didReceiveRemoteNotification:)
                                                 name:@"CordovaPluginPushDidReceiveRemoteNotification"
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(pushPluginOnApplicationDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(willPresentNotification:)
                                                 name:@"CordovaPluginPushWillPresentNotification"
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(didReceiveNotificationResponse:)
                                                 name:@"CordovaPluginPushDidReceiveNotificationResponse"
                                               object:nil];
}

- (void)unregister:(CDVInvokedUrlCommand *)command {
    NSArray* topics = [command argumentAtIndex:0];

    if (topics != nil) {
        [self.pushPluginFCM unsubscribeFromTopics:topics];
    } else {
        [[UIApplication sharedApplication] unregisterForRemoteNotifications];
        [self successWithMessage:command.callbackId withMsg:@"unregistered"];
    }
}

- (void)subscribe:(CDVInvokedUrlCommand *)command {
    if (!self.pushPluginFCM.isFCMEnabled) {
        NSLog(@"[PushPlugin] The 'subscribe' API not allowed. FCM is not enabled.");
        [self successWithMessage:command.callbackId withMsg:@"The 'subscribe' API not allowed. FCM is not enabled."];
        return;
    }

    NSString* topic = [command argumentAtIndex:0];
    if (topic == nil) {
        NSLog(@"[PushPlugin] There is no topic to subscribe");
        [self successWithMessage:command.callbackId withMsg:@"There is no topic to subscribe"];
        return;
    }

    [self.pushPluginFCM subscribeToTopic:topic];
    [self successWithMessage:command.callbackId withMsg:[NSString stringWithFormat:@"Successfully subscribe to topic %@", topic]];
}

- (void)unsubscribe:(CDVInvokedUrlCommand *)command {
    if (!self.pushPluginFCM.isFCMEnabled) {
        NSLog(@"[PushPlugin] The 'unsubscribe' API not allowed. FCM is not enabled.");
        [self successWithMessage:command.callbackId withMsg:@"The 'unsubscribe' API not allowed. FCM is not enabled."];
        return;
    }

    NSString* topic = [command argumentAtIndex:0];
    if (topic == nil) {
        NSLog(@"[PushPlugin] There is no topic to unsubscribe from.");
        [self successWithMessage:command.callbackId withMsg:@"There is no topic to unsubscribe from."];
        return;
    }

    [self.pushPluginFCM unsubscribeFromTopic:topic];
    [self successWithMessage:command.callbackId withMsg:[NSString stringWithFormat:@"Successfully unsubscribe from topic %@", topic]];
}

- (void)init:(CDVInvokedUrlCommand *)command {
    NSMutableDictionary* options = [command.arguments objectAtIndex:0];
    [[PushPluginSettings sharedInstance] updateSettingsWithOptions:[options objectForKey:@"ios"]];
    PushPluginSettings *settings = [PushPluginSettings sharedInstance];

    if ([self.pushPluginFCM isFCMEnabled]) {
        self.pushPluginFCM.callbackId = command.callbackId;
    }

    self.callbackId = command.callbackId;

    if ([settings voipEnabled]) {
        [self.commandDelegate runInBackground:^ {
            NSLog(@"[PushPlugin] VoIP set to true");
            PKPushRegistry *pushRegistry = [[PKPushRegistry alloc] initWithQueue:dispatch_get_main_queue()];
            pushRegistry.delegate = self;
            pushRegistry.desiredPushTypes = [NSSet setWithObject:PKPushTypeVoIP];
        }];
    } else {
        NSLog(@"[PushPlugin] VoIP missing or false");

        [self.commandDelegate runInBackground:^ {
            NSLog(@"[PushPlugin] register called");
            self.isInline = NO;
            self.forceShow = [settings forceShowEnabled];
            self.clearBadge = [settings clearBadgeEnabled];
            if (self.clearBadge) {
                [[UIApplication sharedApplication] setApplicationIconBadgeNumber:0];
            }

            UNAuthorizationOptions authorizationOptions = UNAuthorizationOptionNone;
            if ([settings badgeEnabled]) {
                authorizationOptions |= UNAuthorizationOptionBadge;
            }
            if ([settings soundEnabled]) {
                authorizationOptions |= UNAuthorizationOptionSound;
            }
            if ([settings alertEnabled]) {
                authorizationOptions |= UNAuthorizationOptionAlert;
            }
            if (@available(iOS 12.0, *))
            {
                if ([settings criticalEnabled]) {
                    authorizationOptions |= UNAuthorizationOptionCriticalAlert;
                }
            }
            [self handleNotificationSettingsWithAuthorizationOptions:[NSNumber numberWithInteger:authorizationOptions]];

            UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
            [center setNotificationCategories:[settings categories]];

            // If there is a pending startup notification, we will delay to allow JS event handlers to setup
            if (self.notificationMessage) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self performSelector:@selector(notificationReceived) withObject:nil afterDelay: 0.5];
                });
            }
        }];
    }
}

- (void)didRegisterForRemoteNotificationsWithDeviceToken:(NSNotification *)notification {
    NSData *deviceToken = notification.object;

    if (self.callbackId == nil) {
        NSLog(@"[PushPlugin] Unexpected call to didRegisterForRemoteNotificationsWithDeviceToken, ignoring: %@", deviceToken);
        return;
    }

    NSLog(@"[PushPlugin] register success: %@", deviceToken);

    if ([self.pushPluginFCM isFCMEnabled]) {
        [self.pushPluginFCM configureTokens:deviceToken];
    } else {
        [self registerWithToken:[self convertTokenToString:deviceToken]];
    }
}

- (NSString *)convertTokenToString:(NSData *)deviceToken {
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    // [deviceToken description] is like "{length = 32, bytes = 0xd3d997af 967d1f43 b405374a 13394d2f ... 28f10282 14af515f }"
    return [self hexadecimalStringFromData:deviceToken];
#else
    // [deviceToken description] is like "<124686a5 556a72ca d808f572 00c323b9 3eff9285 92445590 3225757d b83967be>"
    return [[[[deviceToken description] stringByReplacingOccurrencesOfString:@"<"withString:@""]
                        stringByReplacingOccurrencesOfString:@">" withString:@""]
                       stringByReplacingOccurrencesOfString: @" " withString: @""];
#endif
}

- (NSString *)hexadecimalStringFromData:(NSData *)data {
    NSUInteger dataLength = data.length;
    if (dataLength == 0) {
        return nil;
    }

    const unsigned char *dataBuffer = data.bytes;
    NSMutableString *hexString  = [NSMutableString stringWithCapacity:(dataLength * 2)];
    for (int i = 0; i < dataLength; ++i) {
        [hexString appendFormat:@"%02x", dataBuffer[i]];
    }
    return [hexString copy];
}

- (void)didFailToRegisterForRemoteNotificationsWithError:(NSNotification *)notification {
    NSError *error = (NSError *)notification.object;

    if (self.callbackId == nil) {
        NSLog(@"[PushPlugin] Unexpected call to didFailToRegisterForRemoteNotificationsWithError, ignoring: %@", error);
        return;
    }
    NSLog(@"[PushPlugin] register failed");
    [self failWithMessage:self.callbackId withMsg:@"" withError:error];
}

- (void)didReceiveRemoteNotification:(NSNotification *)notification {
    NSDictionary *notificationInfo = notification.userInfo;
    // Extract userInfo and completionHandler
    NSDictionary *userInfo = notificationInfo[@"userInfo"];
    void (^completionHandler)(UIBackgroundFetchResult) = notificationInfo[@"completionHandler"];
    NSLog(@"[PushPlugin]didReceiveNotification with fetchCompletionHandler");
    // app is in the background or inactive, so only call notification callback if this is a silent push
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        NSLog(@"[PushPlugin] app in-active");
        // do some convoluted logic to find out if this should be a silent push.
        long silent = 0;
        id aps = [userInfo objectForKey:@"aps"];
        id contentAvailable = [aps objectForKey:@"content-available"];
        if ([contentAvailable isKindOfClass:[NSString class]] && [contentAvailable isEqualToString:@"1"]) {
            silent = 1;
        } else if ([contentAvailable isKindOfClass:[NSNumber class]]) {
            silent = [contentAvailable integerValue];
        }
        if (silent == 1) {
            NSLog(@"[PushPlugin] this should be a silent push");
            void (^safeHandler)(UIBackgroundFetchResult) = ^(UIBackgroundFetchResult result){
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionHandler(result);
                });
            };
            if (self.handlerObj == nil) {
                self.handlerObj = [NSMutableDictionary dictionaryWithCapacity:2];
            }
            id notId = [userInfo objectForKey:@"notId"];
            if (notId != nil) {
                NSLog(@"[PushPlugin] notId %@", notId);
                [self.handlerObj setObject:safeHandler forKey:notId];
            } else {
                NSLog(@"[PushPlugin] notId handler");
                [self.handlerObj setObject:safeHandler forKey:@"handler"];
            }
            self.notificationMessage = userInfo;
            self.isInline = NO;
            [self notificationReceived];
        } else {
            NSLog(@"[PushPlugin] Save push for later");
            self.launchNotification = userInfo;
            completionHandler(UIBackgroundFetchResultNewData);
        }
    } else {
        completionHandler(UIBackgroundFetchResultNoData);
    }
}

- (void)pushPluginOnApplicationDidBecomeActive:(NSNotification *)notification {
    NSLog(@"[PushPlugin] pushPluginOnApplicationDidBecomeActive");

    NSString *firstLaunchKey = @"firstLaunchKey";
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"phonegap-plugin-push"];
    if (![defaults boolForKey:firstLaunchKey]) {
        NSLog(@"[PushPlugin] application first launch: remove badge icon number");
        [defaults setBool:YES forKey:firstLaunchKey];
        [[UIApplication sharedApplication] setApplicationIconBadgeNumber:0];
    }

    UIApplication *application = notification.object;

    if (self.clearBadge) {
        NSLog(@"[PushPlugin] clearing badge");
        application.applicationIconBadgeNumber = 0;
    } else {
        NSLog(@"[PushPlugin] skip clear badge");
    }

    if (self.launchNotification) {
        self.isInline = NO;
        self.coldstart = NO;
        self.notificationMessage = self.launchNotification;
        self.launchNotification = nil;
        [self performSelectorOnMainThread:@selector(notificationReceived) withObject:self waitUntilDone:NO];
    }
}

- (void)willPresentNotification:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo[@"userInfo"];
    void (^completionHandler)(UNNotificationPresentationOptions) = notification.userInfo[@"completionHandler"];

    NSLog(@"[PushPlugin] NotificationCenter Handle push from foreground");

    self.notificationMessage = userInfo;
    self.isInline = YES;
    [self notificationReceived];

    UNNotificationPresentationOptions presentationOption = UNNotificationPresentationOptionNone;
    if (@available(iOS 10, *)) {
        if(self.forceShow) {
            presentationOption = UNNotificationPresentationOptionAlert;
        }
    }

    if (completionHandler) {
        completionHandler(presentationOption);
    }
}

- (void)didReceiveNotificationResponse:(NSNotification *)notification {
    NSDictionary *originalUserInfo = notification.userInfo[@"originalUserInfo"];
    NSDictionary *modifiedUserInfo = notification.userInfo[@"modifiedUserInfo"];
    void (^completionHandler)(void) = notification.userInfo[@"completionHandler"];
    NSLog(@"[PushPlugin] Modified UserInfo %@", modifiedUserInfo);
    switch ([UIApplication sharedApplication].applicationState) {
        case UIApplicationStateActive:
        {
            self.notificationMessage = modifiedUserInfo;
            self.isInline = NO;
            [self notificationReceived];
            if (completionHandler) {
                completionHandler();
            }
            break;
        }
        case UIApplicationStateInactive:
        {
            NSLog(@"[PushPlugin] coldstart");
            if ([notification.userInfo[@"actionIdentifier"] rangeOfString:@"UNNotificationDefaultActionIdentifier"].location == NSNotFound) {
                self.launchNotification = modifiedUserInfo;
            } else {
                self.launchNotification = originalUserInfo;
            }
            self.coldstart = YES;
            if (completionHandler) {
                completionHandler();
            }
            break;
        }
        case UIApplicationStateBackground:
        {
            void (^safeHandler)(void) = ^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completionHandler) {
                        completionHandler();
                    }
                });
            };
            if (self.handlerObj == nil) {
                self.handlerObj = [NSMutableDictionary dictionaryWithCapacity:2];
            }
            id notId = modifiedUserInfo[@"notId"];
            if (notId != nil) {
                NSLog(@"[PushPlugin] notId %@", notId);
                [self.handlerObj setObject:safeHandler forKey:notId];
            } else {
                NSLog(@"[PushPlugin] notId handler");
                [self.handlerObj setObject:safeHandler forKey:@"handler"];
            }
            self.notificationMessage = modifiedUserInfo;
            self.isInline = NO;
            [self performSelectorOnMainThread:@selector(notificationReceived) withObject:self waitUntilDone:NO];
            break;
        }
    }
}

- (void)notificationReceived {
    NSLog(@"[PushPlugin] Notification received");

    if (self.notificationMessage && self.callbackId != nil)
    {
        NSMutableDictionary* message = [NSMutableDictionary dictionaryWithCapacity:4];
        NSMutableDictionary* additionalData = [NSMutableDictionary dictionaryWithCapacity:4];

        for (id key in self.notificationMessage) {
            if ([key isEqualToString:@"aps"]) {
                id aps = [self.notificationMessage objectForKey:@"aps"];

                for(id key in aps) {
                    NSLog(@"[PushPlugin] key: %@", key);
                    id value = [aps objectForKey:key];

                    if ([key isEqualToString:@"alert"]) {
                        if ([value isKindOfClass:[NSDictionary class]]) {
                            for (id messageKey in value) {
                                id messageValue = [value objectForKey:messageKey];
                                if ([messageKey isEqualToString:@"body"]) {
                                    [message setObject:messageValue forKey:@"message"];
                                } else if ([messageKey isEqualToString:@"title"]) {
                                    [message setObject:messageValue forKey:@"title"];
                                } else {
                                    [additionalData setObject:messageValue forKey:messageKey];
                                }
                            }
                        }
                        else {
                            [message setObject:value forKey:@"message"];
                        }
                    } else if ([key isEqualToString:@"title"]) {
                        [message setObject:value forKey:@"title"];
                    } else if ([key isEqualToString:@"badge"]) {
                        [message setObject:value forKey:@"count"];
                    } else if ([key isEqualToString:@"sound"]) {
                        [message setObject:value forKey:@"sound"];
                    } else if ([key isEqualToString:@"image"]) {
                        [message setObject:value forKey:@"image"];
                    } else {
                        [additionalData setObject:value forKey:key];
                    }
                }
            } else {
                [additionalData setObject:[self.notificationMessage objectForKey:key] forKey:key];
            }
        }

        if (self.isInline) {
            [additionalData setObject:[NSNumber numberWithBool:YES] forKey:@"foreground"];
        } else {
            [additionalData setObject:[NSNumber numberWithBool:NO] forKey:@"foreground"];
        }

        if (self.coldstart) {
            [additionalData setObject:[NSNumber numberWithBool:YES] forKey:@"coldstart"];
        } else {
            [additionalData setObject:[NSNumber numberWithBool:NO] forKey:@"coldstart"];
        }

        [message setObject:additionalData forKey:@"additionalData"];

        // send notification message
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:message];
        [pluginResult setKeepCallbackAsBool:YES];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:self.callbackId];

        self.coldstart = NO;
        self.notificationMessage = nil;
    }
}

- (void)clearNotification:(CDVInvokedUrlCommand *)command {
    NSNumber *notId = [command.arguments objectAtIndex:0];
    [[UNUserNotificationCenter currentNotificationCenter] getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> * _Nonnull notifications) {
        /*
         * If the server generates a unique "notId" for every push notification, there should only be one match in these arrays, but if not, it will delete
         * all notifications with the same value for "notId"
         */
        NSPredicate *matchingNotificationPredicate = [NSPredicate predicateWithFormat:@"request.content.userInfo.notId == %@", notId];
        NSArray<UNNotification *> *matchingNotifications = [notifications filteredArrayUsingPredicate:matchingNotificationPredicate];
        NSMutableArray<NSString *> *matchingNotificationIdentifiers = [NSMutableArray array];
        for (UNNotification *notification in matchingNotifications) {
            [matchingNotificationIdentifiers addObject:notification.request.identifier];
        }
        [[UNUserNotificationCenter currentNotificationCenter] removeDeliveredNotificationsWithIdentifiers:matchingNotificationIdentifiers];

        NSString *message = [NSString stringWithFormat:@"Cleared notification with ID: %@", notId];
        CDVPluginResult *commandResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:message];
        [self.commandDelegate sendPluginResult:commandResult callbackId:command.callbackId];
    }];
}

- (void)setApplicationIconBadgeNumber:(CDVInvokedUrlCommand *)command {
    NSMutableDictionary* options = [command.arguments objectAtIndex:0];
    int badge = [[options objectForKey:@"badge"] intValue] ?: 0;

    [[UIApplication sharedApplication] setApplicationIconBadgeNumber:badge];

    NSString* message = [NSString stringWithFormat:@"app badge count set to %d", badge];
    CDVPluginResult *commandResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:message];
    [self.commandDelegate sendPluginResult:commandResult callbackId:command.callbackId];
}

- (void)getApplicationIconBadgeNumber:(CDVInvokedUrlCommand *)command {
    NSInteger badge = [UIApplication sharedApplication].applicationIconBadgeNumber;

    CDVPluginResult *commandResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:(int)badge];
    [self.commandDelegate sendPluginResult:commandResult callbackId:command.callbackId];
}

- (void)clearAllNotifications:(CDVInvokedUrlCommand *)command {
    [[UIApplication sharedApplication] setApplicationIconBadgeNumber:0];

    NSString* message = [NSString stringWithFormat:@"cleared all notifications"];
    CDVPluginResult *commandResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:message];
    [self.commandDelegate sendPluginResult:commandResult callbackId:command.callbackId];
}

- (void)hasPermission:(CDVInvokedUrlCommand *)command {
    if ([self respondsToSelector:@selector(checkUserHasRemoteNotificationsEnabledWithCompletionHandler:)]) {
        [self performSelector:@selector(checkUserHasRemoteNotificationsEnabledWithCompletionHandler:) withObject:^(BOOL isEnabled) {
            NSMutableDictionary* message = [NSMutableDictionary dictionaryWithCapacity:1];
            [message setObject:[NSNumber numberWithBool:isEnabled] forKey:@"isEnabled"];
            CDVPluginResult *commandResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:message];
            [self.commandDelegate sendPluginResult:commandResult callbackId:command.callbackId];
        }];
    }
}

- (void)successWithMessage:(NSString *)myCallbackId withMsg:(NSString *)message {
    if (myCallbackId != nil)
    {
        CDVPluginResult *commandResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:message];
        [self.commandDelegate sendPluginResult:commandResult callbackId:myCallbackId];
    }
}

- (void)registerWithToken:(NSString *)token {
    NSMutableDictionary* message = [NSMutableDictionary dictionaryWithCapacity:2];
    [message setObject:token forKey:@"registrationId"];
    [message setObject:@"APNS" forKey:@"registrationType"];

    // Send result to trigger 'registration' event but keep callback
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:message];
    [pluginResult setKeepCallbackAsBool:YES];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:self.callbackId];
}

- (void)failWithMessage:(NSString *)myCallbackId withMsg:(NSString *)message withError:(NSError *)error {
    NSString        *errorMessage = (error) ? [NSString stringWithFormat:@"%@ - %@", message, [error localizedDescription]] : message;
    CDVPluginResult *commandResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:errorMessage];

    [self.commandDelegate sendPluginResult:commandResult callbackId:myCallbackId];
}

- (void) finish:(CDVInvokedUrlCommand *)command {
    NSLog(@"[PushPlugin] finish called");

    [self.commandDelegate runInBackground:^ {
        NSString* notId = [command.arguments objectAtIndex:0];

        dispatch_async(dispatch_get_main_queue(), ^{
            [NSTimer scheduledTimerWithTimeInterval:0.1
                                             target:self
                                           selector:@selector(stopBackgroundTask:)
                                           userInfo:notId
                                            repeats:NO];
        });

        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    }];
}

- (void)stopBackgroundTask:(NSTimer *)timer {
    UIApplication *app = [UIApplication sharedApplication];

    NSLog(@"[PushPlugin] stopBackgroundTask called");

    if (self.handlerObj) {
        NSLog(@"[PushPlugin] handlerObj");
        self.backgroundTaskcompletionHandler = [self.handlerObj[[timer userInfo]] copy];
        if (self.backgroundTaskcompletionHandler) {
            NSLog(@"[PushPlugin] stopBackgroundTask (remaining t: %f)", app.backgroundTimeRemaining);
            self.backgroundTaskcompletionHandler(UIBackgroundFetchResultNewData);
            self.backgroundTaskcompletionHandler = nil;
        }
    }
}


- (void)pushRegistry:(PKPushRegistry *)registry didUpdatePushCredentials:(PKPushCredentials *)credentials forType:(NSString *)type {
    if([credentials.token length] == 0) {
        NSLog(@"[PushPlugin] VoIP register error - No device token:");
        return;
    }

    NSLog(@"[PushPlugin] VoIP register success");
    const unsigned *tokenBytes = [credentials.token bytes];
    NSString *sToken = [NSString stringWithFormat:@"%08x%08x%08x%08x%08x%08x%08x%08x",
                        ntohl(tokenBytes[0]), ntohl(tokenBytes[1]), ntohl(tokenBytes[2]),
                        ntohl(tokenBytes[3]), ntohl(tokenBytes[4]), ntohl(tokenBytes[5]),
                        ntohl(tokenBytes[6]), ntohl(tokenBytes[7])];

    [self registerWithToken:sToken];
}

- (void)pushRegistry:(PKPushRegistry *)registry didReceiveIncomingPushWithPayload:(PKPushPayload *)payload forType:(NSString *)type {
    NSLog(@"[PushPlugin] VoIP Notification received");
    self.notificationMessage = payload.dictionaryPayload;
    [self notificationReceived];
}

- (void)handleNotificationSettingsWithAuthorizationOptions:(NSNumber *)authorizationOptionsObject {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    UNAuthorizationOptions authorizationOptions = [authorizationOptionsObject unsignedIntegerValue];

    __weak UNUserNotificationCenter *weakCenter = center;
    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings * _Nonnull settings) {
        switch (settings.authorizationStatus) {
            case UNAuthorizationStatusNotDetermined:
            {
                [weakCenter requestAuthorizationWithOptions:authorizationOptions completionHandler:^(BOOL granted, NSError * _Nullable error) {
                    if (error) {
                        NSLog(@"[PushPlugin] Error during authorization request: %@", error.localizedDescription);
                    }

                    if (granted) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [[UIApplication sharedApplication] registerForRemoteNotifications];
                        });
                    } else {
                        NSLog(@"[PushPlugin] Notification authorization denied.");
                    }
                }];
                break;
            }
            case UNAuthorizationStatusAuthorized:
            {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[UIApplication sharedApplication] registerForRemoteNotifications];
                });
                break;
            }
            case UNAuthorizationStatusDenied:
            {
                NSLog(@"[PushPlugin] User denied notification permission.");
                break;
            }
            default:
                NSLog(@"[PushPlugin] Unhandled authorization status: %ld", (long)settings.authorizationStatus);
                break;
        }
    }];
}

- (void)checkUserHasRemoteNotificationsEnabledWithCompletionHandler:(nonnull void (^)(BOOL))completionHandler {
    [[UNUserNotificationCenter currentNotificationCenter] getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings * _Nonnull settings) {

        switch (settings.authorizationStatus)
        {
            case UNAuthorizationStatusDenied:
            case UNAuthorizationStatusNotDetermined:
                completionHandler(NO);
                break;

            case UNAuthorizationStatusAuthorized:
            case UNAuthorizationStatusEphemeral:
            case UNAuthorizationStatusProvisional:
                completionHandler(YES);
                break;
        }
    }];
}

- (void)dealloc {
    self.launchNotification = nil;
    self.coldstart = nil;
}

@end
