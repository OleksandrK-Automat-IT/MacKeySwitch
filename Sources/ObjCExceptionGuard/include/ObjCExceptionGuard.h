#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Bridges @try/@catch to Swift. Returns YES if the block completed without an NSException.
@interface ObjCExceptionGuard : NSObject
+ (BOOL)tryBlock:(void (^)(void))block NS_SWIFT_NAME(tryBlock(_:));
@end

NS_ASSUME_NONNULL_END
