/*
 * NetworkModel.m - Data model implementation
 */

#import "NetworkModel.h"

#pragma mark - Distribution

@implementation Distribution

+ (instancetype)exponentialWithRate:(double)rate {
    Distribution *d = [[Distribution alloc] init];
    d.type = DistributionExponential;
    d.param1 = rate;
    return d;
}

+ (instancetype)erlangWithShape:(int)k rate:(double)rate {
    Distribution *d = [[Distribution alloc] init];
    d.type = DistributionErlang;
    d.param1 = k;
    d.param2 = rate;
    return d;
}

+ (instancetype)uniformWithMin:(double)min max:(double)max {
    Distribution *d = [[Distribution alloc] init];
    d.type = DistributionUniform;
    d.param1 = min;
    d.param2 = max;
    return d;
}

+ (instancetype)deterministicWithValue:(double)value {
    Distribution *d = [[Distribution alloc] init];
    d.type = DistributionDeterministic;
    d.param1 = value;
    return d;
}

+ (instancetype)none {
    Distribution *d = [[Distribution alloc] init];
    d.type = DistributionNone;
    return d;
}

- (NSString *)displayString {
    switch (self.type) {
        case DistributionNone:
            return @"None";
        case DistributionExponential:
            return [NSString stringWithFormat:@"Exp(λ=%.2f)", self.param1];
        case DistributionErlang:
            return [NSString stringWithFormat:@"Erlang(k=%d, λ=%.2f)", (int)self.param1, self.param2];
        case DistributionGamma:
            return [NSString stringWithFormat:@"Gamma(α=%.2f, β=%.2f)", self.param1, self.param2];
        case DistributionUniform:
            return [NSString stringWithFormat:@"Uniform(%.2f, %.2f)", self.param1, self.param2];
        case DistributionDeterministic:
            return [NSString stringWithFormat:@"Const(%.2f)", self.param1];
        case DistributionHyperexp2:
            return [NSString stringWithFormat:@"HyperExp(p=%.2f, λ1=%.2f, λ2=%.2f)",
                    self.param1, self.param2, self.param3];
        case DistributionLognormal:
            return [NSString stringWithFormat:@"LogN(μ=%.2f, σ=%.2f)", self.param1, self.param2];
        case DistributionWeibull:
            return [NSString stringWithFormat:@"Weibull(k=%.2f, λ=%.2f)", self.param1, self.param2];
        case DistributionPareto:
            return [NSString stringWithFormat:@"Pareto(α=%.2f, xm=%.2f)", self.param1, self.param2];
        default:
            return @"Unknown";
    }
}

- (NSString *)simString {
    switch (self.type) {
        case DistributionNone:
            return @"none";
        case DistributionExponential:
            return [NSString stringWithFormat:@"exponential %.6f", self.param1];
        case DistributionErlang:
            return [NSString stringWithFormat:@"erlang %d %.6f", (int)self.param1, self.param2];
        case DistributionGamma:
            return [NSString stringWithFormat:@"gamma %.6f %.6f", self.param1, self.param2];
        case DistributionUniform:
            return [NSString stringWithFormat:@"uniform %.6f %.6f", self.param1, self.param2];
        case DistributionDeterministic:
            return [NSString stringWithFormat:@"deterministic %.6f", self.param1];
        case DistributionHyperexp2:
            return [NSString stringWithFormat:@"hyperexp2 %.6f %.6f %.6f",
                    self.param1, self.param2, self.param3];
        case DistributionLognormal:
            return [NSString stringWithFormat:@"lognormal %.6f %.6f", self.param1, self.param2];
        case DistributionWeibull:
            return [NSString stringWithFormat:@"weibull %.6f %.6f", self.param1, self.param2];
        case DistributionPareto:
            return [NSString stringWithFormat:@"pareto %.6f %.6f", self.param1, self.param2];
        default:
            return @"none";
    }
}

