//
//  CSElectronDebug.mm
//  4AD — Acorn Electron debug panel for CLK
//

#import "CSElectronDebug.h"
#import "CSMachine.h"

#include "Machines/Acorn/Electron/Electron.hpp"

static NSString *FourADROMImagesRoot = nil;

extern "C" {

void CSSetFourADROMImagesRoot(NSString *path) {
	if(path.length == 0) {
		FourADROMImagesRoot = nil;
		return;
	}
	FourADROMImagesRoot = [path copy];
}

NSString *CSFourADROMImagesRoot(void) {
	return FourADROMImagesRoot;
}

} // extern "C"

@interface CSElectronDebugPanel ()
@property(nonatomic, weak) CSMachine *machine;
@property(nonatomic, strong) NSTextView *registersView;
@property(nonatomic, strong) NSTextView *disasmView;
@property(nonatomic, strong) NSTextView *memoryView;
@property(nonatomic, strong) NSTextView *screenView;
@property(nonatomic, strong) NSTextField *breakpointField;
@property(nonatomic, strong) NSTextField *statusField;
@property(nonatomic, strong) NSButton *enabledButton;
@property(nonatomic, strong) NSButton *trapBrkButton;
@property(nonatomic, strong) NSTimer *refreshTimer;
@end

@implementation CSElectronDebugPanel

+ (BOOL)isAvailableForMachine:(CSMachine *)machine {
	return machine.electronDebugAvailable;
}

- (instancetype)initWithMachine:(CSMachine *)machine {
	self = [super initWithWindow:nil];
	if(self) {
		_machine = machine;
		[self buildWindow];
	}
	return self;
}

- (void)buildWindow {
	const CGFloat width = 920;
	const CGFloat height = 680;
	NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(120, 120, width, height)
		styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable)
		backing:NSBackingStoreBuffered defer:NO];
	window.title = @"Electron Debug — 4AD";
	self.window = window;

	NSView *content = window.contentView;

	_statusField = [self makeLabel:@"" frame:NSMakeRect(12, height - 34, width - 24, 20)];
	_statusField.font = [NSFont boldSystemFontOfSize:12];
	[content addSubview:_statusField];

	_enabledButton = [self makeCheckbox:@"Debug enabled" frame:NSMakeRect(12, height - 58, 140, 22) action:@selector(toggleEnabled:)];
	_enabledButton.state = NSControlStateValueOn;
	[content addSubview:_enabledButton];

	_trapBrkButton = [self makeCheckbox:@"Trap BRK" frame:NSMakeRect(160, height - 58, 120, 22) action:@selector(toggleTrapBrk:)];
	_trapBrkButton.state = NSControlStateValueOn;
	[content addSubview:_trapBrkButton];

	[content addSubview:[self makeButton:@"Continue" frame:NSMakeRect(300, height - 60, 90, 24) action:@selector(continueExecution:)]];
	[content addSubview:[self makeButton:@"Step" frame:NSMakeRect(396, height - 60, 70, 24) action:@selector(stepExecution:)]];
	[content addSubview:[self makeButton:@"Pause" frame:NSMakeRect(472, height - 60, 70, 24) action:@selector(pauseExecution:)]];
	[content addSubview:[self makeButton:@"Refresh" frame:NSMakeRect(548, height - 60, 80, 24) action:@selector(refresh)]];

	_breakpointField = [[NSTextField alloc] initWithFrame:NSMakeRect(640, height - 60, 90, 24)];
	_breakpointField.placeholderString = @"&8023";
	_breakpointField.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
	[content addSubview:_breakpointField];
	[content addSubview:[self makeButton:@"Add BP" frame:NSMakeRect(736, height - 60, 72, 24) action:@selector(addBreakpoint:)]];
	[content addSubview:[self makeButton:@"Clear BP" frame:NSMakeRect(814, height - 60, 88, 24) action:@selector(clearBreakpoints:)]];

	_registersView = [self makeTextView:NSMakeRect(12, 360, 280, 250) inView:content];
	_disasmView = [self makeTextView:NSMakeRect(304, 360, 280, 250) inView:content];
	_memoryView = [self makeTextView:NSMakeRect(596, 360, 312, 250) inView:content];
	_screenView = [self makeTextView:NSMakeRect(12, 12, 896, 336) inView:content];

	[content addSubview:[self sectionLabel:@"CPU + BASIC workspace" frame:NSMakeRect(12, 614, 280, 18)]];
	[content addSubview:[self sectionLabel:@"Disassembly @ PC" frame:NSMakeRect(304, 614, 280, 18)]];
	[content addSubview:[self sectionLabel:@"Memory dump" frame:NSMakeRect(596, 614, 312, 18)]];
	[content addSubview:[self sectionLabel:@"Screen text (40x25 @ HIMEM)" frame:NSMakeRect(12, 352, 400, 18)]];

	[_machine electronDebugSetEnabled:YES];
	[self refresh];
}

- (NSTextField *)makeLabel:(NSString *)text frame:(NSRect)frame {
	NSTextField *field = [[NSTextField alloc] initWithFrame:frame];
	field.stringValue = text;
	field.bezeled = NO;
	field.drawsBackground = NO;
	field.editable = NO;
	field.selectable = NO;
	return field;
}

- (NSTextField *)sectionLabel:(NSString *)text frame:(NSRect)frame {
	NSTextField *field = [self makeLabel:text frame:frame];
	field.font = [NSFont boldSystemFontOfSize:11];
	return field;
}

