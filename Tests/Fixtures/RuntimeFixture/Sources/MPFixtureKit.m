#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface MPFixtureLateTarget : NSObject
- (BOOL)lateValue;
- (NSInteger)lateInteger;
- (NSString *)lateGreeting:(NSString *)name;
- (CGRect)lateRect:(CGRect)rect;
- (NSRange)lateRange:(NSRange)range;
- (NSInteger)lateBlockResult:(NSInteger (^)(NSInteger value))block;
@end

@implementation MPFixtureLateTarget

- (BOOL)lateValue {
    return NO;
}

- (NSInteger)lateInteger {
    return 42;
}

- (NSString *)lateGreeting:(NSString *)name {
    return [NSString stringWithFormat:@"Late hello, %@", name];
}

- (CGRect)lateRect:(CGRect)rect {
    return CGRectInset(rect, 2, 2);
}

- (NSRange)lateRange:(NSRange)range {
    return NSMakeRange(range.location + 1, range.length);
}

- (NSInteger)lateBlockResult:(NSInteger (^)(NSInteger value))block {
    return block == nil ? 0 : block(9);
}

@end

@interface NSObject (MPFixtureRuntimeExtras)
- (BOOL)mp_fixtureCategoryFlag;
@end

@implementation NSObject (MPFixtureRuntimeExtras)

- (BOOL)mp_fixtureCategoryFlag {
    return NO;
}

@end
