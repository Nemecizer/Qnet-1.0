/*
 * ToolPalette.m - Tool palette for selecting editing tools
 */

#import "ToolPalette.h"

@interface ToolPalette ()
@property (strong, nonatomic) NSMutableArray<NSButton *> *toolButtons;
@property (nonatomic) EditorTool selectedTool;
@end

@implementation ToolPalette

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _toolButtons = [NSMutableArray array];
        _selectedTool = ToolSelect;
        [self setupButtons];
    }
    return self;
}

- (void)setupButtons {
    NSArray *toolNames = @[@"Select", @"Station", @"Class", @"Connection", @"Delete"];
    NSArray *toolTips = @[
        @"Select and move objects",
        @"Add a new station (server)",
        @"Add a customer class to a station",
        @"Create routing connection between classes",
        @"Delete selected object"
    ];

    CGFloat buttonHeight = 32;
    CGFloat buttonWidth = self.bounds.size.width - 20;
    CGFloat startY = self.bounds.size.height - 50;
    CGFloat spacing = 40;

    for (NSInteger i = 0; i < toolNames.count; i++) {
        NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(10, startY - i * spacing, buttonWidth, buttonHeight)];
        [button setTitle:toolNames[i]];
        [button setToolTip:toolTips[i]];
        [button setButtonType:NSButtonTypePushOnPushOff];
        [button setBezelStyle:NSBezelStyleRounded];
        [button setTarget:self];
        [button setAction:@selector(toolButtonClicked:)];
        [button setTag:i];

        if (i == 0) {
            [button setState:NSControlStateValueOn];
        }

        [self addSubview:button];
        [self.toolButtons addObject:button];
    }

    // Add separator
    NSBox *separator = [[NSBox alloc] initWithFrame:NSMakeRect(10, startY - toolNames.count * spacing - 10, buttonWidth, 1)];
    [separator setBoxType:NSBoxSeparator];
    [self addSubview:separator];

    // Add help label
    NSTextField *helpLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 10, buttonWidth, 60)];
    [helpLabel setStringValue:@"Tip: Click on canvas to place objects. Drag to move."];
    [helpLabel setBezeled:NO];
    [helpLabel setDrawsBackground:NO];
    [helpLabel setEditable:NO];
    [helpLabel setSelectable:NO];
    [helpLabel setFont:[NSFont systemFontOfSize:10]];
    [helpLabel setTextColor:[NSColor secondaryLabelColor]];
    [helpLabel setAlignment:NSTextAlignmentCenter];
    [self addSubview:helpLabel];
}

- (void)toolButtonClicked:(NSButton *)sender {
    EditorTool newTool = (EditorTool)sender.tag;
    [self selectTool:newTool];
}

- (void)selectTool:(EditorTool)tool {
    self.selectedTool = tool;

    // Update button states
    for (NSButton *button in self.toolButtons) {
        [button setState:(button.tag == tool) ? NSControlStateValueOn : NSControlStateValueOff];
    }

    // Update network editor
    if (self.networkEditor) {
        self.networkEditor.currentTool = tool;
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    // Draw background
    [[NSColor windowBackgroundColor] setFill];
    NSRectFill(dirtyRect);

    // Draw title
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:13],
        NSForegroundColorAttributeName: [NSColor labelColor]
    };
    [@"Tools" drawAtPoint:NSMakePoint(10, self.bounds.size.height - 25) withAttributes:attrs];
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
    [super resizeSubviewsWithOldSize:oldSize];

    CGFloat buttonWidth = self.bounds.size.width - 20;
    CGFloat startY = self.bounds.size.height - 50;
    CGFloat spacing = 40;

    for (NSInteger i = 0; i < self.toolButtons.count; i++) {
        NSButton *button = self.toolButtons[i];
        [button setFrame:NSMakeRect(10, startY - i * spacing, buttonWidth, 32)];
    }
}

@end
