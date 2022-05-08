#import <stdio.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>

#import <Foundation/Foundation.h>
#import <Accounts/Accounts.h>
#import <rocketbootstrap/rocketbootstrap.h>
#import "pac_helper.h"


@interface MicroPaymentQueueRequest : NSObject
@property(retain) NSNumber* userIdentifier;
@property(retain) NSNumber* rangeStartIdentifier;
@property(retain) NSNumber* rangeEndIdentifier;
@property(assign) BOOL needsAuthentication;
- (id)_ntsQueryParameters:(id *)parameters;
- (id)_ntsClientApplication:(id *)application;
- (id)description;
- (id)newStoreURLOperation:(id *)operation;
- (id)init;
@end

@interface SSAccount : NSObject
@property (nonatomic, readonly) ACAccount *backingAccount;
@property (nonatomic, retain) dispatch_queue_t backingAccountAccessQueue;
@property (copy) NSString *ITunesPassSerialNumber;
@property (copy) NSString *altDSID;
@property (copy) NSString *accountName;
@property (copy) NSString *firstName;
@property (copy) NSString *lastName;
@property (readonly) NSString *localizedName;
@property (copy) NSString *storeFrontIdentifier;
@property (getter=isActive) bool active;
@property (getter=isAuthenticated) bool authenticated;
@property (retain) NSNumber *uniqueIdentifier;
@end

@interface SSAccountStore : NSObject
+ (SSAccountStore *)defaultStore;
@property (readonly) SSAccount *activeAccount;
@end

@interface ISDevice : NSObject
+ (ISDevice *)sharedInstance;
@property (readonly) NSString *guid; 
@end

@interface ISStoreURLOperation : NSObject
@property (assign) BOOL needsURLBag;
@property (assign) BOOL needsAuthentication;
@property (assign) BOOL needsTermsAndConditionsAcceptance;
@property (assign) BOOL performsMachineDataActions;

- (NSURLRequest *)newRequestWithURL:(NSURL *)url;
+ (void)_addiTunesStoreHeadersToRequest:(id)arg1 withAccount:(id)arg2 appendAuthKitHeaders:(BOOL)arg3 appendStorefrontToURL:(BOOL)arg4 clientBundleIdentifier:(id)arg5 extraHeaders:(id)arg6 storefrontSuffix:(id)arg7;
@end


