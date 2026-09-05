/*
 * AppDelegate.m - Application delegate implementation
 */

#import "AppDelegate.h"
#import "NetworkEditorView.h"
#import "PropertiesPanel.h"
#import "ConsoleView.h"
#import "ToolPalette.h"
#import "NetworkModel.h"

@implementation AppDelegate {
    NSString *_currentFilePath;
    NSSplitView *_mainSplitView;
    NSSplitView *_rightSplitView;
    ToolPalette *_toolPalette;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // Initialize default settings
    self.warmupTime = 10000.0;
    self.runLength = 100000.0;
    self.replications = 30;
    self.seed = 12345;
    self.useFiniteBuffers = NO;
    self.defaultBufferCapacity = 10;
    self.blockingProtocol = @"BAS";
    _currentFilePath = nil;

    [self createMainWindow];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)createMainWindow {
    // Create main window
    NSRect screenRect = [[NSScreen mainScreen] visibleFrame];
    NSRect windowRect = NSMakeRect(
        screenRect.origin.x + 50,
        screenRect.origin.y + 50,
        MIN(1400, screenRect.size.width - 100),
        MIN(900, screenRect.size.height - 100)
    );

    self.mainWindow = [[NSWindow alloc]
        initWithContentRect:windowRect
                  styleMask:NSWindowStyleMaskTitled |
                           NSWindowStyleMaskClosable |
                           NSWindowStyleMaskMiniaturizable |
                           NSWindowStyleMaskResizable
                    backing:NSBackingStoreBuffered
                      defer:NO];

    [self.mainWindow setTitle:@"Jackson Network Simulator - Untitled"];
    [self.mainWindow setDelegate:self];
    [self.mainWindow setMinSize:NSMakeSize(800, 600)];

    // Create the tool palette (left side)
    _toolPalette = [[ToolPalette alloc] initWithFrame:NSMakeRect(0, 0, 80, windowRect.size.height)];

    // Create the network editor (center)
    NSScrollView *editorScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 700, 600)];
    self.networkEditor = [[NetworkEditorView alloc] initWithFrame:NSMakeRect(0, 0, 2000, 2000)];
    [editorScrollView setDocumentView:self.networkEditor];
    [editorScrollView setHasVerticalScroller:YES];
    [editorScrollView setHasHorizontalScroller:YES];
    [editorScrollView setAutohidesScrollers:YES];
    [editorScrollView setBorderType:NSBezelBorder];

    // Create the properties panel (right side)
    self.propertiesPanel = [[PropertiesPanel alloc] initWithFrame:NSMakeRect(0, 0, 300, 400)];

    // Create the console view (bottom right)
    self.consoleView = [[ConsoleView alloc] initWithFrame:NSMakeRect(0, 0, 300, 200)];

    // Right split view (properties on top, console on bottom)
    _rightSplitView = [[NSSplitView alloc] initWithFrame:NSMakeRect(0, 0, 300, 600)];
    [_rightSplitView setVertical:NO];
    [_rightSplitView addSubview:self.propertiesPanel];
    [_rightSplitView addSubview:self.consoleView];
    [_rightSplitView setDividerStyle:NSSplitViewDividerStyleThin];

    // Main split view (palette | editor | right panel)
    _mainSplitView = [[NSSplitView alloc] initWithFrame:[[self.mainWindow contentView] bounds]];
    [_mainSplitView setVertical:YES];
    [_mainSplitView addSubview:_toolPalette];
    [_mainSplitView addSubview:editorScrollView];
    [_mainSplitView addSubview:_rightSplitView];
    [_mainSplitView setDividerStyle:NSSplitViewDividerStyleThin];
    [_mainSplitView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    // Set split view positions
    [_mainSplitView setPosition:80 ofDividerAtIndex:0];
    [_mainSplitView setPosition:windowRect.size.width - 320 ofDividerAtIndex:1];
    [_rightSplitView setPosition:400 ofDividerAtIndex:0];

    [[self.mainWindow contentView] addSubview:_mainSplitView];

    // Connect components
    [_toolPalette setNetworkEditor:self.networkEditor];
    [self.networkEditor setPropertiesPanel:self.propertiesPanel];
    [self.networkEditor setAppDelegate:self];
    [self.propertiesPanel setNetworkEditor:self.networkEditor];

    [self.mainWindow makeKeyAndOrderFront:nil];

    [self logMessage:@"Jackson Network Simulator ready."];
    [self logMessage:@"Select a tool from the palette and click on the canvas to add stations."];
}

