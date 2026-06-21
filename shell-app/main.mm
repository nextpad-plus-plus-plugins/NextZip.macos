// NextZip.app — entry point.
//
// Standalone macOS app that hosts the same NextZipController the Nextpad++
// plugin uses, in regular NSWindows with a real Cocoa menu bar. Same source
// tree, same 7-Zip engine, no Nextpad++ dependency.

#import <Cocoa/Cocoa.h>
#import "NextZipAppDelegate.h"

int main(int argc, const char* argv[]) {
	@autoreleasepool {
		NSApplication* app = [NSApplication sharedApplication];
		// Regular activation policy — dock icon, menu bar, Cmd-Tab.
		[app setActivationPolicy:NSApplicationActivationPolicyRegular];

		NextZipAppDelegate* delegate = [[NextZipAppDelegate alloc] init];
		app.delegate = delegate;

		[app run];
	}
	return 0;
}
