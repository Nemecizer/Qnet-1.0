/*
 * NetworkEditorView.h - Main canvas for network editing
 */

#import <Cocoa/Cocoa.h>

@class NetworkModel;
@class PropertiesPanel;
@class AppDelegate;

typedef NS_ENUM(NSInteger, EditorTool) {
    ToolSelect = 0,
    ToolStation,
    ToolClass,
    ToolConnection,
    ToolDelete
};

@interface NetworkEditorView : NSView

@property (strong, nonatomic, readonly) NetworkModel *model;
@property (weak, nonatomic) PropertiesPanel *propertiesPanel;
@property (weak, nonatomic) AppDelegate *appDelegate;
@property (nonatomic) EditorTool currentTool;

- (void)setNeedsDisplayForModel;
- (void)deleteSelectedObject;

@end
