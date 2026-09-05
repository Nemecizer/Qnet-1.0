/*
 * ConsoleView.m - Console output view for simulation results and messages
 */

#import "ConsoleView.h"

@interface ConsoleView ()
@property (strong, nonatomic) NSTextField *titleLabel;
@property (strong, nonatomic) NSScrollView *scrollView;
@property (strong, nonatomic) NSTextView *textView;
@property (strong, nonatomic) NSButton *clearButton;
@end

@implementation ConsoleView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    // Title label
    self.titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(10, self.bounds.size.height - 30, 100, 20)];
    [self.titleLabel setStringValue:@"Console"];
    [self.titleLabel setBezeled:NO];
    [self.titleLabel setDrawsBackground:NO];
    [self.titleLabel setEditable:NO];
    [self.titleLabel setSelectable:NO];
    [self.titleLabel setFont:[NSFont boldSystemFontOfSize:13]];
    [self addSubview:self.titleLabel];

    // Clear button
    self.clearButton = [[NSButton alloc] initWithFrame:NSMakeRect(self.bounds.size.width - 60, self.bounds.size.height - 32, 50, 24)];
    [self.clearButton setTitle:@"Clear"];
    [self.clearButton setBezelStyle:NSBezelStyleRounded];
    [self.clearButton setTarget:self];
    [self.clearButton setAction:@selector(clear)];
    [self.clearButton setFont:[NSFont systemFontOfSize:11]];
    [self addSubview:self.clearButton];

    // Scroll view with text view
    self.scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(5, 5, self.bounds.size.width - 10, self.bounds.size.height - 45)];
    [self.scrollView setHasVerticalScroller:YES];
    [self.scrollView setAutohidesScrollers:YES];
    [self.scrollView setBorderType:NSBezelBorder];

    NSSize contentSize = self.scrollView.contentSize;
    self.textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, contentSize.width, contentSize.height)];
    [self.textView setMinSize:NSMakeSize(0, contentSize.height)];
    [self.textView setMaxSize:NSMakeSize(FLT_MAX, FLT_MAX)];
    [self.textView setVerticallyResizable:YES];
    [self.textView setHorizontallyResizable:NO];
    [self.textView setAutoresizingMask:NSViewWidthSizable];
    [[self.textView textContainer] setContainerSize:NSMakeSize(contentSize.width, FLT_MAX)];
    [[self.textView textContainer] setWidthTracksTextView:YES];
    [self.textView setEditable:NO];
    [self.textView setSelectable:YES];
    [self.textView setFont:[NSFont fontWithName:@"Menlo" size:11]];
    [self.textView setBackgroundColor:[NSColor textBackgroundColor]];

    [self.scrollView setDocumentView:self.textView];
    [self addSubview:self.scrollView];

    // Initial message
    [self appendInfo:@"SimNet - Jackson Network Simulator\n"];
    [self appendText:@"Ready. Build a network and run simulation.\n"];
}

- (void)clear {
    [self.textView setString:@""];
}

- (void)appendText:(NSString *)text {
    [self appendText:text color:[NSColor textColor]];
}

- (void)appendText:(NSString *)text color:(NSColor *)color {
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont fontWithName:@"Menlo" size:11],
        NSForegroundColorAttributeName: color
    };

    NSAttributedString *attrStr = [[NSAttributedString alloc] initWithString:text attributes:attrs];
    [[self.textView textStorage] appendAttributedString:attrStr];

    // Scroll to bottom
    [self.textView scrollRangeToVisible:NSMakeRange(self.textView.string.length, 0)];
}

- (void)appendError:(NSString *)error {
    [self appendText:[NSString stringWithFormat:@"ERROR: %@\n", error] color:[NSColor systemRedColor]];
}

- (void)appendSuccess:(NSString *)message {
    [self appendText:[NSString stringWithFormat:@"%@\n", message] color:[NSColor systemGreenColor]];
}

- (void)appendInfo:(NSString *)info {
    [self appendText:[NSString stringWithFormat:@"%@", info] color:[NSColor systemBlueColor]];
}

- (void)appendMessage:(NSString *)message {
    [self appendText:[NSString stringWithFormat:@"%@\n", message]];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    [[NSColor windowBackgroundColor] setFill];
    NSRectFill(dirtyRect);
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
    [super resizeSubviewsWithOldSize:oldSize];

    [self.titleLabel setFrame:NSMakeRect(10, self.bounds.size.height - 30, 100, 20)];
    [self.clearButton setFrame:NSMakeRect(self.bounds.size.width - 60, self.bounds.size.height - 32, 50, 24)];
    [self.scrollView setFrame:NSMakeRect(5, 5, self.bounds.size.width - 10, self.bounds.size.height - 45)];
}

@end
