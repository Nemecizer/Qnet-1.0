/*
 * NetworkEditorView.m - Main canvas for network editing
 */

#import "NetworkEditorView.h"
#import "NetworkModel.h"
#import "PropertiesPanel.h"
#import "AppDelegate.h"

@implementation NetworkEditorView {
    NetworkModel *_model;
    NSPoint _dragStart;
    id _draggedObject;
    BOOL _isDragging;
    NSInteger _connectionStartClass;
    NSPoint _connectionEndPoint;
    BOOL _drawingConnection;
    NSTrackingArea *_trackingArea;
}

@synthesize model = _model;

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _model = [[NetworkModel alloc] init];
        _currentTool = ToolSelect;
        _isDragging = NO;
        _drawingConnection = NO;
        _connectionStartClass = -1;
    }
    return self;
}

- (void)updateTrackingAreas {
    if (_trackingArea) {
        [self removeTrackingArea:_trackingArea];
    }
    _trackingArea = [[NSTrackingArea alloc]
                     initWithRect:[self bounds]
                          options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow
                            owner:self
                         userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)isFlipped {
    return NO;
}

#pragma mark - Drawing

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    // Background
    [[NSColor colorWithWhite:0.95 alpha:1.0] setFill];
    NSRectFill(dirtyRect);

    // Grid
    [self drawGrid];

    // Connections
    [self drawConnections];

    // Stations
    [self drawStations];

    // Classes (small indicators on stations)
    [self drawClasses];

    // Connection being drawn
    if (_drawingConnection && _connectionStartClass >= 0) {
        [self drawPendingConnection];
    }
}

- (void)drawGrid {
    [[NSColor colorWithWhite:0.85 alpha:1.0] setStroke];
    NSBezierPath *grid = [NSBezierPath bezierPath];
    [grid setLineWidth:0.5];

    CGFloat spacing = 50;
    for (CGFloat x = 0; x < self.bounds.size.width; x += spacing) {
        [grid moveToPoint:NSMakePoint(x, 0)];
        [grid lineToPoint:NSMakePoint(x, self.bounds.size.height)];
    }
    for (CGFloat y = 0; y < self.bounds.size.height; y += spacing) {
        [grid moveToPoint:NSMakePoint(0, y)];
        [grid lineToPoint:NSMakePoint(self.bounds.size.width, y)];
    }
    [grid stroke];
}

- (void)drawStations {
    for (StationNode *station in [_model stations]) {
        NSRect frame = [station frame];

        // Shadow
        NSShadow *shadow = [[NSShadow alloc] init];
        [shadow setShadowOffset:NSMakeSize(2, -2)];
        [shadow setShadowBlurRadius:4];
        [shadow setShadowColor:[NSColor colorWithWhite:0 alpha:0.3]];
        [NSGraphicsContext saveGraphicsState];
        [shadow set];

        // Station body
        NSBezierPath *stationPath = [NSBezierPath bezierPathWithRoundedRect:frame
                                                                    xRadius:8
                                                                    yRadius:8];

        if (station.selected) {
            [[NSColor colorWithRed:0.3 green:0.5 blue:0.9 alpha:1.0] setFill];
        } else {
            [[NSColor colorWithRed:0.4 green:0.6 blue:0.8 alpha:1.0] setFill];
        }
        [stationPath fill];

        [NSGraphicsContext restoreGraphicsState];

        // Border
        if (station.selected) {
            [[NSColor colorWithRed:0.2 green:0.3 blue:0.7 alpha:1.0] setStroke];
            [stationPath setLineWidth:3];
        } else {
            [[NSColor colorWithRed:0.2 green:0.4 blue:0.6 alpha:1.0] setStroke];
            [stationPath setLineWidth:1.5];
        }
        [stationPath stroke];

        // Station label
        NSString *label = [NSString stringWithFormat:@"S%ld", (long)station.stationId];
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont boldSystemFontOfSize:14],
            NSForegroundColorAttributeName: [NSColor whiteColor]
        };
        NSSize labelSize = [label sizeWithAttributes:attrs];
        NSPoint labelPoint = NSMakePoint(
            station.position.x - labelSize.width / 2,
            station.position.y - labelSize.height / 2
        );
        [label drawAtPoint:labelPoint withAttributes:attrs];

        // Buffer indicator (if finite)
        if (station.bufferCapacity > 0) {
            NSString *bufLabel = [NSString stringWithFormat:@"[%ld]", (long)station.bufferCapacity];
            NSDictionary *bufAttrs = @{
                NSFontAttributeName: [NSFont systemFontOfSize:9],
                NSForegroundColorAttributeName: [NSColor colorWithWhite:0.3 alpha:1.0]
            };
            NSSize bufSize = [bufLabel sizeWithAttributes:bufAttrs];
            [bufLabel drawAtPoint:NSMakePoint(frame.origin.x + frame.size.width - bufSize.width - 2,
                                              frame.origin.y + 2)
                   withAttributes:bufAttrs];
        }
    }
}

