/*
 * ConsoleView.h - Console output view for simulation results and messages
 */

#import <Cocoa/Cocoa.h>

@interface ConsoleView : NSView

- (void)clear;
- (void)appendText:(NSString *)text;
- (void)appendText:(NSString *)text color:(NSColor *)color;
- (void)appendError:(NSString *)error;
- (void)appendSuccess:(NSString *)message;
- (void)appendInfo:(NSString *)info;
- (void)appendMessage:(NSString *)message;

@end
