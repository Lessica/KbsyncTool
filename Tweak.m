#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <stdio.h>

#import "pac_helper.h"
#import <Accounts/Accounts.h>
#import <CaptainHook/CaptainHook.h>
#import <Foundation/Foundation.h>
#import <libSandy.h>
#import <rocketbootstrap/rocketbootstrap.h>
#import <rootless.h>

@interface MicroPaymentQueueRequest : NSObject
@property(retain) NSNumber *userIdentifier;
@property(retain) NSNumber *rangeStartIdentifier;
@property(retain) NSNumber *rangeEndIdentifier;
@property(assign) BOOL needsAuthentication;
- (id)_ntsQueryParameters:(id *)parameters;
- (id)_ntsClientApplication:(id *)application;
- (id)description;
- (id)newStoreURLOperation:(id *)operation;
- (id)init;
@end

@interface SSAccount : NSObject
@property(nonatomic, readonly) ACAccount *backingAccount;
@property(nonatomic, retain) dispatch_queue_t backingAccountAccessQueue;
@property(copy) NSString *ITunesPassSerialNumber;
@property(copy) NSString *altDSID;
@property(copy) NSString *accountName;
@property(copy) NSString *firstName;
@property(copy) NSString *lastName;
@property(readonly) NSString *localizedName;
@property(copy) NSString *storeFrontIdentifier;
@property(getter=isActive) bool active;
@property(getter=isAuthenticated) bool authenticated;
@property(retain) NSNumber *uniqueIdentifier;
@end

@interface SSAccountStore : NSObject
+ (SSAccountStore *)defaultStore;
@property(readonly) SSAccount *activeAccount;
@end

@interface ISDevice : NSObject
+ (ISDevice *)sharedInstance;
@property(readonly) NSString *guid;
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
+ (AMSPromise *)headersForRequest:(AMSURLRequest *)urlRequest
                          account:(ACAccount *)account
                             type:(long long)type
                              bag:(AMSBagNetworkDataSource *)bagSource;
@end

@interface ACAccountStore (AMS)
+ (ACAccountStore *)ams_sharedAccountStore;
- (ACAccount *)ams_activeiTunesAccount;
@end

@interface SSVFairPlaySubscriptionController : NSObject
- (BOOL)generateSubscriptionBagRequestWithAccountUniqueIdentifier:(unsigned long long)arg1
                                                  transactionType:(unsigned int)arg2
                                                    machineIDData:(NSData *)arg3
                                     returningSubscriptionBagData:(NSData **)arg4
                                                            error:(NSError **)arg5;
@end

@interface PurchaseOperation : NSObject
- (SSVFairPlaySubscriptionController *)_fairPlaySubscriptionController;
@end

static inline char itoh(int i) {
    if (i > 9)
        return 'A' + (i - 10);
    return '0' + i;
}

static NSString *NSDataToHex(NSData *data) {
    NSUInteger i, len;
    unsigned char *buf, *bytes;

    len = data.length;
    bytes = (unsigned char *)data.bytes;
    buf = (unsigned char *)malloc(len * 2);

    for (i = 0; i < len; i++) {
        buf[i * 2] = itoh((bytes[i] >> 4) & 0xF);
        buf[i * 2 + 1] = itoh(bytes[i] & 0xF);
    }

    return [[NSString alloc] initWithBytesNoCopy:buf length:len * 2 encoding:NSASCIIStringEncoding freeWhenDone:YES];
}

