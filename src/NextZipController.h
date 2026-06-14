/*
 * NextZipController.h — the NextZip archive-manager window controller.
 * Scaffold: opens an archive via NextZipEngine and lists its entries in a
 * sortable NSTableView (the seed of the 7-Zip-File-Manager-style UI). Toolbar,
 * breadcrumb navigation, descend-into-folders/nested-archives, extract, create,
 * and drag-out come next.
 *
 * NextZip (Nextpad++ archive plugin) 2026 (GPL).
 */
#import <Cocoa/Cocoa.h>

struct NppData;

@interface NextZipController : NSObject
- (instancetype)initWithNpp:(const NppData*)npp;
- (void)togglePanel;                   // "Show NextZip" — register/show/hide the dock panel
- (void)showOpenPanel;                 // "Open Archive…" menu command
- (void)openArchiveAtPath:(NSString*)path;
- (void)openCurrentEditorFile;         // open the file in the active editor tab, if an archive
- (void)handleFileSaved:(NSString*)path; // NPPN_FILESAVED → write a temp back into its archive
- (void)showAbout;
@end
