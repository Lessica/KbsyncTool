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
- (NSURLRequest *)newRequestWithURL:(NSURL *)url;
@end

@interface AMSURLRequest : NSMutableURLRequest
- (AMSURLRequest *)initWithRequest:(NSURLRequest *)urlRequest;
@end

@interface AMSBagNetworkDataSource : NSObject
@end

@interface AMSPromise : NSObject
- (NSDictionary *)resultWithError:(NSError **)errPtr;
@end

@interface AMSAnisette : NSObject
+ (AMSBagNetworkDataSource *)createBagForSubProfile;
+ (AMSPromise *)headersForRequest:(AMSURLRequest *)urlRequest account:(ACAccount *)account type:(long long)type bag:(AMSBagNetworkDataSource *)bagSource;
@end

@interface ACAccountStore (AMS)
+ (ACAccountStore *)ams_sharedAccountStore;
- (ACAccount *)ams_activeiTunesAccount;
@end


static inline char itoh(int i) {
    if (i > 9) return 'A' + (i - 10);
    return '0' + i;
}

static NSString * NSDataToHex(NSData *data) {
    NSUInteger i, len;
    unsigned char *buf, *bytes;
    
    len = data.length;
    bytes = (unsigned char*)data.bytes;
    buf = (unsigned char *)malloc(len*2);
    
    for (i=0; i<len; i++) {
        buf[i*2] = itoh((bytes[i] >> 4) & 0xF);
        buf[i*2+1] = itoh(bytes[i] & 0xF);
    }
    
    return [[NSString alloc] initWithBytesNoCopy:buf
                                          length:len*2
                                        encoding:NSASCIIStringEncoding
                                    freeWhenDone:YES];
}


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
    AMSURLRequest *amsRequest = [[NSClassFromString(@"AMSURLRequest") alloc] initWithRequest:urlRequest];
    NSMutableDictionary *headerFields = [[urlRequest allHTTPHeaderFields] mutableCopy];

    ACAccount *amsAccount = [[ACAccountStore ams_sharedAccountStore] ams_activeiTunesAccount];
    AMSBagNetworkDataSource *bagSource = [NSClassFromString(@"AMSAnisette") createBagForSubProfile];
    NSDictionary *amsHeader1 = [[NSClassFromString(@"AMSAnisette") headersForRequest:amsRequest account:amsAccount type:1 bag:bagSource] resultWithError:nil];
    if ([amsHeader1 isKindOfClass:[NSDictionary class]]) {
        [headerFields addEntriesFromDictionary:amsHeader1];
    }

    NSDictionary *amsHeader2 = [[NSClassFromString(@"AMSAnisette") headersForRequest:amsRequest account:amsAccount type:2 bag:bagSource] resultWithError:nil];
    if ([amsHeader2 isKindOfClass:[NSDictionary class]]) {
        [headerFields addEntriesFromDictionary:amsHeader2];
    }

    returnDict[@"headers"] = headerFields;

    kbsync = ((CFDataRef (*)(long, int))kbsync_entry)(accountID, 0xB);
    NSString *kbsyncString = nil;
    if ([args[@"kbsyncType"] isEqualToString:@"hex"]) {
        kbsyncString = NSDataToHex(CFBridgingRelease(kbsync));
    } else {
        kbsyncString = [CFBridgingRelease(kbsync) base64EncodedStringWithOptions:kNilOptions];
    }
    NSLog(@"kbsync_result_callback %@", kbsyncString);
    returnDict[@"kbsync"] = kbsyncString;

    if (kbsync) {
        return (CFDataRef)CFBridgingRetain([NSPropertyListSerialization dataWithPropertyList:returnDict format:NSPropertyListBinaryFormat_v1_0 options:kNilOptions error:nil]);
    }

    NSLog(@"kbsync_result_callback %@", @"error, you should download something in the App Store to init kbsync.");
    return nil;
}

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
            CFMessagePortCreateRunLoopSource(kCFAllocatorDefault, localPort, 0);

        CFRunLoopAddSource(
            CFRunLoopGetCurrent(),
            runLoopSource,
            kCFRunLoopCommonModes
        );

        rocketbootstrap_cfmessageportexposelocal(localPort);
    }
}