- (void)drawClasses {
    for (CustomerClass *cls in [_model customerClasses]) {
        StationNode *station = [_model stationWithId:cls.constituencyStation];
        if (!station) continue;

        // Calculate position (stack classes vertically near station)
        NSArray *stationClasses = [_model classesForStation:station];
        NSInteger index = [stationClasses indexOfObject:cls];

        CGFloat classSize = 16;
        CGFloat offset = 35 + index * (classSize + 4);
        NSPoint classPos = NSMakePoint(station.position.x + offset - 30,
                                       station.position.y + 35);

        NSRect classRect = NSMakeRect(classPos.x - classSize/2,
                                      classPos.y - classSize/2,
                                      classSize, classSize);

        // Draw class indicator
        NSBezierPath *classPath = [NSBezierPath bezierPathWithOvalInRect:classRect];
        [cls.color setFill];
        [classPath fill];

        if (cls.selected) {
            [[NSColor blackColor] setStroke];
            [classPath setLineWidth:2];
        } else {
            [[NSColor colorWithWhite:0.3 alpha:1.0] setStroke];
            [classPath setLineWidth:1];
        }
        [classPath stroke];

        // Class number
        NSString *label = [NSString stringWithFormat:@"%ld", (long)cls.classId];
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont boldSystemFontOfSize:9],
            NSForegroundColorAttributeName: [NSColor whiteColor]
        };
        NSSize labelSize = [label sizeWithAttributes:attrs];
        [label drawAtPoint:NSMakePoint(classPos.x - labelSize.width/2,
                                       classPos.y - labelSize.height/2)
            withAttributes:attrs];

        // Arrival indicator (if has external arrivals)
        if (cls.arrivalDistribution.type != DistributionNone) {
            NSBezierPath *arrow = [NSBezierPath bezierPath];
            [arrow moveToPoint:NSMakePoint(classPos.x - 20, classPos.y)];
            [arrow lineToPoint:NSMakePoint(classPos.x - classSize/2 - 2, classPos.y)];
            // Arrow head
            [arrow moveToPoint:NSMakePoint(classPos.x - classSize/2 - 2, classPos.y)];
            [arrow lineToPoint:NSMakePoint(classPos.x - classSize/2 - 6, classPos.y + 3)];
            [arrow moveToPoint:NSMakePoint(classPos.x - classSize/2 - 2, classPos.y)];
            [arrow lineToPoint:NSMakePoint(classPos.x - classSize/2 - 6, classPos.y - 3)];

            [[NSColor colorWithRed:0.2 green:0.7 blue:0.2 alpha:1.0] setStroke];
            [arrow setLineWidth:2];
            [arrow stroke];
        }
    }
}

- (void)drawConnections {
    for (Connection *conn in [_model connections]) {
        CustomerClass *fromCls = [_model classWithId:conn.fromClass];
        CustomerClass *toCls = [_model classWithId:conn.toClass];
        if (!fromCls || !toCls) continue;

        NSPoint fromPoint = [self centerOfClass:fromCls];
        NSPoint toPoint = [self centerOfClass:toCls];

        [self drawArrowFrom:fromPoint to:toPoint
                      color:fromCls.color
                   selected:conn.selected
                probability:conn.probability];
    }
}

- (void)drawPendingConnection {
    CustomerClass *fromCls = [_model classWithId:_connectionStartClass];
    if (!fromCls) return;

    NSPoint fromPoint = [self centerOfClass:fromCls];
    [self drawArrowFrom:fromPoint to:_connectionEndPoint
                  color:[NSColor grayColor]
               selected:NO
            probability:-1];
}