#pragma mark - File Operations

- (void)newDocument:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Create New Network?"];
    [alert setInformativeText:@"This will clear the current network. Unsaved changes will be lost."];
    [alert addButtonWithTitle:@"New"];
    [alert addButtonWithTitle:@"Cancel"];

    if ([alert runModal] == NSAlertFirstButtonReturn) {
        [[self.networkEditor model] clear];
        [self.networkEditor setNeedsDisplay:YES];
        [self.propertiesPanel clearSelection];
        _currentFilePath = nil;
        [self.mainWindow setTitle:@"Jackson Network Simulator - Untitled"];
        [self logMessage:@"New network created."];
    }
}

- (void)openDocument:(id)sender {
    NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    [openPanel setAllowedFileTypes:@[@"jnet", @"sim"]];
    [openPanel setAllowsMultipleSelection:NO];

    if ([openPanel runModal] == NSModalResponseOK) {
        NSURL *url = [[openPanel URLs] firstObject];
        [self loadNetworkFromURL:url];
    }
}

- (void)loadNetworkFromURL:(NSURL *)url {
    NSError *error;
    NSString *content = [NSString stringWithContentsOfURL:url
                                                 encoding:NSUTF8StringEncoding
                                                    error:&error];
    if (error) {
        [self logError:[NSString stringWithFormat:@"Failed to open file: %@", error.localizedDescription]];
        return;
    }

    // Parse and load the network
    if ([[self.networkEditor model] loadFromString:content]) {
        _currentFilePath = [url path];
        [self.mainWindow setTitle:[NSString stringWithFormat:@"Jackson Network Simulator - %@",
                                   [[url path] lastPathComponent]]];
        [self.networkEditor setNeedsDisplay:YES];
        [self logMessage:[NSString stringWithFormat:@"Loaded network from %@", [url path]]];
    } else {
        [self logError:@"Failed to parse network file."];
    }
}

- (void)saveDocument:(id)sender {
    if (_currentFilePath) {
        [self saveToPath:_currentFilePath];
    } else {
        [self saveDocumentAs:sender];
    }
}

- (void)saveDocumentAs:(id)sender {
    NSSavePanel *savePanel = [NSSavePanel savePanel];
    [savePanel setAllowedFileTypes:@[@"jnet"]];
    [savePanel setNameFieldStringValue:@"network.jnet"];

    if ([savePanel runModal] == NSModalResponseOK) {
        NSURL *url = [savePanel URL];
        [self saveToPath:[url path]];
        _currentFilePath = [url path];
        [self.mainWindow setTitle:[NSString stringWithFormat:@"Jackson Network Simulator - %@",
                                   [[url path] lastPathComponent]]];
    }
}

- (void)saveToPath:(NSString *)path {
    NSString *content = [[self.networkEditor model] saveToString];
    NSError *error;
    [content writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error];

    if (error) {
        [self logError:[NSString stringWithFormat:@"Failed to save: %@", error.localizedDescription]];
    } else {
        [self logMessage:[NSString stringWithFormat:@"Saved to %@", path]];
    }
}

- (void)exportSimFile:(id)sender {
    NSSavePanel *savePanel = [NSSavePanel savePanel];
    [savePanel setAllowedFileTypes:@[@"sim"]];
    [savePanel setNameFieldStringValue:@"network.sim"];

    if ([savePanel runModal] == NSModalResponseOK) {
        NSURL *url = [savePanel URL];
        [self exportSimToPath:[url path]];
    }
}

