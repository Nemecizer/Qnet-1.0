/*
 * PropertiesPanel.m - Properties panel for editing selected objects
 */

#import "PropertiesPanel.h"
#import "NetworkEditorView.h"

@interface PropertiesPanel () <NSTextFieldDelegate, NSComboBoxDelegate>

@property (strong, nonatomic) NSTextField *titleLabel;
@property (strong, nonatomic) NSScrollView *scrollView;
@property (strong, nonatomic) NSView *contentView;

// Current object being edited
@property (weak, nonatomic) StationNode *currentStation;
@property (weak, nonatomic) CustomerClass *currentClass;
@property (weak, nonatomic) Connection *currentConnection;

// Station controls
@property (strong, nonatomic) NSTextField *stationNameField;
@property (strong, nonatomic) NSTextField *bufferCapacityField;

// Class controls
@property (strong, nonatomic) NSTextField *classNameField;
@property (strong, nonatomic) NSPopUpButton *arrivalTypePopup;
@property (strong, nonatomic) NSTextField *arrivalParam1Field;
@property (strong, nonatomic) NSTextField *arrivalParam2Field;
@property (strong, nonatomic) NSTextField *arrivalParam3Field;
@property (strong, nonatomic) NSPopUpButton *serviceTypePopup;
@property (strong, nonatomic) NSTextField *serviceParam1Field;
@property (strong, nonatomic) NSTextField *serviceParam2Field;
@property (strong, nonatomic) NSTextField *serviceParam3Field;

// Connection controls
@property (strong, nonatomic) NSTextField *probabilityField;

@end

@implementation PropertiesPanel

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    // Title label
    self.titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(10, self.bounds.size.height - 30, self.bounds.size.width - 20, 20)];
    [self.titleLabel setStringValue:@"Properties"];
    [self.titleLabel setBezeled:NO];
    [self.titleLabel setDrawsBackground:NO];
    [self.titleLabel setEditable:NO];
    [self.titleLabel setSelectable:NO];
    [self.titleLabel setFont:[NSFont boldSystemFontOfSize:13]];
    [self addSubview:self.titleLabel];

    // Scroll view for content
    self.scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, self.bounds.size.width, self.bounds.size.height - 40)];
    [self.scrollView setHasVerticalScroller:YES];
    [self.scrollView setAutohidesScrollers:YES];
    [self.scrollView setBorderType:NSNoBorder];

    self.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, self.bounds.size.width - 20, 400)];
    [self.scrollView setDocumentView:self.contentView];
    [self addSubview:self.scrollView];
}

- (void)clearContentView {
    for (NSView *subview in [self.contentView.subviews copy]) {
        [subview removeFromSuperview];
    }
    self.currentStation = nil;
    self.currentClass = nil;
    self.currentConnection = nil;
}

- (NSTextField *)createLabelWithText:(NSString *)text atY:(CGFloat)y {
    NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(10, y, 100, 20)];
    [label setStringValue:text];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setFont:[NSFont systemFontOfSize:11]];
    return label;
}

- (NSTextField *)createTextFieldAtY:(CGFloat)y {
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(110, y, self.contentView.bounds.size.width - 120, 22)];
    [field setDelegate:self];
    return field;
}

- (NSPopUpButton *)createDistributionPopupAtY:(CGFloat)y {
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(110, y, self.contentView.bounds.size.width - 120, 25) pullsDown:NO];
    [popup addItemsWithTitles:@[
        @"None",
        @"Exponential",
        @"Erlang",
        @"Gamma",
        @"Uniform",
        @"Deterministic",
        @"Hyperexp-2",
        @"Lognormal",
        @"Weibull",
        @"Pareto"
    ]];
    return popup;
}

#pragma mark - Station Properties

