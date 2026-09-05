/*
 * PropertiesPanel.h - Properties panel for editing selected objects
 */

#import <Cocoa/Cocoa.h>
#import "NetworkModel.h"

@class NetworkEditorView;

@interface PropertiesPanel : NSView

@property (weak, nonatomic) NetworkEditorView *networkEditor;

- (void)showStationProperties:(StationNode *)station;
- (void)showClassProperties:(CustomerClass *)cls withStations:(NSArray<StationNode *> *)stations;
- (void)showConnectionProperties:(Connection *)conn;
- (void)clearProperties;
- (void)clearSelection;

// Convenience methods
- (void)showStation:(StationNode *)station;
- (void)showClass:(CustomerClass *)cls;
- (void)showConnection:(Connection *)conn;

@end