+ (Distribution *)fromSimString:(NSString *)str {
    NSArray *parts = [str componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    parts = [parts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];

    if ([parts count] == 0) return [Distribution none];

    NSString *type = [parts[0] lowercaseString];
    Distribution *d = [[Distribution alloc] init];

    if ([type isEqualToString:@"none"]) {
        d.type = DistributionNone;
    } else if ([type isEqualToString:@"exponential"] || [type isEqualToString:@"exp"]) {
        d.type = DistributionExponential;
        if ([parts count] > 1) d.param1 = [parts[1] doubleValue];
    } else if ([type isEqualToString:@"erlang"]) {
        d.type = DistributionErlang;
        if ([parts count] > 1) d.param1 = [parts[1] doubleValue];
        if ([parts count] > 2) d.param2 = [parts[2] doubleValue];
    } else if ([type isEqualToString:@"gamma"]) {
        d.type = DistributionGamma;
        if ([parts count] > 1) d.param1 = [parts[1] doubleValue];
        if ([parts count] > 2) d.param2 = [parts[2] doubleValue];
    } else if ([type isEqualToString:@"uniform"]) {
        d.type = DistributionUniform;
        if ([parts count] > 1) d.param1 = [parts[1] doubleValue];
        if ([parts count] > 2) d.param2 = [parts[2] doubleValue];
    } else if ([type isEqualToString:@"deterministic"] || [type isEqualToString:@"const"]) {
        d.type = DistributionDeterministic;
        if ([parts count] > 1) d.param1 = [parts[1] doubleValue];
    } else if ([type isEqualToString:@"hyperexp2"] || [type isEqualToString:@"hyperexp"]) {
        d.type = DistributionHyperexp2;
        if ([parts count] > 1) d.param1 = [parts[1] doubleValue];
        if ([parts count] > 2) d.param2 = [parts[2] doubleValue];
        if ([parts count] > 3) d.param3 = [parts[3] doubleValue];
    } else if ([type isEqualToString:@"lognormal"]) {
        d.type = DistributionLognormal;
        if ([parts count] > 1) d.param1 = [parts[1] doubleValue];
        if ([parts count] > 2) d.param2 = [parts[2] doubleValue];
    } else if ([type isEqualToString:@"weibull"]) {
        d.type = DistributionWeibull;
        if ([parts count] > 1) d.param1 = [parts[1] doubleValue];
        if ([parts count] > 2) d.param2 = [parts[2] doubleValue];
    } else if ([type isEqualToString:@"pareto"]) {
        d.type = DistributionPareto;
        if ([parts count] > 1) d.param1 = [parts[1] doubleValue];
        if ([parts count] > 2) d.param2 = [parts[2] doubleValue];
    } else {
        d.type = DistributionNone;
    }

    return d;
}

- (id)copyWithZone:(NSZone *)zone {
    Distribution *copy = [[Distribution alloc] init];
    copy.type = self.type;
    copy.param1 = self.param1;
    copy.param2 = self.param2;
    copy.param3 = self.param3;
    return copy;
}

@end

#pragma mark - Station Node

@implementation StationNode

- (instancetype)initWithId:(NSInteger)stationId position:(NSPoint)pos {
    self = [super init];
    if (self) {
        _stationId = stationId;
        _position = pos;
        _name = [NSString stringWithFormat:@"Station %ld", (long)stationId];
        _bufferCapacity = -1;  // Infinite
        _selected = NO;
    }
    return self;
}

- (NSRect)frame {
    CGFloat size = 60;
    return NSMakeRect(self.position.x - size/2, self.position.y - size/2, size, size);
}

- (id)copyWithZone:(NSZone *)zone {
    StationNode *copy = [[StationNode alloc] init];
    copy.stationId = self.stationId;
    copy.name = [self.name copy];
    copy.position = self.position;
    copy.bufferCapacity = self.bufferCapacity;
    copy.selected = self.selected;
    return copy;
}

@end

#pragma mark - Customer Class

@implementation CustomerClass

- (instancetype)initWithId:(NSInteger)classId station:(NSInteger)stationId {
    self = [super init];
    if (self) {
        _classId = classId;
        _constituencyStation = stationId;
        _name = [NSString stringWithFormat:@"Class %ld", (long)classId];
        _arrivalDistribution = [Distribution none];
        _serviceDistribution = [Distribution exponentialWithRate:1.0];
        _routingProbabilities = [NSMutableArray array];
        _selected = NO;

        // Assign a color based on class ID
        NSArray *colors = @[
            [NSColor colorWithRed:0.2 green:0.6 blue:0.9 alpha:1.0],
            [NSColor colorWithRed:0.9 green:0.4 blue:0.3 alpha:1.0],
            [NSColor colorWithRed:0.3 green:0.8 blue:0.4 alpha:1.0],
            [NSColor colorWithRed:0.9 green:0.7 blue:0.2 alpha:1.0],
            [NSColor colorWithRed:0.7 green:0.3 blue:0.8 alpha:1.0],
            [NSColor colorWithRed:0.2 green:0.8 blue:0.8 alpha:1.0],
        ];
        _color = colors[classId % [colors count]];
    }
    return self;
}

- (NSString *)arrivalDistributionString {
    return [self.arrivalDistribution simString];
}

- (NSString *)serviceDistributionString {
    return [self.serviceDistribution simString];
}

- (NSString *)routingString {
    NSMutableArray *probs = [NSMutableArray array];
    for (NSNumber *p in self.routingProbabilities) {
        [probs addObject:[NSString stringWithFormat:@"%.6f", [p doubleValue]]];
    }
    return [probs componentsJoinedByString:@" "];
}

- (void)ensureRoutingCapacity:(NSInteger)classCount {
    while ([self.routingProbabilities count] < classCount) {
        [self.routingProbabilities addObject:@0.0];
    }
}

- (id)copyWithZone:(NSZone *)zone {
    CustomerClass *copy = [[CustomerClass alloc] init];
    copy.classId = self.classId;
    copy.name = [self.name copy];
    copy.constituencyStation = self.constituencyStation;
    copy.arrivalDistribution = [self.arrivalDistribution copy];
    copy.serviceDistribution = [self.serviceDistribution copy];
    copy.routingProbabilities = [self.routingProbabilities mutableCopy];
    copy.selected = self.selected;
    copy.color = self.color;
    return copy;
}

@end

#pragma mark - Connection

@implementation Connection

- (instancetype)initFrom:(NSInteger)from to:(NSInteger)to probability:(double)prob {
    self = [super init];
    if (self) {
        _fromClass = from;
        _toClass = to;
        _probability = prob;
        _selected = NO;
    }
    return self;
}

@end

#pragma mark - Network Model

@implementation NetworkModel {
    NSInteger _nextStationId;
    NSInteger _nextClassId;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _stations = [NSMutableArray array];
        _customerClasses = [NSMutableArray array];
        _connections = [NSMutableArray array];
        _nextStationId = 0;
        _nextClassId = 0;
    }
    return self;
}

