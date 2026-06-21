#import "NextZipMenuBuilder.h"
#import "NextZipAppDelegate.h"

static NSMenuItem* addItem(NSMenu* m, NSString* title, SEL action,
                           NSString* key, NSEventModifierFlags mods, id target) {
	NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];
	if (mods != 0) item.keyEquivalentModifierMask = mods;
	item.target = target;
	[m addItem:item];
	return item;
}

@implementation NextZipMenuBuilder

+ (NSMenu*)buildMainMenuForDelegate:(NextZipAppDelegate*)delegate {
	NSMenu* root = [[NSMenu alloc] initWithTitle:@""];
	[root addItem:[self _appMenu]];
	[root addItem:[self _fileMenuForDelegate:delegate]];
	[root addItem:[self _editMenu]];
	[root addItem:[self _windowMenu]];
	[root addItem:[self _helpMenuForDelegate:delegate]];
	return root;
}

#pragma mark - Application menu

+ (NSMenuItem*)_appMenu {
	NSMenuItem* appMenuItem = [[NSMenuItem alloc] init];
	NSMenu* appMenu = [[NSMenu alloc] initWithTitle:@"NextZip"];

	addItem(appMenu, @"About NextZip", @selector(orderFrontStandardAboutPanel:), @"", 0, NSApp);
	[appMenu addItem:[NSMenuItem separatorItem]];

	NSMenuItem* services = [[NSMenuItem alloc] initWithTitle:@"Services" action:nil keyEquivalent:@""];
	NSMenu* servicesMenu = [[NSMenu alloc] initWithTitle:@"Services"];
	services.submenu = servicesMenu;
	[NSApp setServicesMenu:servicesMenu];
	[appMenu addItem:services];
	[appMenu addItem:[NSMenuItem separatorItem]];

	addItem(appMenu, @"Hide NextZip", @selector(hide:), @"h", 0, NSApp);
	addItem(appMenu, @"Hide Others", @selector(hideOtherApplications:), @"h",
	        NSEventModifierFlagOption | NSEventModifierFlagCommand, NSApp);
	addItem(appMenu, @"Show All", @selector(unhideAllApplications:), @"", 0, NSApp);
	[appMenu addItem:[NSMenuItem separatorItem]];
	addItem(appMenu, @"Quit NextZip", @selector(terminate:), @"q", 0, NSApp);

	appMenuItem.submenu = appMenu;
	return appMenuItem;
}

#pragma mark - File menu

+ (NSMenuItem*)_fileMenuForDelegate:(NextZipAppDelegate*)delegate {
	NSMenuItem* fileMenuItem = [[NSMenuItem alloc] init];
	NSMenu* fileMenu = [[NSMenu alloc] initWithTitle:@"File"];

	addItem(fileMenu, @"New Window", @selector(newWindow:), @"n", 0, delegate);
	addItem(fileMenu, @"Open Archive…", @selector(openArchive:), @"o", 0, delegate);

	NSMenuItem* openRecentItem = [[NSMenuItem alloc] initWithTitle:@"Open Recent" action:nil keyEquivalent:@""];
	NSMenu* openRecentMenu = [[NSMenu alloc] initWithTitle:@"Open Recent"];
	openRecentMenu.delegate = delegate;
	openRecentMenu.autoenablesItems = NO;
	openRecentItem.submenu = openRecentMenu;
	[fileMenu addItem:openRecentItem];

	[fileMenu addItem:[NSMenuItem separatorItem]];
	addItem(fileMenu, @"Close Window", @selector(performClose:), @"w", 0, nil);

	fileMenuItem.submenu = fileMenu;
	return fileMenuItem;
}

#pragma mark - Edit menu (standard, for text fields in dialogs)

+ (NSMenuItem*)_editMenu {
	NSMenuItem* editMenuItem = [[NSMenuItem alloc] init];
	NSMenu* editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];

	addItem(editMenu, @"Undo", @selector(undo:), @"z", 0, nil);
	addItem(editMenu, @"Redo", @selector(redo:), @"z",
	        NSEventModifierFlagCommand | NSEventModifierFlagShift, nil);
	[editMenu addItem:[NSMenuItem separatorItem]];
	addItem(editMenu, @"Cut", @selector(cut:), @"x", 0, nil);
	addItem(editMenu, @"Copy", @selector(copy:), @"c", 0, nil);
	addItem(editMenu, @"Paste", @selector(paste:), @"v", 0, nil);
	addItem(editMenu, @"Select All", @selector(selectAll:), @"a", 0, nil);

	editMenuItem.submenu = editMenu;
	return editMenuItem;
}

#pragma mark - Window menu

+ (NSMenuItem*)_windowMenu {
	NSMenuItem* windowMenuItem = [[NSMenuItem alloc] init];
	NSMenu* windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];

	addItem(windowMenu, @"Minimize", @selector(performMiniaturize:), @"m", 0, nil);
	addItem(windowMenu, @"Zoom", @selector(performZoom:), @"", 0, nil);
	[windowMenu addItem:[NSMenuItem separatorItem]];
	addItem(windowMenu, @"Bring All to Front", @selector(arrangeInFront:), @"", 0, NSApp);

	[NSApp setWindowsMenu:windowMenu];
	windowMenuItem.submenu = windowMenu;
	return windowMenuItem;
}

#pragma mark - Help menu

+ (NSMenuItem*)_helpMenuForDelegate:(NextZipAppDelegate*)delegate {
	NSMenuItem* helpMenuItem = [[NSMenuItem alloc] init];
	NSMenu* helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];

	addItem(helpMenu, @"NextZip on GitHub", @selector(showNextZipHelp:), @"", 0, delegate);

	[NSApp setHelpMenu:helpMenu];
	helpMenuItem.submenu = helpMenu;
	return helpMenuItem;
}

@end
