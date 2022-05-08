#import <stdio.h>

#import <Foundation/Foundation.h>
#import <rocketbootstrap/rocketbootstrap.h>


int main(int argc, char *argv[], char *envp[]) {

    if (argc != 2) {
        fprintf(stderr, "usage: %s url\n", argv[0]);
        return 1;
    }

    CFMessagePortRef remotePort = rocketbootstrap_cfmessageportcreateremote(NULL, CFSTR("com.darwindev.kbsync.port"));

	if (!remotePort) {
		fprintf(stderr, "no remote port found\n");
		return 1;
	}

    NSString *urlString = [NSString stringWithUTF8String:argv[1]];
    CFDataRef data = (__bridge CFDataRef)[NSPropertyListSerialization dataWithPropertyList:@{@"url": urlString} format:NSPropertyListBinaryFormat_v1_0 options:kNilOptions error:nil];
    CFDataRef returnData = NULL;
    SInt32 status =
        CFMessagePortSendRequest(
            remotePort,
            0x1111,
            data,
            3.0,
            3.0,
            kCFRunLoopDefaultMode,
            &returnData
        );
    
    CFRelease(data);
    CFMessagePortInvalidate(remotePort);
    CFRelease(remotePort);

    if (status != kCFMessagePortSuccess) {
		fprintf(stderr, "CFMessagePortSendRequest %d\n", status);
		return 1;
    }

    id returnObj = [NSPropertyListSerialization propertyListWithData:(__bridge NSData *)returnData options:kNilOptions format:nil error:nil];
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:returnObj options:(NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys) error:nil];
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
	printf("%s\n", [jsonString UTF8String]);
    CFRelease(returnData);
	return 0;
}