static CFDataRef Callback(CFMessagePortRef port, SInt32 messageID, CFDataRef data, void *info) {
    // ...

    NSDictionary *args = [NSPropertyListSerialization propertyListWithData:(__bridge NSData *)data
                                                                   options:kNilOptions
                                                                    format:nil
                                                                     error:nil];

    SSAccount *account = [[SSAccountStore defaultStore] activeAccount];
    unsigned long long accountID = [[account uniqueIdentifier] unsignedLongLongValue];
    NSLog(@"Got account %@, id %llu", account, accountID);

    NSLog(@"Start to calc kbsync and sbsync, base offset: 0x%lx.", _dyld_get_image_vmaddr_slide(0));
    CFDataRef kbsync = NULL;
    {
        Class KeybagSyncOperationCls = NSClassFromString(@"KeybagSyncOperation");
        NSLog(@"Got KeybagSyncOperation class: %p.", KeybagSyncOperationCls);

        Method RunMethod = class_getInstanceMethod(KeybagSyncOperationCls, NSSelectorFromString(@"run"));
        NSLog(@"Got -run method: %p.", RunMethod);

        IMP RunIMP = method_getImplementation(RunMethod);
        NSLog(@"Got -run implementation: %p.", RunIMP);

#if __arm64e__
        const uint32_t *kbsync_caller = (uint32_t *)make_sym_readable((void *)RunIMP);
#else
        const uint32_t *kbsync_caller = (uint32_t *)RunIMP;
#endif
        const uint8_t mov_w1_0xb[] = {
            0x61,
            0x01,
            0x80,
            0x52,
        };
        while (*kbsync_caller++ != *(uint32_t *)&mov_w1_0xb[0])
            ;
        NSLog(@"Parsed kbsync caller: %p.", kbsync_caller);

        // decode the bl instruction to get the real kbsync callee
        // 31 30 29 28 27 26 25 ... 0
        //  1  0  0  1  0  1  - imm -
        int blopcode, blmask;
        blopcode = *(int *)kbsync_caller;
        blmask = 0xFC000000;
        if (blopcode & (1 << 26)) {
            // sign extend
            blopcode |= blmask;
        } else {
            blopcode &= ~blmask;
        }

        long kbsync_entry = (long)kbsync_caller + (blopcode << 2);
        NSLog(@"Decoded kbsync entry: 0x%lx.", kbsync_entry);

#if __arm64e__
        kbsync_entry = (long)make_sym_callable((void *)kbsync_entry);
#endif

        // call the kbsync calc entry
        kbsync = ((CFDataRef(*)(long, int))kbsync_entry)(accountID, 0xB);
        NSLog(@"Got kbsync: %@", (__bridge NSData *)kbsync);
    }

    NSData *sbsync = NULL;
    do {
        Class PurchaseOperationCls = NSClassFromString(@"PurchaseOperation");
        NSLog(@"Got PurchaseOperation class: %p.", PurchaseOperationCls);

        Method FairMethod = class_getInstanceMethod(
            PurchaseOperationCls, NSSelectorFromString(@"_addFairPlayToRequestProperties:withAccountIdentifier:"));
        NSLog(@"Got -_addFairPlayToRequestProperties:withAccountIdentifier: method: %p.", FairMethod);

        IMP FairIMP = method_getImplementation(FairMethod);
        NSLog(@"Got -_addFairPlayToRequestProperties:withAccountIdentifier: implementation: %p.", FairIMP);

#if __arm64e__
        const uint32_t *machine_id_caller = (uint32_t *)make_sym_readable((void *)FairIMP);
#else
        const uint32_t *machine_id_caller = (uint32_t *)FairIMP;
#endif
        const uint8_t movn_x0_0x0[] = {
            0x00,
            0x00,
            0x80,
            0x92,
        };
        CFDataRef machine_id = NULL;
        while (*machine_id_caller++ != *(uint32_t *)&movn_x0_0x0[0])
            ;
        NSLog(@"Parsed machine_id caller: %p.", machine_id_caller);

        // decode the bl instruction to get the real kbsyn callee
        // 31 30 29 28 27 26 25 ... 0
        //  1  0  0  1  0  1  - imm -
        int blopcode, blmask;
        blopcode = *(int *)machine_id_caller;
        blmask = 0xFC000000;
        if (blopcode & (1 << 26)) {
            // sign extend
            blopcode |= blmask;
            blopcode ^= blmask;
        } else {
            blopcode &= ~blmask;
        }

        long machine_id_entry = (long)machine_id_caller + (blopcode << 2);
        NSLog(@"Decoded machine_id entry: 0x%lx.", machine_id_entry);

#if __arm64e__
        machine_id_entry = (long)make_sym_callable((void *)machine_id_entry);
#endif

        // call the machine_id calc entry
        char *md_str = NULL;
        size_t md_len = 0;
        char *amd_str = NULL;
        size_t amd_len = 0;
        int md_ret = ((int (*)(long, char **, size_t *, char **, size_t *))machine_id_entry)(
            0xffffffffffffffff, &md_str, &md_len, &amd_str, &amd_len);
        if (md_ret) {
            break;
        }

        NSData *mdData = [[NSData alloc] initWithBytesNoCopy:md_str length:md_len freeWhenDone:NO];
        NSLog(@"Got Machine ID data: %@", [mdData base64EncodedStringWithOptions:kNilOptions]);

        NSData *amdData = [[NSData alloc] initWithBytesNoCopy:amd_str length:amd_len freeWhenDone:NO];
        NSLog(@"Got Apple Machine ID data: %@", [amdData base64EncodedStringWithOptions:kNilOptions]);

        NSError *sbsyncErr = nil;
        PurchaseOperation *purchaseOp = [[NSClassFromString(@"PurchaseOperation") alloc] init];
        SSVFairPlaySubscriptionController *fairPlayCtrl = [purchaseOp _fairPlaySubscriptionController];
        BOOL sbsyncSucceed =
            [fairPlayCtrl generateSubscriptionBagRequestWithAccountUniqueIdentifier:accountID
                                                                    transactionType:0x138 /* PurchaseOperation */
                                                                      machineIDData:mdData
                                                       returningSubscriptionBagData:&sbsync
                                                                              error:&sbsyncErr];
        if (!sbsyncSucceed) {
            NSLog(@"Failed to generate subscription bag request: %@", sbsyncErr);
            break;
        }

        NSLog(@"Got sbsync: %@", sbsync);
    } while (0);

    NSMutableDictionary *returnDict = [NSMutableDictionary dictionary];
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
    NSDictionary *amsHeader1 = [[NSClassFromString(@"AMSAnisette") headersForRequest:amsRequest
                                                                             account:amsAccount
                                                                                type:1
                                                                                 bag:bagSource] resultWithError:nil];
    if ([amsHeader1 isKindOfClass:[NSDictionary class]]) {
        [headerFields addEntriesFromDictionary:amsHeader1];
    }

    NSDictionary *amsHeader2 = [[NSClassFromString(@"AMSAnisette") headersForRequest:amsRequest
                                                                             account:amsAccount
                                                                                type:2
                                                                                 bag:bagSource] resultWithError:nil];
    if ([amsHeader2 isKindOfClass:[NSDictionary class]]) {
        [headerFields addEntriesFromDictionary:amsHeader2];
    }

    [headerFields removeObjectForKey:@"Authorization"];

    returnDict[@"headers"] = headerFields;

    NSString *kbsyncString = nil;
    if ([args[@"kbsyncType"] isEqualToString:@"hex"]) {
        kbsyncString = NSDataToHex(CFBridgingRelease(kbsync));
    } else {
        kbsyncString = [CFBridgingRelease(kbsync) base64EncodedStringWithOptions:kNilOptions];
    }
    NSLog(@"kbsync_result_callback %@", kbsyncString);
    returnDict[@"kbsync"] = kbsyncString;

    NSString *sbsyncString = nil;
    if ([args[@"sbsyncType"] isEqualToString:@"hex"]) {
        sbsyncString = NSDataToHex(sbsync);
    } else {
        sbsyncString = [sbsync base64EncodedStringWithOptions:kNilOptions];
    }
    NSLog(@"sbsync_result_callback %@", sbsyncString);
    returnDict[@"sbsync"] = sbsyncString;

    if (kbsync || sbsync) {
        return (CFDataRef)CFBridgingRetain([NSPropertyListSerialization
            dataWithPropertyList:returnDict
                          format:NSPropertyListBinaryFormat_v1_0
                         options:kNilOptions
                           error:nil]);
    }

    NSLog(@"kbsync_result_callback %@", @"error, you should download something in the App Store to init kbsync.");
    return nil;
}