- (void)showStationProperties:(StationNode *)station {
    [self clearContentView];
    self.currentStation = station;
    [self.titleLabel setStringValue:@"Station Properties"];

    CGFloat y = self.contentView.bounds.size.height - 30;

    // Name
    [self.contentView addSubview:[self createLabelWithText:@"Name:" atY:y]];
    self.stationNameField = [self createTextFieldAtY:y];
    [self.stationNameField setStringValue:station.name ?: @""];
    [self.stationNameField setTag:1];
    [self.contentView addSubview:self.stationNameField];
    y -= 35;

    // Buffer capacity
    [self.contentView addSubview:[self createLabelWithText:@"Buffer:" atY:y]];
    self.bufferCapacityField = [self createTextFieldAtY:y];
    if (station.bufferCapacity < 0) {
        [self.bufferCapacityField setStringValue:@"Infinite"];
    } else {
        [self.bufferCapacityField setIntegerValue:station.bufferCapacity];
    }
    [self.bufferCapacityField setTag:2];
    [self.contentView addSubview:self.bufferCapacityField];
    y -= 35;

    // Help text
    NSTextField *helpLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(10, y - 40, self.contentView.bounds.size.width - 20, 40)];
    [helpLabel setStringValue:@"Enter -1 or 'Infinite' for unlimited buffer capacity."];
    [helpLabel setBezeled:NO];
    [helpLabel setDrawsBackground:NO];
    [helpLabel setEditable:NO];
    [helpLabel setSelectable:NO];
    [helpLabel setFont:[NSFont systemFontOfSize:10]];
    [helpLabel setTextColor:[NSColor secondaryLabelColor]];
    [self.contentView addSubview:helpLabel];
}

#pragma mark - Class Properties

