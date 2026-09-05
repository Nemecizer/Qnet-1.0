/*
 * NetworkModel.h - Data model for the network
 */

#import <Cocoa/Cocoa.h>

// Distribution types
typedef NS_ENUM(NSInteger, DistributionType) {
    DistributionNone = 0,
    DistributionExponential,
    DistributionErlang,
    DistributionGamma,
    DistributionUniform,
    DistributionDeterministic,
    DistributionHyperexp2,
    DistributionLognormal,
    DistributionWeibull,
    DistributionPareto
};

#pragma mark - Distribution

@interface Distribution : NSObject <NSCopying>
@property (nonatomic) DistributionType type;
@property (nonatomic) double param1;
@property (nonatomic) double param2;
@property (nonatomic) double param3;

+ (instancetype)exponentialWithRate:(double)rate;
+ (instancetype)erlangWithShape:(int)k rate:(double)rate;
+ (instancetype)uniformWithMin:(double)min max:(double)max;
+ (instancetype)deterministicWithValue:(double)value;
+ (instancetype)none;

- (NSString *)displayString;
- (NSString *)simString;
+ (Distribution *)fromSimString:(NSString *)str;
@end

#pragma mark - Station Node

@interface StationNode : NSObject <NSCopying>
@property (nonatomic) NSInteger stationId;
@property (copy, nonatomic) NSString *name;
@property (nonatomic) NSPoint position;
@property (nonatomic) NSInteger bufferCapacity;  // -1 for infinite
@property (nonatomic) BOOL selected;

- (instancetype)initWithId:(NSInteger)stationId position:(NSPoint)pos;
- (NSRect)frame;
@end

#pragma mark - Customer Class

@interface CustomerClass : NSObject <NSCopying>
@property (nonatomic) NSInteger classId;
@property (copy, nonatomic) NSString *name;
@property (nonatomic) NSInteger constituencyStation;  // Station where this class is served
@property (strong, nonatomic) Distribution *arrivalDistribution;
@property (strong, nonatomic) Distribution *serviceDistribution;
@property (strong, nonatomic) NSMutableArray<NSNumber *> *routingProbabilities;
@property (nonatomic) BOOL selected;
@property (strong, nonatomic) NSColor *color;

- (instancetype)initWithId:(NSInteger)classId station:(NSInteger)stationId;
- (NSString *)arrivalDistributionString;
- (NSString *)serviceDistributionString;
- (NSString *)routingString;
- (void)ensureRoutingCapacity:(NSInteger)classCount;
@end

#pragma mark - Connection (visual routing)

@interface Connection : NSObject
@property (nonatomic) NSInteger fromClass;
@property (nonatomic) NSInteger toClass;
@property (nonatomic) double probability;
@property (nonatomic) BOOL selected;

- (instancetype)initFrom:(NSInteger)from to:(NSInteger)to probability:(double)prob;
@end

#pragma mark - Network Model

@interface NetworkModel : NSObject

@property (strong, nonatomic, readonly) NSMutableArray<StationNode *> *stations;
@property (strong, nonatomic, readonly) NSMutableArray<CustomerClass *> *customerClasses;
@property (strong, nonatomic, readonly) NSMutableArray<Connection *> *connections;

// Station management
- (StationNode *)addStationAtPosition:(NSPoint)pos;
- (void)removeStation:(StationNode *)station;
- (StationNode *)stationAtPoint:(NSPoint)point;
- (StationNode *)stationWithId:(NSInteger)stationId;
- (NSInteger)stationCount;

// Class management
- (CustomerClass *)addClassForStation:(StationNode *)station;
- (void)removeClass:(CustomerClass *)cls;
- (CustomerClass *)classWithId:(NSInteger)classId;
- (NSInteger)classCount;
- (NSArray<CustomerClass *> *)classesForStation:(StationNode *)station;

// Connection management
- (Connection *)addConnectionFrom:(NSInteger)fromClass to:(NSInteger)toClass probability:(double)prob;
- (void)removeConnection:(Connection *)conn;
- (void)updateRoutingFromConnections;

// Selection
- (void)clearSelection;
- (id)selectedObject;

// Validation
- (NSString *)validate;

// Serialization
- (NSString *)saveToString;
- (BOOL)loadFromString:(NSString *)content;
- (void)clear;

@end