- (NSButton *)makeButton:(NSString *)title frame:(NSRect)frame action:(SEL)action {
	NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
	button.frame = frame;
	button.bezelStyle = NSBezelStyleRounded;
	return button;
}

- (NSButton *)makeCheckbox:(NSString *)title frame:(NSRect)frame action:(SEL)action {
	NSButton *button = [NSButton checkboxWithTitle:title target:self action:action];
	button.frame = frame;
	return button;
}

- (NSTextView *)makeTextView:(NSRect)frame inView:(NSView *)parent {
	NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:frame];
	scroll.hasVerticalScroller = YES;
	scroll.borderType = NSBezelBorder;
	NSTextView *view = [[NSTextView alloc] initWithFrame:scroll.contentView.bounds];
	view.minSize = NSMakeSize(0, frame.size.height);
	view.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
	view.verticallyResizable = YES;
	view.horizontallyResizable = NO;
	view.autoresizingMask = NSViewWidthSizable;
	view.textContainer.containerSize = NSMakeSize(frame.size.width, FLT_MAX);
	view.textContainer.widthTracksTextView = YES;
	view.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
	view.editable = NO;
	view.selectable = YES;
	scroll.documentView = view;
	[parent addSubview:scroll];
	return view;
}

- (void)openDebugWindow {
	[self showWindow:nil];
	[self.window makeKeyAndOrderFront:nil];
	if(!_refreshTimer) {
		_refreshTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
	}
}

- (void)toggleEnabled:(id)sender {
	[_machine electronDebugSetEnabled:(((NSButton *)sender).state == NSControlStateValueOn)];
	[self refresh];
}

- (void)toggleTrapBrk:(id)sender {
	[_machine electronDebugSetTrapBrk:(((NSButton *)sender).state == NSControlStateValueOn)];
}

- (void)continueExecution:(id)sender {
	(void)sender;
	[_machine electronDebugContinue];
}

- (void)stepExecution:(id)sender {
	(void)sender;
	[_machine electronDebugStep];
}

- (void)pauseExecution:(id)sender {
	(void)sender;
	[_machine electronDebugPause];
}

- (uint16_t)parseAddress:(NSString *)text {
	NSString *trimmed = [[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] uppercaseString];
	if([trimmed hasPrefix:@"&"]) trimmed = [trimmed substringFromIndex:1];
	const unsigned value = [[NSString stringWithFormat:@"0x%@", trimmed] longLongValue];
	return uint16_t(value & 0xffff);
}

- (void)addBreakpoint:(id)sender {
	(void)sender;
	const uint16_t address = [self parseAddress:_breakpointField.stringValue];
	[_machine electronDebugAddBreakpoint:address];
	[self refresh];
}

- (void)clearBreakpoints:(id)sender {
	(void)sender;
	[_machine electronDebugClearBreakpoints];
	[self refresh];
}

- (NSString *)formatMemory:(NSData *)data base:(uint16_t)base {
	const uint8_t *bytes = (const uint8_t *)data.bytes;
	NSMutableString *out = [NSMutableString string];
	for(NSUInteger row = 0; row < data.length; row += 16) {
		[out appendFormat:@"%04X: ", base + (uint16_t)row];
		for(NSUInteger col = 0; col < 16 && row + col < data.length; col++) {
			[out appendFormat:@"%02X ", bytes[row + col]];
		}
		[out appendString:@"  "];
		for(NSUInteger col = 0; col < 16 && row + col < data.length; col++) {
			const uint8_t ch = bytes[row + col];
			[out appendFormat:@"%c", (ch >= 32 && ch < 127) ? ch : '.'];
		}
		[out appendString:@"\n"];
	}
	return out;
}

- (void)refresh {
	if(!_machine.electronDebugAvailable) {
		_statusField.stringValue = @"Debug not available for this machine.";
		return;
	}

	NSDictionary *snap = [_machine electronDebugSnapshot];
	if(!snap) return;

	const BOOL paused = [snap[@"paused"] boolValue];
	const BOOL enabled = [snap[@"enabled"] boolValue];
	NSString *reason = snap[@"pauseReason"] ?: @"";
	_statusField.stringValue = paused
		? [NSString stringWithFormat:@"PAUSED — %@", reason]
		: (enabled ? @"Running (debug on)" : @"Running (debug off)");

	_registersView.string = [NSString stringWithFormat:
		@"PC    &%04X\n"
		@"A     &%02X\n"
		@"X     &%02X\n"
		@"Y     &%02X\n"
		@"SP    &%02X\n"
		@"P     &%02X\n"
		@"\n"
		@"PAGE  &%04X\n"
		@"TOP   &%04X\n"
		@"HIMEM &%04X\n"
		@"FRE   %d bytes\n"
		@"\n"
		@"Breakpoints:\n%@",
		[snap[@"pc"] unsignedShortValue],
		[snap[@"a"] unsignedCharValue],
		[snap[@"x"] unsignedCharValue],
		[snap[@"y"] unsignedCharValue],
		[snap[@"sp"] unsignedCharValue],
		[snap[@"p"] unsignedCharValue],
		[snap[@"page"] unsignedShortValue],
		[snap[@"top"] unsignedShortValue],
		[snap[@"himem"] unsignedShortValue],
		[snap[@"freeBytes"] intValue],
		snap[@"breakpoints"] ?: @"none"];

	_disasmView.string = snap[@"disassembly"] ?: @"";
	_screenView.string = snap[@"screenText"] ?: @"";

	NSData *memory = snap[@"memoryDump"];
	if(memory) {
		_memoryView.string = [self formatMemory:memory base:[snap[@"pc"] unsignedShortValue] & 0xfff0];
	}
}

@end
