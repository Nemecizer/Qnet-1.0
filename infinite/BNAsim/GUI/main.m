/*
 * main.m - Jackson Network Simulator GUI
 *
 * A native macOS application for building and simulating
 * multi-class Jackson queueing networks.
 *
 * Compile: ./build.sh
 * Run: open JacksonNetworkSimulator.app
 */

#import <Cocoa/Cocoa.h>

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];

        // Load the app delegate
        Class appDelegateClass = NSClassFromString(@"AppDelegate");
        if (appDelegateClass) {
            id appDelegate = [[appDelegateClass alloc] init];
            [NSApp setDelegate:appDelegate];
        }

        // Set activation policy for proper app behavior
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        // Create the menu bar
        NSMenu *menuBar = [[NSMenu alloc] init];

        // Application menu
        NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:appMenuItem];
        NSMenu *appMenu = [[NSMenu alloc] init];
        [appMenu addItemWithTitle:@"About Jackson Network Simulator"
                           action:@selector(orderFrontStandardAboutPanel:)
                    keyEquivalent:@""];
        [appMenu addItem:[NSMenuItem separatorItem]];
        [appMenu addItemWithTitle:@"Quit"
                           action:@selector(terminate:)
                    keyEquivalent:@"q"];
        [appMenuItem setSubmenu:appMenu];

        // File menu
        NSMenuItem *fileMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:fileMenuItem];
        NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
        [fileMenu addItemWithTitle:@"New Network"
                            action:@selector(newDocument:)
                     keyEquivalent:@"n"];
        [fileMenu addItemWithTitle:@"Open..."
                            action:@selector(openDocument:)
                     keyEquivalent:@"o"];
        [fileMenu addItem:[NSMenuItem separatorItem]];
        [fileMenu addItemWithTitle:@"Save"
                            action:@selector(saveDocument:)
                     keyEquivalent:@"s"];
        [fileMenu addItemWithTitle:@"Save As..."
                            action:@selector(saveDocumentAs:)
                     keyEquivalent:@"S"];
        [fileMenu addItem:[NSMenuItem separatorItem]];
        [fileMenu addItemWithTitle:@"Export .sim File..."
                            action:@selector(exportSimFile:)
                     keyEquivalent:@"e"];
        [fileMenuItem setSubmenu:fileMenu];

        // Edit menu
        NSMenuItem *editMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:editMenuItem];
        NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
        [editMenu addItemWithTitle:@"Undo"
                            action:@selector(undo:)
                     keyEquivalent:@"z"];
        [editMenu addItemWithTitle:@"Redo"
                            action:@selector(redo:)
                     keyEquivalent:@"Z"];
        [editMenu addItem:[NSMenuItem separatorItem]];
        [editMenu addItemWithTitle:@"Delete"
                            action:@selector(delete:)
                     keyEquivalent:@"\b"];
        [editMenuItem setSubmenu:editMenu];

        // Simulation menu
        NSMenuItem *simMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:simMenuItem];
        NSMenu *simMenu = [[NSMenu alloc] initWithTitle:@"Simulation"];
        [simMenu addItemWithTitle:@"Run Simulation"
                           action:@selector(runSimulation:)
                    keyEquivalent:@"r"];
        [simMenu addItemWithTitle:@"Run with Finite Buffers"
                           action:@selector(runFiniteSimulation:)
                    keyEquivalent:@"R"];
        [simMenu addItem:[NSMenuItem separatorItem]];
        [simMenu addItemWithTitle:@"Simulation Settings..."
                           action:@selector(showSimulationSettings:)
                    keyEquivalent:@","];
        [simMenuItem setSubmenu:simMenu];

        // Window menu
        NSMenuItem *windowMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:windowMenuItem];
        NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
        [windowMenu addItemWithTitle:@"Minimize"
                              action:@selector(performMiniaturize:)
                       keyEquivalent:@"m"];
        [windowMenu addItemWithTitle:@"Zoom"
                              action:@selector(performZoom:)
                       keyEquivalent:@""];
        [windowMenuItem setSubmenu:windowMenu];

        [NSApp setMainMenu:menuBar];

        // Run the application
        [NSApp run];
    }
    return 0;
}
