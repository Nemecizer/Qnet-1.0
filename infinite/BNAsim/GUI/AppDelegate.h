/*
 * AppDelegate.h - Application delegate header
 */

#import <Cocoa/Cocoa.h>

@class NetworkEditorView;
@class PropertiesPanel;
@class ConsoleView;

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>

@property (strong, nonatomic) NSWindow *mainWindow;
@property (strong, nonatomic) NetworkEditorView *networkEditor;
@property (strong, nonatomic) PropertiesPanel *propertiesPanel;
@property (strong, nonatomic) ConsoleView *consoleView;

// Simulation settings
@property (nonatomic) double warmupTime;
@property (nonatomic) double runLength;
@property (nonatomic) int replications;
@property (nonatomic) unsigned long seed;
@property (nonatomic) BOOL useFiniteBuffers;
@property (nonatomic) int defaultBufferCapacity;
@property (copy, nonatomic) NSString *blockingProtocol;

// Actions
- (void)newDocument:(id)sender;
- (void)openDocument:(id)sender;
- (void)saveDocument:(id)sender;
- (void)saveDocumentAs:(id)sender;
- (void)exportSimFile:(id)sender;
- (void)runSimulation:(id)sender;
- (void)runFiniteSimulation:(id)sender;
- (void)showSimulationSettings:(id)sender;

// Logging
- (void)logMessage:(NSString *)message;
- (void)logError:(NSString *)message;
- (void)clearConsole;

@end
