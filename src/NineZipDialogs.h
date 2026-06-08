/*
 * NineZipDialogs.h — modal Cocoa dialogs modeled on the Windows 7-Zip windows
 * (Add to Archive, Extract, Checksum/Info). Built programmatically; each returns
 * a plain options object (nil = the user cancelled).
 *
 * NineZip 2026 (GPL).
 */
#import <Cocoa/Cocoa.h>

// Result of the "Add to Archive" dialog.
@interface NZAddOptions : NSObject
@property (copy)   NSString* archivePath;   // full destination path
@property (copy)   NSString* format;        // 7z|zip|tar|gzip|bzip2|xz
@property (assign) int        level;        // 0,1,3,5,7,9
@property (copy)   NSString* password;      // @"" = none
@property (assign) BOOL       encryptNames; // 7z only
@property (assign) BOOL       deleteAfter;
@end

// Result of the "Extract" dialog.
@interface NZExtractOptions : NSObject
@property (copy)   NSString* destDir;       // directory to extract into
@property (assign) BOOL       intoSubfolder;// create a folder named after the archive
@property (assign) int        pathMode;     // 0 = full paths, 1 = no paths (flatten)
@property (copy)   NSString* password;      // @"" = none
@end

@interface NineZipDialogs : NSObject
// Returns nil if cancelled. `inputs` = the filesystem paths being compressed.
+ (nullable NZAddOptions*)runAddForInputs:(nonnull NSArray<NSString*>*)inputs;
// Returns nil if cancelled. `archivePath` seeds the default destination.
+ (nullable NZExtractOptions*)runExtractForArchive:(nonnull NSString*)archivePath;
// A simple scrollable monospaced info window with an OK button (checksums, test result).
+ (void)showInfoTitle:(nonnull NSString*)title text:(nonnull NSString*)text;
@end