- (void)showClassProperties:(CustomerClass *)cls withStations:(NSArray<StationNode *> *)stations {
    [self clearContentView];
    self.currentClass = cls;
    [self.titleLabel setStringValue:@"Customer Class Properties"];

    CGFloat y = self.contentView.bounds.size.height - 30;

    // Name
    [self.contentView addSubview:[self createLabelWithText:@"Name:" atY:y]];
    self.classNameField = [self createTextFieldAtY:y];
    [self.classNameField setStringValue:cls.name ?: @""];
    [self.classNameField setTag:10];
    [self.contentView addSubview:self.classNameField];
    y -= 35;

    // Arrival Distribution section
    NSTextField *arrivalTitle = [[NSTextField alloc] initWithFrame:NSMakeRect(10, y, 200, 20)];
    [arrivalTitle setStringValue:@"Arrival Distribution"];
    [arrivalTitle setBezeled:NO];
    [arrivalTitle setDrawsBackground:NO];
    [arrivalTitle setEditable:NO];
    [arrivalTitle setFont:[NSFont boldSystemFontOfSize:11]];
    [self.contentView addSubview:arrivalTitle];
    y -= 30;

    // Arrival type
    [self.contentView addSubview:[self createLabelWithText:@"Type:" atY:y]];
    self.arrivalTypePopup = [self createDistributionPopupAtY:y];
    [self.arrivalTypePopup selectItemAtIndex:cls.arrivalDistribution.type];
    [self.arrivalTypePopup setTarget:self];
    [self.arrivalTypePopup setAction:@selector(arrivalTypeChanged:)];
    [self.contentView addSubview:self.arrivalTypePopup];
    y -= 30;

    // Arrival params
    [self.contentView addSubview:[self createLabelWithText:@"Param 1:" atY:y]];
    self.arrivalParam1Field = [self createTextFieldAtY:y];
    [self.arrivalParam1Field setDoubleValue:cls.arrivalDistribution.param1];
    [self.arrivalParam1Field setTag:11];
    [self.contentView addSubview:self.arrivalParam1Field];
    y -= 30;

    [self.contentView addSubview:[self createLabelWithText:@"Param 2:" atY:y]];
    self.arrivalParam2Field = [self createTextFieldAtY:y];
    [self.arrivalParam2Field setDoubleValue:cls.arrivalDistribution.param2];
    [self.arrivalParam2Field setTag:12];
    [self.contentView addSubview:self.arrivalParam2Field];
    y -= 30;

    [self.contentView addSubview:[self createLabelWithText:@"Param 3:" atY:y]];
    self.arrivalParam3Field = [self createTextFieldAtY:y];
    [self.arrivalParam3Field setDoubleValue:cls.arrivalDistribution.param3];
    [self.arrivalParam3Field setTag:13];
    [self.contentView addSubview:self.arrivalParam3Field];
    y -= 40;

    // Service Distribution section
    NSTextField *serviceTitle = [[NSTextField alloc] initWithFrame:NSMakeRect(10, y, 200, 20)];
    [serviceTitle setStringValue:@"Service Distribution"];
    [serviceTitle setBezeled:NO];
    [serviceTitle setDrawsBackground:NO];
    [serviceTitle setEditable:NO];
    [serviceTitle setFont:[NSFont boldSystemFontOfSize:11]];
    [self.contentView addSubview:serviceTitle];
    y -= 30;

    // Service type
    [self.contentView addSubview:[self createLabelWithText:@"Type:" atY:y]];
    self.serviceTypePopup = [self createDistributionPopupAtY:y];
    [self.serviceTypePopup selectItemAtIndex:cls.serviceDistribution.type];
    [self.serviceTypePopup setTarget:self];
    [self.serviceTypePopup setAction:@selector(serviceTypeChanged:)];
    [self.contentView addSubview:self.serviceTypePopup];
    y -= 30;

    // Service params
    [self.contentView addSubview:[self createLabelWithText:@"Param 1:" atY:y]];
    self.serviceParam1Field = [self createTextFieldAtY:y];
    [self.serviceParam1Field setDoubleValue:cls.serviceDistribution.param1];
    [self.serviceParam1Field setTag:14];
    [self.contentView addSubview:self.serviceParam1Field];
    y -= 30;

    [self.contentView addSubview:[self createLabelWithText:@"Param 2:" atY:y]];
    self.serviceParam2Field = [self createTextFieldAtY:y];
    [self.serviceParam2Field setDoubleValue:cls.serviceDistribution.param2];
    [self.serviceParam2Field setTag:15];
    [self.contentView addSubview:self.serviceParam2Field];
    y -= 30;

    [self.contentView addSubview:[self createLabelWithText:@"Param 3:" atY:y]];
    self.serviceParam3Field = [self createTextFieldAtY:y];
    [self.serviceParam3Field setDoubleValue:cls.serviceDistribution.param3];
    [self.serviceParam3Field setTag:16];
    [self.contentView addSubview:self.serviceParam3Field];

    [self updateParamLabels];
}

- (void)arrivalTypeChanged:(NSPopUpButton *)sender {
    if (self.currentClass) {
        self.currentClass.arrivalDistribution.type = (DistributionType)sender.indexOfSelectedItem;
        [self updateParamLabels];
        [self notifyModelChanged];
    }
}

- (void)serviceTypeChanged:(NSPopUpButton *)sender {
    if (self.currentClass) {
        self.currentClass.serviceDistribution.type = (DistributionType)sender.indexOfSelectedItem;
        [self updateParamLabels];
        [self notifyModelChanged];
    }
}

- (void)updateParamLabels {
    // Update placeholder text based on distribution type
    // This helps users understand what each parameter means
}

#pragma mark - Connection Properties

- (void)showConnectionProperties:(Connection *)conn {
    [self clearContentView];
    self.currentConnection = conn;
    [self.titleLabel setStringValue:@"Connection Properties"];

    CGFloat y = self.contentView.bounds.size.height - 30;

    // Probability
    [self.contentView addSubview:[self createLabelWithText:@"Probability:" atY:y]];
    self.probabilityField = [self createTextFieldAtY:y];
    [self.probabilityField setDoubleValue:conn.probability];
    [self.probabilityField setTag:20];
    [self.contentView addSubview:self.probabilityField];
    y -= 35;

    // Help text
    NSTextField *helpLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(10, y - 40, self.contentView.bounds.size.width - 20, 40)];
    [helpLabel setStringValue:@"Enter routing probability (0.0 to 1.0). Sum of outgoing probabilities from a class should equal 1.0."];
    [helpLabel setBezeled:NO];
    [helpLabel setDrawsBackground:NO];
    [helpLabel setEditable:NO];
    [helpLabel setSelectable:NO];
    [helpLabel setFont:[NSFont systemFontOfSize:10]];
    [helpLabel setTextColor:[NSColor secondaryLabelColor]];
    [self.contentView addSubview:helpLabel];
}