- (void)exportSimToPath:(NSString *)path {
    NSString *content = [self generateSimFileContent];
    NSError *error;
    [content writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error];

    if (error) {
        [self logError:[NSString stringWithFormat:@"Failed to export: %@", error.localizedDescription]];
    } else {
        [self logMessage:[NSString stringWithFormat:@"Exported .sim file to %@", path]];
    }
}

- (NSString *)generateSimFileContent {
    NetworkModel *model = [self.networkEditor model];
    NSMutableString *content = [NSMutableString string];

    // Header comment
    [content appendString:@"# Jackson Network Simulation Input File\n"];
    [content appendString:@"# Generated by Jackson Network Simulator GUI\n\n"];

    // Network dimensions
    [content appendFormat:@"stations %ld\n", (long)[model stationCount]];
    [content appendFormat:@"classes %ld\n\n", (long)[model classCount]];

    // Simulation parameters
    [content appendFormat:@"warmup %.0f\n", self.warmupTime];
    [content appendFormat:@"run_length %.0f\n", self.runLength];
    [content appendFormat:@"replications %d\n", self.replications];
    [content appendFormat:@"seed %lu\n", self.seed];

    // Finite buffer settings
    if (self.useFiniteBuffers) {
        [content appendFormat:@"\nblocking %@\n", self.blockingProtocol];
        [content appendFormat:@"default_buffer %d\n", self.defaultBufferCapacity];

        // Per-station buffer capacities
        for (StationNode *station in [model stations]) {
            if (station.bufferCapacity != self.defaultBufferCapacity) {
                [content appendFormat:@"station_buffer %ld %ld\n",
                 (long)station.stationId, (long)station.bufferCapacity];
            }
        }
    }

    [content appendString:@"\n"];

    // Class definitions
    for (CustomerClass *cls in [model customerClasses]) {
        [content appendFormat:@"class %ld\n", (long)cls.classId];
        [content appendFormat:@"    arrival %@\n", [cls arrivalDistributionString]];
        [content appendFormat:@"    station %ld\n", (long)cls.constituencyStation];
        [content appendFormat:@"    service %@\n", [cls serviceDistributionString]];
        [content appendFormat:@"    routing %@\n", [cls routingString]];
        [content appendString:@"end_class\n\n"];
    }

    return content;
}

#pragma mark - Simulation

- (void)runSimulation:(id)sender {
    [self runSimulationWithFiniteBuffers:NO];
}

- (void)runFiniteSimulation:(id)sender {
    [self runSimulationWithFiniteBuffers:YES];
}

