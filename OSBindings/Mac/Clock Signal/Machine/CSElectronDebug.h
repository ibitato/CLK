//
//  CSElectronDebug.h
//  4AD — Acorn Electron debug panel for CLK
//

#import <Cocoa/Cocoa.h>

@class CSMachine;

NS_ASSUME_NONNULL_BEGIN

@interface CSElectronDebugPanel : NSWindowController

+ (BOOL)isAvailableForMachine:(CSMachine *)machine;
- (instancetype)initWithMachine:(CSMachine *)machine;
- (void)openDebugWindow;
- (void)refresh;

@end

NS_ASSUME_NONNULL_END
