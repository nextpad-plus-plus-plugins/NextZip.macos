// NextZipMenuBuilder — builds the standalone app's main menu bar
// programmatically (no nib).

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class NextZipAppDelegate;

@interface NextZipMenuBuilder : NSObject
+ (NSMenu*)buildMainMenuForDelegate:(NextZipAppDelegate*)delegate;
@end

NS_ASSUME_NONNULL_END