- (void)runSimulationWithFiniteBuffers:(BOOL)finite {
    NetworkModel *model = [self.networkEditor model];

    // Validate network
    NSString *validationError = [model validate];
    if (validationError) {
        [self logError:[NSString stringWithFormat:@"Validation error: %@", validationError]];
        return;
    }

    if ([model stationCount] == 0) {
        [self logError:@"No stations in network. Add at least one station."];
        return;
    }

    if ([model classCount] == 0) {
        [self logError:@"No customer classes defined. Add at least one class."];
        return;
    }

    // Create temp file for simulation input
    NSString *tempDir = NSTemporaryDirectory();
    NSString *simPath = [tempDir stringByAppendingPathComponent:@"network_temp.sim"];
    NSString *resultsPath = [tempDir stringByAppendingPathComponent:@"network_temp_results.txt"];

    // Export sim file
    self.useFiniteBuffers = finite;
    [self exportSimToPath:simPath];

    // Find simulator executable
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSString *simExec = finite ?
        [bundlePath stringByAppendingPathComponent:@"Contents/MacOS/jackson_sim_finite"] :
        [bundlePath stringByAppendingPathComponent:@"Contents/MacOS/jackson_sim"];

    // If not in bundle, try current directory
    if (![[NSFileManager defaultManager] fileExistsAtPath:simExec]) {
        NSString *cwd = [[NSFileManager defaultManager] currentDirectoryPath];
        simExec = finite ?
            [cwd stringByAppendingPathComponent:@"jackson_sim_finite"] :
            [cwd stringByAppendingPathComponent:@"jackson_sim"];
    }

    // Also try parent directory (where simulators might be)
    if (![[NSFileManager defaultManager] fileExistsAtPath:simExec]) {
        NSString *parentDir = [[[NSFileManager defaultManager] currentDirectoryPath]
                               stringByDeletingLastPathComponent];
        simExec = finite ?
            [parentDir stringByAppendingPathComponent:@"jackson_sim_finite"] :
            [parentDir stringByAppendingPathComponent:@"jackson_sim"];
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:simExec]) {
        [self logError:[NSString stringWithFormat:@"Simulator not found. Please build %@ first.",
                        finite ? @"jackson_sim_finite" : @"jackson_sim"]];
        return;
    }

    [self logMessage:[NSString stringWithFormat:@"Running %@ simulation...",
                      finite ? @"finite buffer" : @"infinite buffer"]];
    [self clearConsole];

    // Run simulation in background
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSTask *task = [[NSTask alloc] init];
        [task setExecutableURL:[NSURL fileURLWithPath:simExec]];
        [task setArguments:@[simPath,
                             @"-w", [NSString stringWithFormat:@"%.0f", self.warmupTime],
                             @"-r", [NSString stringWithFormat:@"%.0f", self.runLength],
                             @"-n", [NSString stringWithFormat:@"%d", self.replications],
                             @"-s", [NSString stringWithFormat:@"%lu", self.seed]]];

        NSPipe *outputPipe = [NSPipe pipe];
        NSPipe *errorPipe = [NSPipe pipe];
        [task setStandardOutput:outputPipe];
        [task setStandardError:errorPipe];

        NSError *error = nil;
        [task launchAndReturnError:&error];

        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self logError:[NSString stringWithFormat:@"Failed to launch simulator: %@",
                                error.localizedDescription]];
            });
            return;
        }

        [task waitUntilExit];

        NSData *outputData = [[outputPipe fileHandleForReading] readDataToEndOfFile];
        NSString *output = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];

        NSData *errorData = [[errorPipe fileHandleForReading] readDataToEndOfFile];
        NSString *errorOutput = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];

        dispatch_async(dispatch_get_main_queue(), ^{
            if ([task terminationStatus] == 0) {
                [self logMessage:@"Simulation completed successfully.\n"];
                [self logMessage:output];
            } else {
                [self logError:@"Simulation failed."];
                if ([errorOutput length] > 0) {
                    [self logError:errorOutput];
                }
                [self logMessage:output];
            }
        });
    });
}