- (void)drawArrowFrom:(NSPoint)from to:(NSPoint)to
                color:(NSColor *)color
             selected:(BOOL)selected
          probability:(double)prob {

    // Calculate direction
    CGFloat dx = to.x - from.x;
    CGFloat dy = to.y - from.y;
    CGFloat len = sqrt(dx*dx + dy*dy);
    if (len < 1) return;

    CGFloat ux = dx / len;
    CGFloat uy = dy / len;

    // Shorten to not overlap with class circles
    from.x += ux * 10;
    from.y += uy * 10;
    to.x -= ux * 10;
    to.y -= uy * 10;

    // Curve the line slightly
    CGFloat midX = (from.x + to.x) / 2 + (-uy) * 20;
    CGFloat midY = (from.y + to.y) / 2 + ux * 20;

    NSBezierPath *path = [NSBezierPath bezierPath];
    [path moveToPoint:from];
    [path curveToPoint:to
         controlPoint1:NSMakePoint(midX, midY)
         controlPoint2:NSMakePoint(midX, midY)];

    [color setStroke];
    [path setLineWidth:selected ? 3 : 2];
    [path stroke];

    // Arrow head
    CGFloat arrowLen = 10;
    CGFloat arrowAngle = 0.4;

    // Direction at end point (tangent of curve)
    CGFloat tangentX = to.x - midX;
    CGFloat tangentY = to.y - midY;
    CGFloat tangentLen = sqrt(tangentX*tangentX + tangentY*tangentY);
    tangentX /= tangentLen;
    tangentY /= tangentLen;

    NSBezierPath *arrow = [NSBezierPath bezierPath];
    [arrow moveToPoint:to];
    [arrow lineToPoint:NSMakePoint(
        to.x - arrowLen * (tangentX * cos(arrowAngle) + tangentY * sin(arrowAngle)),
        to.y - arrowLen * (tangentY * cos(arrowAngle) - tangentX * sin(arrowAngle)))];
    [arrow moveToPoint:to];
    [arrow lineToPoint:NSMakePoint(
        to.x - arrowLen * (tangentX * cos(arrowAngle) - tangentY * sin(arrowAngle)),
        to.y - arrowLen * (tangentY * cos(arrowAngle) + tangentX * sin(arrowAngle)))];

    [arrow setLineWidth:selected ? 3 : 2];
    [arrow stroke];

    // Probability label
    if (prob >= 0) {
        NSString *label = [NSString stringWithFormat:@"%.2f", prob];
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:10],
            NSForegroundColorAttributeName: [NSColor colorWithWhite:0.3 alpha:1.0],
            NSBackgroundColorAttributeName: [NSColor colorWithWhite:1.0 alpha:0.8]
        };
        NSSize labelSize = [label sizeWithAttributes:attrs];
        [label drawAtPoint:NSMakePoint(midX - labelSize.width/2, midY - labelSize.height/2)
            withAttributes:attrs];
    }
}

- (NSPoint)centerOfClass:(CustomerClass *)cls {
    StationNode *station = [_model stationWithId:cls.constituencyStation];
    if (!station) return NSZeroPoint;

    NSArray *stationClasses = [_model classesForStation:station];
    NSInteger index = [stationClasses indexOfObject:cls];

    CGFloat classSize = 16;
    CGFloat offset = 35 + index * (classSize + 4);

    return NSMakePoint(station.position.x + offset - 30,
                       station.position.y + 35);
}

#pragma mark - Mouse Events

- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
    _dragStart = point;
    _isDragging = NO;

    switch (_currentTool) {
        case ToolSelect:
            [self handleSelectAtPoint:point];
            break;

        case ToolStation:
            [self handleAddStationAtPoint:point];
            break;

        case ToolClass:
            [self handleAddClassAtPoint:point];
            break;

        case ToolConnection:
            [self handleStartConnectionAtPoint:point];
            break;

        case ToolDelete:
            [self handleDeleteAtPoint:point];
            break;
    }

    [self setNeedsDisplay:YES];
}