#pragma mark - Station Management

- (StationNode *)addStationAtPosition:(NSPoint)pos {
    StationNode *station = [[StationNode alloc] initWithId:_nextStationId++ position:pos];
    [_stations addObject:station];
    return station;
}

- (void)removeStation:(StationNode *)station {
    // Remove all classes for this station
    NSArray *classesToRemove = [self classesForStation:station];
    for (CustomerClass *cls in classesToRemove) {
        [self removeClass:cls];
    }
    [_stations removeObject:station];
}

- (StationNode *)stationAtPoint:(NSPoint)point {
    for (StationNode *station in _stations) {
        if (NSPointInRect(point, [station frame])) {
            return station;
        }
    }
    return nil;
}

- (StationNode *)stationWithId:(NSInteger)stationId {
    for (StationNode *station in _stations) {
        if (station.stationId == stationId) {
            return station;
        }
    }
    return nil;
}

- (NSInteger)stationCount {
    return [_stations count];
}

#pragma mark - Class Management

- (CustomerClass *)addClassForStation:(StationNode *)station {
    CustomerClass *cls = [[CustomerClass alloc] initWithId:_nextClassId++
                                                   station:station.stationId];
    [_customerClasses addObject:cls];

    // Update routing for all classes
    for (CustomerClass *c in _customerClasses) {
        [c ensureRoutingCapacity:[_customerClasses count]];
    }

    return cls;
}

