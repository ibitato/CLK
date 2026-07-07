//
//  CSElectronDebug.h
//  4AD — Acorn Electron debug panel for CLK
//

#import <Cocoa/Cocoa.h>

@class CSMachine;

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// 4AD: project ROMImages root (--fourad-rom-path), checked before bundle/support dirs.
void CSSetFourADROMImagesRoot(NSString *_Nullable path);
NSString *_Nullable CSFourADROMImagesRoot(void);

#ifdef __cplusplus
}
#endif

@interface CSElectronDebugPanel : NSWindowController

+ (BOOL)isAvailableForMachine:(CSMachine *)machine;
- (instancetype)initWithMachine:(CSMachine *)machine;
- (void)openDebugWindow;
- (void)refresh;

@end

NS_ASSUME_NONNULL_END