#pragma mark - Clear

- (void)clearProperties {
    [self clearContentView];
    [self.titleLabel setStringValue:@"Properties"];

    NSTextField *helpLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(10, self.contentView.bounds.size.height / 2, self.contentView.bounds.size.width - 20, 40)];
    [helpLabel setStringValue:@"Select an object to view and edit its properties."];
    [helpLabel setBezeled:NO];
    [helpLabel setDrawsBackground:NO];
    [helpLabel setEditable:NO];
    [helpLabel setSelectable:NO];
    [helpLabel setFont:[NSFont systemFontOfSize:11]];
    [helpLabel setTextColor:[NSColor secondaryLabelColor]];
    [helpLabel setAlignment:NSTextAlignmentCenter];
    [self.contentView addSubview:helpLabel];
}

- (void)clearSelection {
    [self clearProperties];
}

#pragma mark - Convenience Methods

- (void)showStation:(StationNode *)station {
    [self showStationProperties:station];
}

- (void)showClass:(CustomerClass *)cls {
    [self showClassProperties:cls withStations:nil];
}

- (void)showConnection:(Connection *)conn {
    [self showConnectionProperties:conn];
}

#pragma mark - NSTextFieldDelegate

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    NSTextField *field = notification.object;

    if (self.currentStation) {
        if (field.tag == 1) {
            self.currentStation.name = field.stringValue;
        } else if (field.tag == 2) {
            NSString *value = field.stringValue.lowercaseString;
            if ([value isEqualToString:@"infinite"] || [value isEqualToString:@"inf"] || [value isEqualToString:@"-1"]) {
                self.currentStation.bufferCapacity = -1;
            } else {
                self.currentStation.bufferCapacity = field.integerValue;
            }
        }
    }

    if (self.currentClass) {
        if (field.tag == 10) {
            self.currentClass.name = field.stringValue;
        } else if (field.tag == 11) {
            self.currentClass.arrivalDistribution.param1 = field.doubleValue;
        } else if (field.tag == 12) {
            self.currentClass.arrivalDistribution.param2 = field.doubleValue;
        } else if (field.tag == 13) {
            self.currentClass.arrivalDistribution.param3 = field.doubleValue;
        } else if (field.tag == 14) {
            self.currentClass.serviceDistribution.param1 = field.doubleValue;
        } else if (field.tag == 15) {
            self.currentClass.serviceDistribution.param2 = field.doubleValue;
        } else if (field.tag == 16) {
            self.currentClass.serviceDistribution.param3 = field.doubleValue;
        }
    }

    if (self.currentConnection) {
        if (field.tag == 20) {
            double prob = field.doubleValue;
            if (prob < 0) prob = 0;
            if (prob > 1) prob = 1;
            self.currentConnection.probability = prob;
            [field setDoubleValue:prob];
        }
    }

    [self notifyModelChanged];
}

- (void)notifyModelChanged {
    if (self.networkEditor) {
        [self.networkEditor setNeedsDisplayForModel];
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    [[NSColor windowBackgroundColor] setFill];
    NSRectFill(dirtyRect);
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
    [super resizeSubviewsWithOldSize:oldSize];

    [self.titleLabel setFrame:NSMakeRect(10, self.bounds.size.height - 30, self.bounds.size.width - 20, 20)];
    [self.scrollView setFrame:NSMakeRect(0, 0, self.bounds.size.width, self.bounds.size.height - 40)];
}

@end