- (void)mouseDragged:(NSEvent *)event {
    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];

    if (_currentTool == ToolSelect && _draggedObject) {
        _isDragging = YES;
        if ([_draggedObject isKindOfClass:[StationNode class]]) {
            StationNode *station = _draggedObject;
            station.position = point;
        }
    }
    else if (_currentTool == ToolConnection && _drawingConnection) {
        _connectionEndPoint = point;
    }

    [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)event {
    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];

    if (_currentTool == ToolConnection && _drawingConnection) {
        [self handleEndConnectionAtPoint:point];
    }

    _isDragging = NO;
    _draggedObject = nil;
    _drawingConnection = NO;

    [self setNeedsDisplay:YES];
}

- (void)mouseMoved:(NSEvent *)event {
    if (_drawingConnection) {
        _connectionEndPoint = [self convertPoint:[event locationInWindow] fromView:nil];
        [self setNeedsDisplay:YES];
    }
}

- (void)keyDown:(NSEvent *)event {
    if ([event keyCode] == 51 || [event keyCode] == 117) {  // Delete or Backspace
        [self deleteSelectedObject];
    } else {
        [super keyDown:event];
    }
}

#pragma mark - Tool Handlers

- (void)handleSelectAtPoint:(NSPoint)point {
    [_model clearSelection];

    // Check classes first (they're smaller targets)
    for (CustomerClass *cls in [_model customerClasses]) {
        NSPoint classCenter = [self centerOfClass:cls];
        CGFloat dist = sqrt(pow(point.x - classCenter.x, 2) + pow(point.y - classCenter.y, 2));
        if (dist < 12) {
            cls.selected = YES;
            _draggedObject = cls;
            [self.propertiesPanel showClass:cls];
            return;
        }
    }

    // Check stations
    StationNode *station = [_model stationAtPoint:point];
    if (station) {
        station.selected = YES;
        _draggedObject = station;
        [self.propertiesPanel showStation:station];
        return;
    }

    // Check connections
    for (Connection *conn in [_model connections]) {
        if ([self isPoint:point nearConnection:conn]) {
            conn.selected = YES;
            [self.propertiesPanel showConnection:conn];
            return;
        }
    }

    [self.propertiesPanel clearSelection];
}

- (BOOL)isPoint:(NSPoint)point nearConnection:(Connection *)conn {
    CustomerClass *fromCls = [_model classWithId:conn.fromClass];
    CustomerClass *toCls = [_model classWithId:conn.toClass];
    if (!fromCls || !toCls) return NO;

    NSPoint from = [self centerOfClass:fromCls];
    NSPoint to = [self centerOfClass:toCls];

    // Simple distance to line check
    CGFloat dx = to.x - from.x;
    CGFloat dy = to.y - from.y;
    CGFloat lenSq = dx*dx + dy*dy;
    if (lenSq < 1) return NO;

    CGFloat t = MAX(0, MIN(1, ((point.x - from.x) * dx + (point.y - from.y) * dy) / lenSq));
    CGFloat projX = from.x + t * dx;
    CGFloat projY = from.y + t * dy;

    CGFloat dist = sqrt(pow(point.x - projX, 2) + pow(point.y - projY, 2));
    return dist < 10;
}

- (void)handleAddStationAtPoint:(NSPoint)point {
    // Snap to grid
    CGFloat gridSize = 50;
    point.x = round(point.x / gridSize) * gridSize;
    point.y = round(point.y / gridSize) * gridSize;

    StationNode *station = [_model addStationAtPosition:point];
    [self.appDelegate logMessage:[NSString stringWithFormat:@"Added station %ld at (%.0f, %.0f)",
                                  (long)station.stationId, point.x, point.y]];

    [_model clearSelection];
    station.selected = YES;
    [self.propertiesPanel showStation:station];
}

- (void)handleAddClassAtPoint:(NSPoint)point {
    StationNode *station = [_model stationAtPoint:point];
    if (station) {
        CustomerClass *cls = [_model addClassForStation:station];
        [self.appDelegate logMessage:[NSString stringWithFormat:@"Added class %ld for station %ld",
                                      (long)cls.classId, (long)station.stationId]];

        [_model clearSelection];
        cls.selected = YES;
        [self.propertiesPanel showClass:cls];
    } else {
        [self.appDelegate logError:@"Click on a station to add a customer class."];
    }
}