- (void)removeClass:(CustomerClass *)cls {
    // Remove connections involving this class
    NSMutableArray *toRemove = [NSMutableArray array];
    for (Connection *conn in _connections) {
        if (conn.fromClass == cls.classId || conn.toClass == cls.classId) {
            [toRemove addObject:conn];
        }
    }
    [_connections removeObjectsInArray:toRemove];

    [_customerClasses removeObject:cls];
}

- (CustomerClass *)classWithId:(NSInteger)classId {
    for (CustomerClass *cls in _customerClasses) {
        if (cls.classId == classId) {
            return cls;
        }
    }
    return nil;
}

- (NSInteger)classCount {
    return [_customerClasses count];
}

- (NSArray<CustomerClass *> *)classesForStation:(StationNode *)station {
    NSMutableArray *result = [NSMutableArray array];
    for (CustomerClass *cls in _customerClasses) {
        if (cls.constituencyStation == station.stationId) {
            [result addObject:cls];
        }
    }
    return result;
}

#pragma mark - Connection Management

- (Connection *)addConnectionFrom:(NSInteger)fromClass to:(NSInteger)toClass probability:(double)prob {
    // Check if connection already exists
    for (Connection *conn in _connections) {
        if (conn.fromClass == fromClass && conn.toClass == toClass) {
            conn.probability = prob;
            [self updateRoutingFromConnections];
            return conn;
        }
    }

    Connection *conn = [[Connection alloc] initFrom:fromClass to:toClass probability:prob];
    [_connections addObject:conn];
    [self updateRoutingFromConnections];
    return conn;
}

- (void)removeConnection:(Connection *)conn {
    [_connections removeObject:conn];
    [self updateRoutingFromConnections];
}

- (void)updateRoutingFromConnections {
    // Reset all routing probabilities
    for (CustomerClass *cls in _customerClasses) {
        [cls ensureRoutingCapacity:[_customerClasses count]];
        for (NSInteger i = 0; i < [cls.routingProbabilities count]; i++) {
            cls.routingProbabilities[i] = @0.0;
        }
    }

    // Set from connections
    for (Connection *conn in _connections) {
        CustomerClass *fromCls = [self classWithId:conn.fromClass];
        if (fromCls && conn.toClass < [fromCls.routingProbabilities count]) {
            fromCls.routingProbabilities[conn.toClass] = @(conn.probability);
        }
    }
}

#pragma mark - Selection

- (void)clearSelection {
    for (StationNode *s in _stations) s.selected = NO;
    for (CustomerClass *c in _customerClasses) c.selected = NO;
    for (Connection *conn in _connections) conn.selected = NO;
}

- (id)selectedObject {
    for (StationNode *s in _stations) if (s.selected) return s;
    for (CustomerClass *c in _customerClasses) if (c.selected) return c;
    for (Connection *conn in _connections) if (conn.selected) return conn;
    return nil;
}

#pragma mark - Validation

- (NSString *)validate {
    if ([_stations count] == 0) {
        return @"Network has no stations";
    }

    if ([_customerClasses count] == 0) {
        return @"Network has no customer classes";
    }

    // Check that each class has valid station
    for (CustomerClass *cls in _customerClasses) {
        if (![self stationWithId:cls.constituencyStation]) {
            return [NSString stringWithFormat:@"Class %ld references non-existent station %ld",
                    (long)cls.classId, (long)cls.constituencyStation];
        }
    }

    // Check at least one class has external arrivals
    BOOL hasArrivals = NO;
    for (CustomerClass *cls in _customerClasses) {
        if (cls.arrivalDistribution.type != DistributionNone) {
            hasArrivals = YES;
            break;
        }
    }
    if (!hasArrivals) {
        return @"At least one class must have external arrivals";
    }

    return nil;  // Valid
}