static CFDataRef Callback(
    CFMessagePortRef port,
    SInt32 messageID,
    CFDataRef data,
    void *info
) {
    // ...

    NSDictionary *args = [NSPropertyListSerialization propertyListWithData:(__bridge NSData *)data options:kNilOptions format:nil error:nil];
    NSLog(@"Start to calc kbsync, base offset: 0x%lx.", _dyld_get_image_vmaddr_slide(0));

    Class KeybagSyncOperation = NSClassFromString(@"KeybagSyncOperation");
    NSLog(@"Get KeybagSyncOperation class: %p.", KeybagSyncOperation);

    Method method = class_getInstanceMethod(KeybagSyncOperation, NSSelectorFromString(@"run"));
    NSLog(@"Get run method: %p.", method);

    IMP imp = method_getImplementation(method);
    NSLog(@"Get run implementation: %p.", imp);

#if __arm64e__
    const uint32_t *kbsync_caller = (uint32_t *)make_sym_readable((void *)imp);
#else
    const uint32_t *kbsync_caller = (uint32_t *)imp;
#endif
    const uint8_t mov_w1_0xb[] = {
        0x61, 0x01, 0x80, 0x52,
    };
    CFDataRef kbsync = NULL;
    while (*kbsync_caller++ != *(uint32_t *)&mov_w1_0xb[0]);
    NSLog(@"Parsed kbsync caller: %p.", kbsync_caller);

    // decode the bl instruction to get the real kbsyn callee
    // 31 30 29 28 27 26 25 ... 0
    //  1  0  0  1  0  1  - imm -
    int blopcode = *(int *)kbsync_caller;
    int blmask = 0xFC000000;
    if (blopcode & (1 << 26)) {
        // sign extend
        blopcode |= blmask;
    } else {
        blopcode &= ~blmask;
    }

    long kbsync_entry = (long)kbsync_caller + (blopcode << 2);
    NSLog(@"Decoded kbsync entry: 0x%lx.", kbsync_entry);

    // call the kbsync calc entry
#if __arm64e__
    kbsync_entry = (long)make_sym_callable((void *)kbsync_entry);
#endif
    
    NSMutableDictionary *returnDict = [NSMutableDictionary dictionary];
    SSAccount *account = [[SSAccountStore defaultStore] activeAccount];
    unsigned long long accountID = [[account uniqueIdentifier] unsignedLongLongValue];
    NSLog(@"Got account %@, id %llu", account, accountID);
    dispatch_sync(account.backingAccountAccessQueue, ^{
        returnDict[@"backingIdentifier"] = [[account backingAccount] identifier];
    });
    if ([account ITunesPassSerialNumber]) {
        returnDict[@"iTunesPassSerialNumber"] = [account ITunesPassSerialNumber];
    }
    if ([account altDSID]) {
        returnDict[@"altDSID"] = [account altDSID];
    }
    if ([account accountName]) {
        returnDict[@"accountName"] = [account accountName];
    }
    if ([account firstName]) {
        returnDict[@"firstName"] = [account firstName];
    }
    if ([account lastName]) {
        returnDict[@"lastName"] = [account lastName];
    }
    if ([account localizedName]) {
        returnDict[@"localizedName"] = [account localizedName];
    }
    if ([account storeFrontIdentifier]) {
        returnDict[@"storeFrontIdentifier"] = [account storeFrontIdentifier];
    }

    returnDict[@"active"] = @([account isActive]);
    returnDict[@"authenticated"] = @([account isAuthenticated]);
    returnDict[@"uniqueIdentifier"] = @(accountID);
    returnDict[@"guid"] = [[NSClassFromString(@"ISDevice") sharedInstance] guid];

    NSURL *url = [NSURL URLWithString:args[@"url"]];

    ISStoreURLOperation *operation = [[NSClassFromString(@"ISStoreURLOperation") alloc] init];
    NSURLRequest *urlRequest = [operation newRequestWithURL:url];
    NSDictionary *headerFields = [urlRequest allHTTPHeaderFields];
    returnDict[@"headerFields"] = headerFields;

    kbsync = ((CFDataRef (*)(long, int))kbsync_entry)(accountID, 0xB);
    NSString *kbsyncString = [(__bridge NSData *)kbsync base64EncodedStringWithOptions:kNilOptions];
    NSLog(@"kbsync_result_callback %@", kbsyncString);
    returnDict[@"kbsync"] = kbsyncString;

    if (kbsync) {
        return (CFDataRef)CFBridgingRetain([NSPropertyListSerialization dataWithPropertyList:returnDict format:NSPropertyListBinaryFormat_v1_0 options:kNilOptions error:nil]);
    }

    NSLog(@"kbsync_result_callback %@", @"error, you should download something in the App Store to init kbsync.");
    return nil;
}

%group AppleMediaServices

/* @class AMSURLSession */
// - (int)_prepareRequest:(int)arg2 properties:(int)arg3 error:(int)arg4

%hook AMSURLSession
- (id)_prepareRequest:(NSURLRequest *)urlRequest properties:(id)arg3 error:(id*)arg4 {
    NSMutableDictionary *headerFields = [[urlRequest allHTTPHeaderFields] mutableCopy];
    [headerFields removeObjectForKey:@"Cookie"];
    NSLog(@"AMSURLSession %@", headerFields); %log;
    return %orig(urlRequest, arg3, arg4);
}
%end

%end

%ctor {
    
    if ([[[NSProcessInfo processInfo] processName] isEqualToString:@"itunesstored"]) {

        static CFMessagePortRef localPort = nil;
        static dispatch_once_t onceToken;

        dispatch_once(&onceToken, ^{
            rocketbootstrap_unlock("com.darwindev.kbsync.port");
            localPort = CFMessagePortCreateLocal(
                nil,
                CFSTR("com.darwindev.kbsync.port"),
                Callback,
                nil,
                nil
            );
        });
        
        CFRunLoopSourceRef runLoopSource =
            CFMessagePortCreateRunLoopSource(nil, localPort, 0);

        CFRunLoopAddSource(
            CFRunLoopGetCurrent(),
            runLoopSource,
            kCFRunLoopCommonModes
        );

        rocketbootstrap_cfmessageportexposelocal(localPort);
    } else {

        %init(AppleMediaServices);
    }
}