- (void)showSimulationSettings:(id)sender {
    // Create settings dialog
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Simulation Settings"];
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];

    // Create accessory view with settings
    NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 200)];

    // Warmup time
    NSTextField *warmupLabel = [self createLabel:@"Warmup Time:" frame:NSMakeRect(10, 170, 100, 20)];
    NSTextField *warmupField = [self createTextField:[NSString stringWithFormat:@"%.0f", self.warmupTime]
                                               frame:NSMakeRect(120, 170, 170, 22)];
    [accessory addSubview:warmupLabel];
    [accessory addSubview:warmupField];

    // Run length
    NSTextField *runLabel = [self createLabel:@"Run Length:" frame:NSMakeRect(10, 140, 100, 20)];
    NSTextField *runField = [self createTextField:[NSString stringWithFormat:@"%.0f", self.runLength]
                                            frame:NSMakeRect(120, 140, 170, 22)];
    [accessory addSubview:runLabel];
    [accessory addSubview:runField];

    // Replications
    NSTextField *repLabel = [self createLabel:@"Replications:" frame:NSMakeRect(10, 110, 100, 20)];
    NSTextField *repField = [self createTextField:[NSString stringWithFormat:@"%d", self.replications]
                                            frame:NSMakeRect(120, 110, 170, 22)];
    [accessory addSubview:repLabel];
    [accessory addSubview:repField];

    // Seed
    NSTextField *seedLabel = [self createLabel:@"Random Seed:" frame:NSMakeRect(10, 80, 100, 20)];
    NSTextField *seedField = [self createTextField:[NSString stringWithFormat:@"%lu", self.seed]
                                             frame:NSMakeRect(120, 80, 170, 22)];
    [accessory addSubview:seedLabel];
    [accessory addSubview:seedField];

    // Buffer capacity (for finite)
    NSTextField *bufLabel = [self createLabel:@"Default Buffer:" frame:NSMakeRect(10, 50, 100, 20)];
    NSTextField *bufField = [self createTextField:[NSString stringWithFormat:@"%d", self.defaultBufferCapacity]
                                            frame:NSMakeRect(120, 50, 170, 22)];
    [accessory addSubview:bufLabel];
    [accessory addSubview:bufField];

    // Blocking protocol
    NSTextField *blockLabel = [self createLabel:@"Blocking:" frame:NSMakeRect(10, 20, 100, 20)];
    NSPopUpButton *blockPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(120, 18, 170, 25) pullsDown:NO];
    [blockPopup addItemsWithTitles:@[@"BAS (After Service)", @"BBS (Before Service)", @"RS (Rejection)"]];
    if ([self.blockingProtocol isEqualToString:@"BAS"]) [blockPopup selectItemAtIndex:0];
    else if ([self.blockingProtocol isEqualToString:@"BBS"]) [blockPopup selectItemAtIndex:1];
    else [blockPopup selectItemAtIndex:2];
    [accessory addSubview:blockLabel];
    [accessory addSubview:blockPopup];

    [alert setAccessoryView:accessory];

    if ([alert runModal] == NSAlertFirstButtonReturn) {
        self.warmupTime = [[warmupField stringValue] doubleValue];
        self.runLength = [[runField stringValue] doubleValue];
        self.replications = [[repField stringValue] intValue];
        self.seed = [[seedField stringValue] integerValue];
        self.defaultBufferCapacity = [[bufField stringValue] intValue];

        NSInteger blockIndex = [blockPopup indexOfSelectedItem];
        if (blockIndex == 0) self.blockingProtocol = @"BAS";
        else if (blockIndex == 1) self.blockingProtocol = @"BBS";
        else self.blockingProtocol = @"RS";

        [self logMessage:@"Simulation settings updated."];
    }
}

- (NSTextField *)createLabel:(NSString *)text frame:(NSRect)frame {
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    [label setStringValue:text];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [label setEditable:NO];
    [label setSelectable:NO];
    return label;
}

- (NSTextField *)createTextField:(NSString *)text frame:(NSRect)frame {
    NSTextField *field = [[NSTextField alloc] initWithFrame:frame];
    [field setStringValue:text];
    return field;
}

#pragma mark - Logging

- (void)logMessage:(NSString *)message {
    [self.consoleView appendMessage:message];
}

- (void)logError:(NSString *)message {
    [self.consoleView appendError:message];
}

- (void)clearConsole {
    [self.consoleView clear];
}

#pragma mark - Window Delegate

- (BOOL)windowShouldClose:(NSWindow *)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Quit Jackson Network Simulator?"];
    [alert setInformativeText:@"Unsaved changes will be lost."];
    [alert addButtonWithTitle:@"Quit"];
    [alert addButtonWithTitle:@"Cancel"];

    return [alert runModal] == NSAlertFirstButtonReturn;
}

- (void)windowWillClose:(NSNotification *)notification {
    [NSApp terminate:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

@end