- (void)handleStartConnectionAtPoint:(NSPoint)point {
    // Find the class clicked
    for (CustomerClass *cls in [_model customerClasses]) {
        NSPoint classCenter = [self centerOfClass:cls];
        CGFloat dist = sqrt(pow(point.x - classCenter.x, 2) + pow(point.y - classCenter.y, 2));
        if (dist < 15) {
            _connectionStartClass = cls.classId;
            _drawingConnection = YES;
            _connectionEndPoint = point;
            return;
        }
    }

    [self.appDelegate logError:@"Click on a class (colored circle) to start a connection."];
}

- (void)handleEndConnectionAtPoint:(NSPoint)point {
    if (_connectionStartClass < 0) return;

    // Find the class at end point
    for (CustomerClass *cls in [_model customerClasses]) {
        NSPoint classCenter = [self centerOfClass:cls];
        CGFloat dist = sqrt(pow(point.x - classCenter.x, 2) + pow(point.y - classCenter.y, 2));
        if (dist < 15) {
            // Prompt for probability
            [self promptForConnectionProbability:_connectionStartClass to:cls.classId];
            _drawingConnection = NO;
            _connectionStartClass = -1;
            return;
        }
    }

    _drawingConnection = NO;
    _connectionStartClass = -1;
}

- (void)promptForConnectionProbability:(NSInteger)from to:(NSInteger)to {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Connection Probability"];
    [alert setInformativeText:[NSString stringWithFormat:@"Enter routing probability from class %ld to class %ld:",
                               (long)from, (long)to]];
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];

    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
    [input setStringValue:@"0.5"];
    [alert setAccessoryView:input];

    if ([alert runModal] == NSAlertFirstButtonReturn) {
        double prob = [[input stringValue] doubleValue];
        if (prob < 0) prob = 0;
        if (prob > 1) prob = 1;

        [_model addConnectionFrom:from to:to probability:prob];
        [self.appDelegate logMessage:[NSString stringWithFormat:@"Added connection from class %ld to %ld with probability %.2f",
                                      (long)from, (long)to, prob]];
        [self setNeedsDisplay:YES];
    }
}

- (void)handleDeleteAtPoint:(NSPoint)point {
    // Try to delete in reverse order of drawing (connections, classes, stations)
    for (Connection *conn in [_model connections]) {
        if ([self isPoint:point nearConnection:conn]) {
            [_model removeConnection:conn];
            [self.appDelegate logMessage:@"Deleted connection"];
            [self.propertiesPanel clearSelection];
            return;
        }
    }

    for (CustomerClass *cls in [_model customerClasses]) {
        NSPoint classCenter = [self centerOfClass:cls];
        CGFloat dist = sqrt(pow(point.x - classCenter.x, 2) + pow(point.y - classCenter.y, 2));
        if (dist < 12) {
            [_model removeClass:cls];
            [self.appDelegate logMessage:[NSString stringWithFormat:@"Deleted class %ld", (long)cls.classId]];
            [self.propertiesPanel clearSelection];
            return;
        }
    }

    StationNode *station = [_model stationAtPoint:point];
    if (station) {
        [_model removeStation:station];
        [self.appDelegate logMessage:[NSString stringWithFormat:@"Deleted station %ld", (long)station.stationId]];
        [self.propertiesPanel clearSelection];
        return;
    }
}

- (void)deleteSelectedObject {
    id selected = [_model selectedObject];
    if ([selected isKindOfClass:[StationNode class]]) {
        [_model removeStation:selected];
        [self.appDelegate logMessage:@"Deleted selected station"];
    } else if ([selected isKindOfClass:[CustomerClass class]]) {
        [_model removeClass:selected];
        [self.appDelegate logMessage:@"Deleted selected class"];
    } else if ([selected isKindOfClass:[Connection class]]) {
        [_model removeConnection:selected];
        [self.appDelegate logMessage:@"Deleted selected connection"];
    }

    [self.propertiesPanel clearSelection];
    [self setNeedsDisplay:YES];
}

- (void)setNeedsDisplayForModel {
    [self setNeedsDisplay:YES];
}

@end
