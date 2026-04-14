#import "ObjCExceptionGuard.h"

@implementation ObjCExceptionGuard
+ (BOOL)tryBlock:(void (^)(void))block {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"[MacKeySwitch] Caught NSException: %@ - %@", exception.name, exception.reason);
        return NO;
    }
}
@end