CHConstructor {

    if ([[[NSProcessInfo processInfo] processName] isEqualToString:@"itunesstored"]) {

        static CFMessagePortRef localPort = nil;
        static dispatch_once_t onceToken;

        dispatch_once(&onceToken, ^{
          void *sandyHandle = dlopen(ROOT_PATH("/usr/lib/libsandy.dylib"), RTLD_LAZY);
          if (sandyHandle) {
              os_log_info(OS_LOG_DEFAULT, "libSandy loaded");
              int (*__dyn_libSandy_applyProfile)(const char *profileName) =
                  (int (*)(const char *))dlsym(sandyHandle, "libSandy_applyProfile");
              if (__dyn_libSandy_applyProfile) {
                  __dyn_libSandy_applyProfile("KbsyncTool");
              }
          }

          kern_return_t unlockRet = rocketbootstrap_unlock("com.darwindev.kbsync.port");
          if (unlockRet != KERN_SUCCESS) {
              os_log_error(OS_LOG_DEFAULT, "Failed to unlock com.darwindev.kbsync.port: %d", unlockRet);
          }

          localPort = CFMessagePortCreateLocal(nil, CFSTR("com.darwindev.kbsync.port"), Callback, nil, nil);
        });

        if (!localPort) {
            return;
        }

        os_log_info(OS_LOG_DEFAULT, "Registering com.darwindev.kbsync.port: %p", localPort);

        CFRunLoopSourceRef runLoopSource = CFMessagePortCreateRunLoopSource(kCFAllocatorDefault, localPort, 0);

        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);

        rocketbootstrap_cfmessageportexposelocal(localPort);
    }
}
