/*
 * ToolPalette.h - Tool palette for selecting editing tools
 */

#import <Cocoa/Cocoa.h>
#import "NetworkEditorView.h"

@interface ToolPalette : NSView

@property (weak, nonatomic) NetworkEditorView *networkEditor;

@end