#pragma mark - Serialization

- (NSString *)saveToString {
    NSMutableString *s = [NSMutableString string];

    [s appendString:@"# Jackson Network GUI File\n\n"];

    // Stations
    [s appendString:@"[STATIONS]\n"];
    for (StationNode *station in _stations) {
        [s appendFormat:@"%ld,%@,%.1f,%.1f,%ld\n",
         (long)station.stationId, station.name,
         station.position.x, station.position.y,
         (long)station.bufferCapacity];
    }
    [s appendString:@"\n"];

    // Classes
    [s appendString:@"[CLASSES]\n"];
    for (CustomerClass *cls in _customerClasses) {
        [s appendFormat:@"%ld,%@,%ld,%@,%@,%@\n",
         (long)cls.classId, cls.name,
         (long)cls.constituencyStation,
         [cls.arrivalDistribution simString],
         [cls.serviceDistribution simString],
         [cls routingString]];
    }
    [s appendString:@"\n"];

    // Connections (for visual purposes)
    [s appendString:@"[CONNECTIONS]\n"];
    for (Connection *conn in _connections) {
        [s appendFormat:@"%ld,%ld,%.6f\n",
         (long)conn.fromClass, (long)conn.toClass, conn.probability];
    }

    return s;
}

- (BOOL)loadFromString:(NSString *)content {
    [self clear];

    NSArray *lines = [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSString *section = nil;

    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        if ([trimmed length] == 0 || [trimmed hasPrefix:@"#"]) continue;

        if ([trimmed hasPrefix:@"["]) {
            section = trimmed;
            continue;
        }

        if ([section isEqualToString:@"[STATIONS]"]) {
            NSArray *parts = [trimmed componentsSeparatedByString:@","];
            if ([parts count] >= 5) {
                StationNode *station = [[StationNode alloc] init];
                station.stationId = [parts[0] integerValue];
                station.name = parts[1];
                station.position = NSMakePoint([parts[2] doubleValue], [parts[3] doubleValue]);
                station.bufferCapacity = [parts[4] integerValue];
                [_stations addObject:station];
                _nextStationId = MAX(_nextStationId, station.stationId + 1);
            }
        }
        else if ([section isEqualToString:@"[CLASSES]"]) {
            NSArray *parts = [trimmed componentsSeparatedByString:@","];
            if ([parts count] >= 6) {
                CustomerClass *cls = [[CustomerClass alloc] initWithId:[parts[0] integerValue]
                                                               station:[parts[2] integerValue]];
                cls.name = parts[1];
                cls.arrivalDistribution = [Distribution fromSimString:parts[3]];
                cls.serviceDistribution = [Distribution fromSimString:parts[4]];

                // Parse routing
                NSArray *routeParts = [parts[5] componentsSeparatedByString:@" "];
                for (NSString *prob in routeParts) {
                    if ([prob length] > 0) {
                        [cls.routingProbabilities addObject:@([prob doubleValue])];
                    }
                }

                [_customerClasses addObject:cls];
                _nextClassId = MAX(_nextClassId, cls.classId + 1);
            }
        }
        else if ([section isEqualToString:@"[CONNECTIONS]"]) {
            NSArray *parts = [trimmed componentsSeparatedByString:@","];
            if ([parts count] >= 3) {
                Connection *conn = [[Connection alloc] initFrom:[parts[0] integerValue]
                                                             to:[parts[1] integerValue]
                                                    probability:[parts[2] doubleValue]];
                [_connections addObject:conn];
            }
        }
    }

    return YES;
}

- (void)clear {
    [_stations removeAllObjects];
    [_customerClasses removeAllObjects];
    [_connections removeAllObjects];
    _nextStationId = 0;
    _nextClassId = 0;
}

@end
