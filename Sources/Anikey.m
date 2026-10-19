// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Anish Aryal

// aniKey: standalone AppKit + IOBluetooth Classic HID device for Android.
// Build instructions are in README.md. All Bluetooth calls use public SDK APIs.
#import <AppKit/AppKit.h>
#import <IOBluetooth/IOBluetooth.h>
#import <CoreBluetooth/CoreBluetooth.h>
#include <signal.h>
#include <stdint.h>
#include <math.h>
#include <unistd.h>

static volatile sig_atomic_t Interrupted = 0;
static void InterruptHandler(int signo) { (void)signo; Interrupted = 1; }

static NSData *Bytes(const uint8_t *bytes, NSUInteger count) {
    return [NSData dataWithBytes:bytes length:count];
}
static NSString *Hex(NSData *data) {
    NSMutableArray *parts = [NSMutableArray array];
    const uint8_t *p = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) [parts addObject:[NSString stringWithFormat:@"%02X", p[i]]];
    return [parts componentsJoinedByString:@" "];
}
static BOOL Fail(NSString **error, NSString *message) { if (error) *error = message; return NO; }
static NSString *IOError(NSString *stage, IOReturn code) {
    return [NSString stringWithFormat:@"%@: IOReturn 0x%08X", stage, (unsigned)code];
}
static NSString *ConnectionFailureStatus(NSString *error) {
    NSString *line = error.length ? error : @"Connection failed without an SDK error.";
    if (line.length > 95) {
        line = [line componentsSeparatedByString:@". "].firstObject;
        if (line.length > 95) line = [[line substringToIndex:92] stringByAppendingString:@"…"];
    }
    return [NSString stringWithFormat:@"%@\nPress Connect to try again.",line];
}
static void Pump(NSTimeInterval seconds) {
    NSTimeInterval until = NSProcessInfo.processInfo.systemUptime + seconds;
    do {
        NSTimeInterval remaining = until - NSProcessInfo.processInfo.systemUptime;
        if (remaining <= 0 || Interrupted) break;
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:MIN(remaining, 0.01)]];
    } while (!Interrupted);
}

#pragma mark - HID encoding and SDP

// Report 1: modifiers, reserved, six usages; output: five LED bits + padding.
// Report 2: only consumer AC Back and AC Home. Keep their bits aligned with
// the original paired host layout; every other consumer bit stays zero.
// Report 10 avoids report 2, which existing hosts may cache as consumer controls.
// Mouse: two button bits, relative X/Y, neutral Z and vertical wheel. Boot mouse uses ID 2.
static NSData *ReportDescriptor(void) {
    const uint8_t descriptor[] = {
        0x05,0x01, 0x09,0x06, 0xA1,0x01, 0x85,0x01,
        0x05,0x07, 0x19,0xE0, 0x29,0xE7, 0x15,0x00, 0x25,0x01,
        0x75,0x01, 0x95,0x08, 0x81,0x02,
        0x75,0x08, 0x95,0x01, 0x81,0x01,
        0x05,0x08, 0x19,0x01, 0x29,0x05, 0x75,0x01, 0x95,0x05, 0x91,0x02,
        0x75,0x03, 0x95,0x01, 0x91,0x01,
        0x05,0x07, 0x19,0x00, 0x29,0x65, 0x15,0x00, 0x25,0x65,
        0x75,0x08, 0x95,0x06, 0x81,0x00, 0xC0,
        0x05,0x0C, 0x09,0x01, 0xA1,0x01, 0x85,0x02,
        0x15,0x00, 0x25,0x01, 0x75,0x01,
        0x0A,0x24,0x02, 0x95,0x01, 0x81,0x02,
        0x81,0x03, // Reserved bit 1; no menu or media usage.
        0x0A,0x23,0x02, 0x81,0x02,
        0x95,0x05, 0x81,0x03,
        0x75,0x08, 0x95,0x01, 0x81,0x03, 0xC0,
        0x05,0x01, 0x09,0x02, 0xA1,0x01, 0x85,0x0A,
        0x09,0x01, 0xA1,0x00, 0x05,0x09, 0x19,0x01, 0x29,0x02,
        0x15,0x00, 0x25,0x01, 0x75,0x01, 0x95,0x02, 0x81,0x02,
        0x75,0x06, 0x95,0x01, 0x81,0x01,
        0x05,0x01, 0x09,0x30, 0x09,0x31, 0x09,0x32, 0x09,0x38, 0x15,0x81, 0x25,0x7F,
        0x75,0x08, 0x95,0x04, 0x81,0x06, 0xC0,0xC0,
    };
    return Bytes(descriptor, sizeof(descriptor));
}
static NSDictionary *SDPNumber(unsigned value, unsigned size) {
    return @{@"DataElementType": @1, @"DataElementSize": @(size), @"DataElementValue": @(value)};
}
static NSDictionary *SDPBoolean(BOOL value) {
    return @{@"DataElementType": @5, @"DataElementValue": @(value)};
}
static NSData *SDPUUID(uint16_t value) {
    const uint8_t bytes[] = {(uint8_t)(value >> 8), (uint8_t)value};
    return Bytes(bytes, 2);
}
static NSDictionary *ServiceDictionary(void) {
    NSDictionary *attributes = @{
        @"0000": @65536,
        @"0001": @[SDPUUID(0x1124)],
        @"0004": @[@[SDPUUID(0x0100), SDPNumber(0x0011,2)], @[SDPUUID(0x0011)]],
        @"0005": @[SDPUUID(0x1002)],
        @"0006": @[SDPNumber(0x656E,2), SDPNumber(106,2), SDPNumber(0x0100,2)],
        @"0009": @[@[SDPUUID(0x1124), SDPNumber(0x0101,2)]],
        @"000D": @[@[@[SDPUUID(0x0100), SDPNumber(0x0013,2)], @[SDPUUID(0x0011)]]],
        @"0100": @"aniKey Bluetooth Keyboard and Mouse", @"0101": @"Native macOS input for Android",
        @"0102": @"aniKey",
        @"0201": SDPNumber(0x0111,2), @"0202": SDPNumber(0xC0,1),
        @"0203": SDPNumber(33,1), @"0204": SDPBoolean(YES), @"0205": SDPBoolean(YES),
        @"0206": @[@[SDPNumber(0x22,1), @{@"DataElementType": @4, @"DataElementValue": ReportDescriptor()}]],
        @"0207": @[@[SDPNumber(0x0409,2), SDPNumber(0x0100,2)]],
        @"0209": SDPBoolean(NO), @"020A": SDPBoolean(NO),
        @"020B": SDPNumber(0x0101,2), @"020C": SDPNumber(0x1F40,2),
        @"020D": SDPBoolean(NO), @"020E": SDPBoolean(YES),
        @"LocalAttributes": @{@"Persistent": @NO}
    };
    // Canonical SDK sample keys make the service identity/name explicit to the bridge.
    NSDictionary *names = @{@"0000":@"ServiceRecordHandle",@"0001":@"ServiceClassIDList",
        @"0004":@"ProtocolDescriptorList",@"0005":@"BrowseGroupList",@"0006":@"LanguageBaseAttributeIDList",
        @"0009":@"BluetoothProfileDescriptorList",@"000D":@"AdditionalProtocolDescriptorLists",
        @"0100":@"ServiceName",@"0101":@"ServiceDescription",@"0102":@"ProviderName",
        @"0201":@"HIDParserVersion",@"0202":@"HIDDeviceSubclass",@"0203":@"HIDCountryCode",
        @"0204":@"HIDVirtualCable",@"0205":@"HIDReconnectInitiate",@"0206":@"HIDDescriptorList",
        @"0207":@"HIDLANGIDBaseList",@"0209":@"HIDBatteryPower",@"020A":@"HIDRemoteWake",
        @"020B":@"HIDProfileVersion",@"020C":@"HIDSupervisionTimeout",@"020D":@"HIDNormallyConnectable",@"020E":@"HIDBootDevice"};
    NSMutableDictionary *service = [NSMutableDictionary dictionary];
    for (NSString *key in attributes) service[names[key] ? [NSString stringWithFormat:@"%@ - %@",key,names[key]] : key] = attributes[key];
    return service;
}
static BOOL ServiceHasExpectedDescriptor(IOBluetoothSDPServiceRecord *record) {
    for (IOBluetoothSDPDataElement *element in [[record getAttributeDataElement:0x0206] getArrayValue]) {
        NSArray<IOBluetoothSDPDataElement *> *entry = [element getArrayValue];
        if (entry.count == 2 && [entry[0].getNumberValue unsignedIntValue] == 0x22)
            return [entry[1].getValue isEqual:ReportDescriptor()];
    }
    return NO;
}
static NSString *ServiceValidationError(IOBluetoothSDPServiceRecord *record) {
    if (!ServiceHasExpectedDescriptor(record)) return @"HID descriptor mismatch; input blocked.";
    BluetoothL2CAPPSM control = 0;
    IOReturn status = [record getL2CAPPSM:&control];
    if (status != kIOReturnSuccess) return IOError(@"Reading published control PSM",status);
    if (control != 0x11) return [NSString stringWithFormat:@"Published control PSM 0x%04X does not match 0x0011; input blocked.",control];
    NSArray *controlProtocols = [[record getAttributeDataElement:0x0004] getArrayValue];
    NSArray *controlHIDP = controlProtocols.count == 2 ? [controlProtocols[1] getArrayValue] : nil;
    if (controlHIDP.count != 1 || ![[controlHIDP[0] getUUIDValue] isEqualToUUID:[IOBluetoothSDPUUID uuid16:0x0011]])
        return @"Published control protocol is missing or malformed; input blocked.";
    NSArray *lists = [[record getAttributeDataElement:0x000D] getArrayValue];
    NSArray *protocols = lists.count == 1 ? [lists[0] getArrayValue] : nil;
    NSArray *l2cap = protocols.count == 2 ? [protocols[0] getArrayValue] : nil;
    NSArray *hidp = protocols.count == 2 ? [protocols[1] getArrayValue] : nil;
    if (l2cap.count != 2 || hidp.count != 1 ||
        ![[l2cap[0] getUUIDValue] isEqualToUUID:[IOBluetoothSDPUUID uuid16:0x0100]] ||
        ![[hidp[0] getUUIDValue] isEqualToUUID:[IOBluetoothSDPUUID uuid16:0x0011]] || ![l2cap[1] getNumberValue])
        return @"Published interrupt protocol is missing or malformed; input blocked.";
    unsigned interrupt = [[l2cap[1] getNumberValue] unsignedIntValue];
    if (interrupt != 0x13) return [NSString stringWithFormat:@"Published interrupt PSM 0x%04X does not match 0x0013; input blocked.",interrupt];
    return nil;
}
static NSData *KeyboardReport(uint8_t modifiers, NSArray<NSNumber *> *usages) {
    uint8_t report[8] = {modifiers, 0, 0, 0, 0, 0, 0, 0};
    if (usages.count > 6) memset(report+2,1,6);
    else for (NSUInteger i = 0; i < usages.count; i++) report[2+i] = usages[i].unsignedCharValue;
    return Bytes(report, sizeof(report));
}
static NSData *MouseWheelReport(uint8_t buttons, int x, int y, int wheel) {
    const uint8_t bytes[] = {(uint8_t)(buttons & 3),(uint8_t)x,(uint8_t)y,0,(uint8_t)wheel};
    return Bytes(bytes,5);
}
static NSData *MouseReport(uint8_t buttons, int x, int y) { return MouseWheelReport(buttons,x,y,0); }

// Keep at most a small amount of relative motion; preserve fractional points.
@interface PointerMotion : NSObject
@property double x, y, wheel;
- (void)addX:(double)x y:(double)y;
- (void)addWheel:(double)wheel;
- (NSData *)takeReport;
- (void)reset;
@end
@implementation PointerMotion
- (void)addX:(double)x y:(double)y {
    if (!isfinite(x) || !isfinite(y)) return;
    self.x = MAX(-512,MIN(512,self.x+x)); self.y = MAX(-512,MIN(512,self.y+y));
}
- (void)addWheel:(double)wheel {
    if (!isfinite(wheel)) return;
    self.wheel = MAX(-32,MIN(32,self.wheel+wheel));
}
- (NSData *)takeReport {
    int x = (int)MAX(-127,MIN(127,self.x)), y = (int)MAX(-127,MIN(127,self.y));
    int wheel = (int)MAX(-8,MIN(8,self.wheel));
    if (!x && !y && !wheel) return nil;
    self.x -= x; self.y -= y; self.wheel -= wheel; return MouseWheelReport(0,x,y,wheel);
}
- (void)reset { self.x = self.y = self.wheel = 0; }
@end

typedef struct { uint8_t usage, modifiers; } Key;
typedef NS_ENUM(NSInteger, PadAction) { PadActionNone, PadActionBack, PadActionHome, PadActionRecentApps };
typedef NS_ENUM(NSInteger, PadAxis) { PadAxisUndecided, PadAxisHorizontal, PadAxisVertical };
static const double PadContentDragDistance = 12;
static const double PadScrollPointsPerStep = 12;
static PadAxis ScrollPadAxis(double x, double y) {
    if (!isfinite(x) || !isfinite(y)) return PadAxisUndecided;
    if (MAX(fabs(x),fabs(y)) < 6) return PadAxisUndecided;
    return fabs(x) > fabs(y) ? PadAxisHorizontal : PadAxisVertical;
}
static BOOL ASCIIKey(unichar character, Key *key) {
    key->modifiers = 0;
    if (character >= 'a' && character <= 'z') key->usage = (uint8_t)(4 + character - 'a');
    else if (character >= 'A' && character <= 'Z') { key->usage = (uint8_t)(4 + character - 'A'); key->modifiers = 2; }
    else if (character >= '1' && character <= '9') key->usage = (uint8_t)(0x1E + character - '1');
    else if (character == '0') key->usage = 0x27;
    else {
        NSString *plain = @"\r\n\t \b-=[]\\;'/`,.";
        const uint8_t codes[] = {0x28,0x28,0x2B,0x2C,0x2A,0x2D,0x2E,0x2F,0x30,0x31,0x33,0x34,0x38,0x35,0x36,0x37};
        NSRange range = [plain rangeOfString:[NSString stringWithCharacters:&character length:1]];
        if (range.location != NSNotFound) key->usage = codes[range.location];
        else {
            NSString *shifted = @"!@#$%^&*()_+{}|:\"?~<>";
            const uint8_t shiftedCodes[] = {0x1E,0x1F,0x20,0x21,0x22,0x23,0x24,0x25,0x26,0x27,0x2D,0x2E,0x2F,0x30,0x31,0x33,0x34,0x38,0x35,0x36,0x37};
            range = [shifted rangeOfString:[NSString stringWithCharacters:&character length:1]];
            if (range.location == NSNotFound) return NO;
            key->usage = shiftedCodes[range.location]; key->modifiers = 2;
        }
    }
    return YES;
}
static BOOL ValidateText(NSString *text, NSString **error) {
    for (NSUInteger i = 0; i < text.length; i++) {
        Key key;
        if (!ASCIIKey([text characterAtIndex:i], &key))
            return Fail(error, [NSString stringWithFormat:@"Unsupported character U+%04X at position %lu; text requires US-layout ASCII.", [text characterAtIndex:i], (unsigned long)i]);
    }
    return YES;
}
static BOOL ParseChord(NSString *chord, Key *key, NSString **error) {
    NSArray<NSString *> *parts = [chord.lowercaseString componentsSeparatedByString:@"+"];
    uint8_t modifiers = 0;
    NSDictionary *modifierCodes = @{@"ctrl": @1, @"control": @1, @"shift": @2, @"alt": @4, @"option": @4, @"gui": @8, @"cmd": @8, @"meta": @8};
    for (NSUInteger i = 0; i + 1 < parts.count; i++) {
        NSNumber *code = modifierCodes[parts[i]];
        if (!code) return Fail(error, [@"Unknown modifier: " stringByAppendingString:parts[i]]);
        modifiers |= code.unsignedCharValue;
    }
    NSString *name = parts.lastObject;
    NSDictionary *keys = @{@"enter": @0x28, @"escape": @0x29, @"esc": @0x29, @"backspace": @0x2A,
        @"tab": @0x2B, @"space": @0x2C, @"capslock": @0x39, @"insert": @0x49,
        @"home": @0x4A, @"pageup": @0x4B, @"delete": @0x4C, @"end": @0x4D,
        @"pagedown": @0x4E, @"right": @0x4F, @"left": @0x50, @"down": @0x51, @"up": @0x52,
        @"numlock": @0x53, @"plus": @0x2E};
    NSNumber *usage = keys[name];
    key->modifiers = 0;
    if (usage) { key->usage = usage.unsignedCharValue; if ([name isEqual:@"plus"]) key->modifiers = 2; }
    else if (name.length == 1 && ASCIIKey([name characterAtIndex:0], key)) {}
    else if ([name hasPrefix:@"f"] && name.length <= 3) {
        NSScanner *scanner = [NSScanner scannerWithString:[name substringFromIndex:1]];
        int number = 0;
        if (![scanner scanInt:&number] || !scanner.isAtEnd || number < 1 || number > 12)
            return Fail(error, [@"Unknown key: " stringByAppendingString:name]);
        key->usage = (uint8_t)(0x3A + number - 1);
    } else return Fail(error, [@"Unknown key: " stringByAppendingString:name]);
    key->modifiers |= modifiers;
    return YES;
}
static NSString *NormalizeAddress(NSString *raw) {
    NSString *compact = [[raw stringByReplacingOccurrencesOfString:@":" withString:@""] stringByReplacingOccurrencesOfString:@"-" withString:@""];
    if (compact.length != 12 || [compact rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"].invertedSet].location != NSNotFound) return nil;
    NSMutableArray *parts = [NSMutableArray array];
    for (NSUInteger i = 0; i < 12; i += 2) [parts addObject:[compact substringWithRange:NSMakeRange(i,2)].uppercaseString];
    return [parts componentsJoinedByString:@"-"];
}

#pragma mark - Bluetooth transport / HIDP

@interface AnikeySession : NSObject <IOBluetoothL2CAPChannelDelegate>
@property BOOL dryRun, trace, ready, suspended, connecting, closing, cancelRequested;
// Mouse input becomes available only after both channel completions and startup write.
@property BOOL mouseValidated, mouseDiagnostics;
@property NSUInteger mouseProbeRemaining;
@property (copy) NSString *mouseDiagnostic;
@property uint8_t protocolMode, LEDs;
@property NSUInteger keyDelayMS;
@property (copy) NSString *lastError;
@property (strong) NSData *keyboard, *mouse;
@property uint16_t consumerControls;
@property (strong) IOBluetoothDevice *device;
@property (strong) IOBluetoothSDPServiceRecord *service;
@property (strong) IOBluetoothL2CAPChannel *control, *interrupt;
@property BOOL completion;
@property IOReturn completionStatus;
@property BluetoothL2CAPPSM openingPSM;
- (BOOL)connect:(NSString *)address;
- (BOOL)writePacket:(NSData *)packet control:(BOOL)control;
- (BOOL)sendReport:(uint8_t)reportID payload:(NSData *)payload;
- (BOOL)sendNavigationUsage:(uint16_t)usage;
- (BOOL)openRecentApps;
- (BOOL)tap:(Key)key;
- (BOOL)tap:(Key)key waitAfterRelease:(BOOL)wait;
- (BOOL)typeText:(NSString *)text;
- (BOOL)probeMouse:(NSString *)action;
- (void)handlePacket:(NSData *)packet control:(BOOL)control;
- (void)disconnect;
- (void)stop;
@end

@implementation AnikeySession
- (instancetype)init {
    if ((self = [super init])) {
        _protocolMode = 1; _keyDelayMS = 50;
        _keyboard = KeyboardReport(0,@[]); _mouse = MouseReport(0,0,0);
    }
    return self;
}
- (BOOL)fail:(NSString *)message { self.lastError = message; return NO; }
- (BOOL)waitForCompletion:(NSString *)stage {
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 15;
    while (!self.completion && !Interrupted && !self.cancelRequested && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.01);
    if (self.cancelRequested) return [self fail:@"Connection cancelled."];
    if (Interrupted) return [self fail:@"Interrupted."];
    if (!self.completion) return [self fail:[stage stringByAppendingString:@": timed out after 15 seconds."]];
    if (self.completionStatus != kIOReturnSuccess) return [self fail:IOError(stage,self.completionStatus)];
    return YES;
}
- (BOOL)openPSM:(BluetoothL2CAPPSM)psm {
    IOBluetoothL2CAPChannel *channel = nil;
    NSString *stage = [NSString stringWithFormat:@"Opening %@ PSM 0x%04X", psm == 0x11 ? @"control" : @"interrupt", psm];
    self.openingPSM = psm; self.completion = NO;
    IOReturn result = [self.device openL2CAPChannelAsync:&channel withPSM:psm delegate:self];
    // The current macOS bridge can return an inert channel from Async. Explicit
    // public delegate registration starts its streams and delivers OpenComplete.
    if (result == kIOReturnSuccess && channel && channel.PSM == psm && !self.cancelRequested)
        result = [channel setDelegate:self];
    BOOL matched = channel && channel.PSM == psm;
    BOOL opened = result == kIOReturnSuccess && matched && !self.cancelRequested && [self waitForCompletion:stage];
    self.openingPSM = 0;
    if (!opened) {
        IOBluetoothL2CAPChannel *adopted = psm == 0x11 ? self.control : self.interrupt;
        [channel setDelegate:nil]; [channel closeChannel];
        if (adopted && adopted != channel) { [adopted setDelegate:nil]; [adopted closeChannel]; }
        if (psm == 0x11) self.control = nil; else self.interrupt = nil;
        if (self.cancelRequested) return [self fail:@"Connection cancelled."];
        if (result != kIOReturnSuccess) return [self fail:IOError(stage,result)];
        if (channel && !matched) return [self fail:[NSString stringWithFormat:@"HID channel mismatch: requested PSM 0x%04X, actual 0x%04X; input blocked.",psm,channel.PSM]];
        return [self fail:self.lastError ?: IOError(stage,kIOReturnError)];
    }
    if (psm == 0x11) self.control = channel; else self.interrupt = channel;
    self.mouseDiagnostic = [NSString stringWithFormat:@"HID channel open completed: PSM=0x%04X.",psm];
    return YES;
}
- (BOOL)connect:(NSString *)address {
    [self disconnect]; // Preserve one SDP service across connection retries.
    self.lastError = nil; self.closing = NO; self.connecting = YES;
    if (self.cancelRequested) { self.connecting = NO; return [self fail:@"Connection cancelled."]; }
    self.protocolMode = 1; self.LEDs = 0; self.consumerControls = 0; self.suspended = NO;
    self.keyboard = KeyboardReport(0,@[]); self.mouse = MouseReport(0,0,0);
    if (self.dryRun) { self.ready = YES; self.connecting = NO; return YES; }
    IOBluetoothHostController *host = IOBluetoothHostController.defaultController;
    if (!host || host.powerState != kBluetoothHCIPowerStateON) {
        self.connecting = NO;
        return [self fail:@"Bluetooth is unavailable to aniKey. If Bluetooth is on, quit and reopen aniKey from Finder or Terminal outside a restricted runner; allow Bluetooth access on your Mac."];
    }
    NSString *normalized = NormalizeAddress(address);
    if (!normalized) { self.connecting = NO; return [self fail:@"Expected a 12-digit Bluetooth address, optionally separated by colons or hyphens."]; }
    self.device = [IOBluetoothDevice deviceWithAddressString:normalized];
    if (!self.device || !self.device.isPaired) { self.connecting = NO; return [self fail:@"Device is not paired. Pair it in macOS Bluetooth settings first."]; }
    // The modern bridge can publish before its local record cache catches up.
    // Give delegate/cache updates a chance before treating a nil wrapper as failure.
    for (NSUInteger attempt = 0; attempt < 3 && !self.service && !Interrupted; attempt++) {
        self.service = [IOBluetoothSDPServiceRecord publishedServiceRecordWithDictionary:ServiceDictionary()];
        if (!self.service) Pump(0.1);
    }
    if (!self.service) { [self fail:@"Mac Bluetooth pairing is present, but the keyboard service could not start. Quit and reopen aniKey from Finder after allowing Bluetooth access. If it persists, this macOS session may be restricting HID publication."]; goto failed; }
    {
        NSString *serviceError = ServiceValidationError(self.service);
        if (serviceError) { [self fail:serviceError]; [self stop]; return NO; }
    }
    self.mouseDiagnostic = @"Local SDP descriptor and PSMs match. Android mouse recognition remains unverified.";
    if (!self.device.isConnected) {
        self.completion = NO; self.openingPSM = 0;
        IOReturn result = [self.device openConnection:self withPageTimeout:0x2000 authenticationRequired:YES];
        if (result != kIOReturnSuccess) { [self fail:IOError(@"Opening authenticated ACL",result)]; goto failed; }
        if (![self waitForCompletion:@"Opening authenticated ACL"]) goto failed;
    } else {
        // This public API is synchronous; pairing must already exist.
        IOReturn result = [self.device requestAuthentication];
        if (result != kIOReturnSuccess) { [self fail:IOError(@"Authenticating existing ACL",result)]; goto failed; }
    }
    if (self.cancelRequested || ![self openPSM:0x11] || ![self openPSM:0x13]) goto failed;
    self.ready = YES; self.connecting = NO;
    Pump(0.25); // Service negotiation callbacks run before the first input.
    if (!self.ready || self.cancelRequested) goto failed;
    if (![self sendReport:1 payload:self.keyboard]) goto failed;
    self.mouseValidated = YES;
    return YES;
failed:
    [self disconnect]; return NO;
}
- (void)connectionComplete:(IOBluetoothDevice *)device status:(IOReturn)status {
    if (device == self.device && self.connecting && self.openingPSM == 0) {
        self.completionStatus = status; self.completion = YES;
    }
}
- (void)l2capChannelOpenComplete:(IOBluetoothL2CAPChannel *)channel status:(IOReturn)status {
    if (self.connecting && channel.PSM == self.openingPSM && channel.device == self.device) {
        self.completionStatus = status; self.completion = YES;
        if (status == kIOReturnSuccess && channel.device == self.device) {
            if (channel.PSM == 0x11) self.control = channel;
            else if (channel.PSM == 0x13) self.interrupt = channel;
        }
    }
}
- (void)l2capChannelClosed:(IOBluetoothL2CAPChannel *)channel {
    if (!self.closing && (channel == self.control || channel == self.interrupt)) {
        self.ready = NO;
        self.lastError = [NSString stringWithFormat:@"HID PSM 0x%04X closed. No input was retried.", channel.PSM];
        self.completionStatus = kIOReturnNotOpen; self.completion = YES;
        if (channel == self.control) self.control = nil; else self.interrupt = nil;
    }
}
- (BOOL)writePacket:(NSData *)packet control:(BOOL)control {
    if (self.dryRun) {
        if (self.trace) printf("%s %s\n", control ? "CONTROL" : "INTERRUPT", Hex(packet).UTF8String);
        return YES;
    }
    IOBluetoothL2CAPChannel *channel = control ? self.control : self.interrupt;
    if (!channel) return [self fail:@"HID channel is not open."];
    // writeSync owns the buffer for the complete call, avoiding async buffer lifetime hazards.
    NSMutableData *buffer = [packet mutableCopy];
    IOReturn result = [channel writeSync:buffer.mutableBytes length:(UInt16)buffer.length];
    if (result != kIOReturnSuccess) { self.ready = NO; return [self fail:IOError(control ? @"Writing control packet" : @"Writing input report",result)]; }
    return YES;
}

- (BOOL)sendReport:(uint8_t)reportID payload:(NSData *)payload {
    if (!self.ready) return [self fail:self.lastError ?: @"Not connected."];
    if (self.suspended) return [self fail:@"The host suspended input. Wait for EXIT_SUSPEND or reconnect."];
    if (!((reportID == 1 && payload.length == 8) || (reportID == 2 && payload.length == 2) || (reportID == 10 && payload.length == 5))) return [self fail:@"Invalid input report."];
    if (reportID == 2) {
        if (!self.protocolMode) return [self fail:@"Consumer navigation is unavailable in boot protocol."];
        const uint8_t *bytes = payload.bytes;
        uint16_t value = (uint16_t)(bytes[0] | ((uint16_t)bytes[1] << 8));
        if (bytes[1] != 0 || (value != 0 && value != 1 && value != 4))
            return [self fail:@"Only consumer Back and Home actions are supported."];
        uint8_t prefix[] = {0xA1,2};
        NSMutableData *packet = [Bytes(prefix,2) mutableCopy]; [packet appendData:payload];
        if (![self writePacket:packet control:NO]) return NO;
        self.consumerControls = value;
        return YES;
    }
    if (reportID == 10) {
        const uint8_t *bytes = payload.bytes;
        if ((bytes[0] & ~3) || bytes[3] || bytes[1] == 0x80 || bytes[2] == 0x80 || bytes[4] == 0x80)
            return [self fail:@"Invalid mouse fields: only left/right buttons, X/Y movement and vertical wheel are supported."];
        if (!self.protocolMode && bytes[4]) return [self fail:@"Scrolling is unavailable in boot protocol."];
        NSString *state = (self.mouseValidated || self.mouseProbeRemaining) ? @"attempt" : @"blocked: mouse unavailable";
        self.mouseDiagnostic = [NSString stringWithFormat:@"Mouse report=%u payload=%lu wire=%lu HIDP=A1 mode=%@ channel=interrupt PSM=0x%04X buttons=%u dx=%d dy=%d wheel=%d %@",
            self.protocolMode ? 10 : 2,(unsigned long)(self.protocolMode ? 5 : 3),(unsigned long)(self.protocolMode ? 7 : 5),self.protocolMode ? @"report" : @"boot",self.interrupt ? self.interrupt.PSM : 0x13,bytes[0],(int8_t)bytes[1],(int8_t)bytes[2],(int8_t)bytes[4],state];
        if (self.mouseDiagnostics) fprintf(stderr,"%s\n",self.mouseDiagnostic.UTF8String);
        if (!self.mouseValidated && !self.mouseProbeRemaining) return [self fail:@"Mouse input is unavailable until the HID connection completes."];
        if (self.mouseProbeRemaining) self.mouseProbeRemaining--;
    }
    uint8_t wireID = reportID == 10 && !self.protocolMode ? 2 : reportID;
    const uint8_t prefix[] = {0xA1,wireID};

    NSMutableData *packet = [Bytes(prefix,2) mutableCopy];
    [packet appendData:reportID == 10 && !self.protocolMode ? [payload subdataWithRange:NSMakeRange(0,3)] : payload];
    BOOL sent = [self writePacket:packet control:NO];
    if (reportID == 10) {
        self.mouseDiagnostic = [self.mouseDiagnostic stringByAppendingString:sent ? @" · sent" : @" · write failed"];
        if (self.mouseDiagnostics) fprintf(stderr,"%s\n",self.mouseDiagnostic.UTF8String);
    }
    if (!sent) return NO;
    if (reportID == 1) self.keyboard = payload;
    else self.mouse = MouseReport(((const uint8_t *)payload.bytes)[0],0,0);
    return YES;
}
- (BOOL)sendNavigationUsage:(uint16_t)usage {
    if (!self.protocolMode) return [self fail:@"Phone navigation gestures require HID report protocol; no report was sent in boot mode."];
    uint8_t bit = usage == 0x0224 ? 1 : usage == 0x0223 ? 4 : 0;
    if (!bit) return [self fail:@"Unsupported navigation usage."];
    uint8_t press[] = {bit,0}, release[] = {0,0};
    if (![self sendReport:2 payload:Bytes(press,sizeof(press))]) return NO;
    Pump(0.035);
    return [self sendReport:2 payload:Bytes(release,sizeof(release))];
}
- (BOOL)openRecentApps {
    // Deliver a complete Windows/Meta+Tab chord: modifier first, Tab second,
    // Tab up while the modifier is still held, then modifier up. Some hosts
    // do not recognize a shortcut when modifier and key arrive simultaneously.
    if (![self sendReport:1 payload:KeyboardReport(0,@[])]) return NO;
    if (![self sendReport:1 payload:KeyboardReport(8,@[])]) return NO;
    Pump(0.035);
    if (![self sendReport:1 payload:KeyboardReport(8,@[@0x2B])]) return NO;
    Pump(0.05);
    if (![self sendReport:1 payload:KeyboardReport(8,@[])]) return NO;
    Pump(0.02);
    return [self sendReport:1 payload:KeyboardReport(0,@[])];
}
- (BOOL)probeMouse:(NSString *)action {
    NSDictionary *directions = @{@"left":@[@-1,@0],@"right":@[@1,@0],@"up":@[@0,@-1],@"down":@[@0,@1]};
    NSArray *delta = directions[action];
    BOOL leftClick = [action isEqual:@"left-click"], rightClick = [action isEqual:@"right-click"];
    if (!delta && !leftClick && !rightClick) return [self fail:@"mouse-test requires left, right, up, down, left-click, or right-click."];
    self.mouseDiagnostics = YES;
    fprintf(stderr,"One bounded mouse test; no input is retried.\n");
    self.mouseProbeRemaining = delta ? 1 : 2;
    @try {
        if (delta) return [self sendReport:10 payload:MouseReport(0,[delta[0] intValue],[delta[1] intValue])];
        if (![self sendReport:10 payload:MouseReport(leftClick ? 1 : 2,0,0)]) return NO;
        Pump(0.02);
        return [self sendReport:10 payload:MouseReport(0,0,0)];
    } @finally { self.mouseProbeRemaining = 0; }
}
- (BOOL)tap:(Key)key {
    return [self tap:key waitAfterRelease:YES];
}
- (BOOL)tap:(Key)key waitAfterRelease:(BOOL)wait {
    if (![self sendReport:1 payload:KeyboardReport(key.modifiers,@[@(key.usage)])]) return NO;
    Pump(self.keyDelayMS / 1000.0);
    BOOL released = [self sendReport:1 payload:KeyboardReport(0,@[])];
    if (wait) Pump(self.keyDelayMS / 1000.0);
    if (Interrupted) return [self fail:@"Interrupted; stopped input."];
    return released;
}
- (BOOL)typeText:(NSString *)text {
    NSString *error = nil;
    if (!ValidateText(text,&error)) return [self fail:error]; // Reject the whole string before any key.
    for (NSUInteger i = 0; i < text.length; i++) {
        if (Interrupted) return [self fail:@"Interrupted; stopped input."];
        Key key = {0};
        if (!ASCIIKey([text characterAtIndex:i],&key)) return [self fail:@"Unsupported character."];
        if (![self tap:key]) return NO;
    }
    return YES;
}
- (void)handshake:(uint8_t)status { [self writePacket:Bytes(&status,1) control:YES]; }
- (BOOL)applyLEDs:(NSData *)packet {
    const uint8_t *p = packet.bytes;
    if (packet.length != 3 || (p[0] & 0x0F) != 2 || p[1] != 1) return NO;
    self.LEDs = p[2] & 0x1F; return YES;
}
- (void)handlePacket:(NSData *)packet control:(BOOL)control {
    if (!packet.length) { if (control) [self handshake:4]; return; }
    const uint8_t *p = packet.bytes;
    uint8_t transaction = p[0] >> 4, parameter = p[0] & 15;
    if (!control) { if (transaction == 0xA) [self applyLEDs:packet]; return; }
    switch (transaction) {
        case 0: break; // Never answer a HANDSHAKE with another HANDSHAKE.
        case 1:
            if (packet.length != 1) break; // HID_CONTROL has no response.
            if (parameter == 3) self.suspended = YES;
            else if (parameter == 4) self.suspended = NO;
            else if (parameter == 5) { self.lastError = @"Host requested virtual cable unplug. Reconnect explicitly."; [self stop]; }
            else if (parameter == 1 || parameter == 2) { self.protocolMode = 1; self.suspended = NO; self.keyboard = KeyboardReport(0,@[]); self.mouse = MouseReport(0,0,0); self.consumerControls = 0; }
            break;
        case 4: { // GET_REPORT: type in bits 0..1, optional little-endian buffer size.
            BOOL sized = (parameter & 8) != 0;
            if ((parameter & 4) || packet.length != (sized ? 4UL : 2UL)) { [self handshake:4]; break; }
            uint8_t type = parameter & 3, reportID = p[1];
            NSData *payload = nil;
            if (type == 1 && reportID == 1) payload = self.keyboard;
            else if (type == 1 && reportID == 2 && self.protocolMode) { uint16_t value = self.consumerControls; payload = Bytes((uint8_t[]){(uint8_t)value,(uint8_t)(value >> 8)},2); }
            else if (type == 1 && reportID == (self.protocolMode ? 10 : 2)) payload = self.protocolMode ? self.mouse : [self.mouse subdataWithRange:NSMakeRange(0,3)];
            else if (type == 2 && reportID == 1) { uint8_t led = self.LEDs; payload = Bytes(&led,1); }
            else { [self handshake:(type == 1 || type == 2) ? 2 : 3]; break; }
            NSMutableData *body = [Bytes(&reportID,1) mutableCopy]; [body appendData:payload];
            if (sized) { NSUInteger limit = p[2] | ((NSUInteger)p[3] << 8); if (body.length > limit) body.length = limit; }
            uint8_t header = 0xA0 | type;
            NSMutableData *response = [Bytes(&header,1) mutableCopy]; [response appendData:body];
            [self writePacket:response control:YES]; break;
        }
        case 5:
            if ((parameter & 3) != 2) [self handshake:3];
            else if (packet.length < 2 || (parameter & 0xC)) [self handshake:4];
            else if (p[1] != 1) [self handshake:2];
            else [self handshake:[self applyLEDs:packet] ? 0 : 4];
            break;
        case 6: {
            if (parameter || packet.length != 1) { [self handshake:4]; break; }
            const uint8_t response[] = {0xA0,self.protocolMode}; [self writePacket:Bytes(response,2) control:YES]; break;
        }
        case 7:
            if (parameter > 1 || packet.length != 1) [self handshake:4];
            else {
                self.protocolMode = parameter; [self handshake:0];
            }
            break;
        case 0xA: [self applyLEDs:packet]; break; // DATA output: no response.
        default: [self handshake:3]; break; // Unsupported (including deprecated GET/SET_IDLE).
    }
}
- (void)l2capChannelData:(IOBluetoothL2CAPChannel *)channel data:(void *)pointer length:(size_t)length {
    // Channel setup can dispatch data before the open-completion callback.
    if (self.connecting && channel.PSM == self.openingPSM && channel.device == self.device) {
        if (channel.PSM == 0x11 && !self.control) self.control = channel;
        else if (channel.PSM == 0x13 && !self.interrupt) self.interrupt = channel;
    }
    if (channel == self.control || channel == self.interrupt)
        [self handlePacket:Bytes(pointer,length) control:channel == self.control];
}
- (void)disconnect {
    // Preserve the existing Bluetooth bond: this closes only our HID channels.
    self.closing = YES;
    NSString *previousError = self.lastError;
    if (self.ready && !self.suspended) {
        if (memcmp(self.keyboard.bytes, (uint8_t[8]){0},8) != 0) [self sendReport:1 payload:KeyboardReport(0,@[])];
        if (self.consumerControls) [self sendReport:2 payload:Bytes((uint8_t[2]){0,0},2)];
        if (((const uint8_t *)self.mouse.bytes)[0]) [self sendReport:10 payload:MouseReport(0,0,0)];
    }
    self.ready = NO; self.connecting = NO; self.mouseValidated = NO;
    [self.control setDelegate:nil]; [self.interrupt setDelegate:nil];
    [self.control closeChannel]; [self.interrupt closeChannel];
    self.control = nil; self.interrupt = nil;
    self.device = nil;
    // Do not tear down a shared ACL: the phone may use other Bluetooth services.
    if (previousError) self.lastError = previousError;
    self.closing = NO;
}
- (void)stop {
    [self disconnect];
    // Remove our local advertisement, never the remote device or its pairing.
    [self.service removeServiceRecord]; self.service = nil;
}
@end

#pragma mark - CLI validation and dispatch

static BOOL ParseInteger(NSString *text, NSInteger low, NSInteger high, NSInteger *out) {
    NSScanner *scanner = [NSScanner scannerWithString:text];
    scanner.charactersToBeSkipped = nil;
    long long value;
    if (![scanner scanLongLong:&value] || !scanner.isAtEnd || value < low || value > high) return NO;
    *out = (NSInteger)value; return YES;
}
static BOOL ValidateCommand(NSArray<NSString *> *args, NSString **error) {
    if (!args.count) return Fail(error,@"Missing command; use --help.");
    NSString *command = args[0]; NSUInteger count = args.count - 1;
    if ([command isEqual:@"mouse-test"]) return count == 1 && [@[@"left",@"right",@"up",@"down",@"left-click",@"right-click"] containsObject:args[1]] ? YES : Fail(error,@"mouse-test requires left, right, up, down, left-click, or right-click.");
    if ([command isEqual:@"pin"] || [command isEqual:@"text"]) {
        if (count != 1) return Fail(error,@"pin/text requires exactly one quoted argument.");
        if ([command isEqual:@"pin"] && (!args[1].length || [args[1] rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location != NSNotFound))
            return Fail(error,@"PIN must contain one or more ASCII digits.");
        return ValidateText(args[1],error);
    }
    if ([command isEqual:@"key"]) {
        Key key; return count == 1 ? ParseChord(args[1],&key,error) : Fail(error,@"key requires one chord, e.g. ctrl+a.");
    }
    if (([command isEqual:@"list"] || [command isEqual:@"check"]) && !count) return YES;
    return Fail(error,[@"Unknown command or unexpected arguments: " stringByAppendingString:command]);
}
static BOOL ExecuteCommand(AnikeySession *session, NSArray<NSString *> *args) {
    NSString *error = nil;
    if (!ValidateCommand(args,&error)) { session.lastError = error; return NO; }
    NSString *command = args[0];
    if ([command isEqual:@"check"]) return session.ready;
    if ([command isEqual:@"mouse-test"]) return [session probeMouse:args[1]];
    if ([command isEqual:@"text"]) return [session typeText:args[1]];
    if ([command isEqual:@"pin"]) return [session typeText:args[1]] && [session tap:(Key){0x28,0}];
    if ([command isEqual:@"key"]) {
        Key key = {0};
        if (!ParseChord(args[1],&key,&error)) { session.lastError = error; return NO; }
        return [session tap:key];
    }
    return NO;
}

#pragma mark - Native keyboard and AppKit window

// A persistent run-loop thread owns GUI Bluetooth calls and channel callbacks.
// AppKit never waits for authentication, channel opens, packet writes or teardown.
@interface TransportWorker : NSObject
@property (strong) NSThread *thread;
@property (strong) NSCondition *startup;
@property (strong) NSMutableArray<dispatch_block_t> *jobs;
@property BOOL started, stopping;
@property BOOL executing;
- (BOOL)perform:(dispatch_block_t)work;
- (void)finish;
@end
@implementation TransportWorker
- (instancetype)init {
    if ((self = [super init])) {
        _startup = [NSCondition new]; _jobs = [NSMutableArray array]; [_startup lock];
        _thread = [[NSThread alloc] initWithTarget:self selector:@selector(run) object:nil];
        _thread.name = @"aniKey Bluetooth"; [_thread start];
        while (!_started) [_startup wait]; // Thread startup only; no Bluetooth work.
        [_startup unlock];
    }
    return self;
}
- (void)run {
    @autoreleasepool {
        NSRunLoop *loop = NSRunLoop.currentRunLoop;
        NSPort *port = [NSMachPort port]; [loop addPort:port forMode:NSDefaultRunLoopMode];
        [self.startup lock]; self.started = YES; [self.startup signal]; [self.startup unlock];
        while (!self.stopping) {
            @autoreleasepool { [loop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:1]]; }
        }
        [loop removePort:port forMode:NSDefaultRunLoopMode]; [port invalidate]; self.thread = nil;
    }
}
- (void)execute:(dispatch_block_t)work {
    [self.jobs addObject:work];
    if (self.executing) return; // SDK waits can pump this run loop recursively.
    self.executing = YES;
    while (self.jobs.count && !self.stopping) {
        dispatch_block_t next = self.jobs.firstObject; [self.jobs removeObjectAtIndex:0]; next();
    }
    self.executing = NO;
}
- (BOOL)perform:(dispatch_block_t)work {
    NSThread *thread = self.thread;
    if (!thread || self.stopping) return NO;
    [self performSelector:@selector(execute:) onThread:thread withObject:[work copy] waitUntilDone:NO];
    return YES;
}
- (void)finish { self.stopping = YES; }
@end

// macOS virtual keycodes -> USB HID keyboard usages. Use physical positions,
// including navigation/function keys, instead of interpreting typed characters.
static uint8_t PhysicalUsage(unsigned short code) {
    static const uint8_t map[128] = {
        [0x00]=0x04,[0x01]=0x16,[0x02]=0x07,[0x03]=0x09,[0x04]=0x0B,[0x05]=0x0A,
        [0x06]=0x1D,[0x07]=0x1B,[0x08]=0x06,[0x09]=0x19,[0x0A]=0x64,[0x0B]=0x05,
        [0x0C]=0x14,[0x0D]=0x1A,[0x0E]=0x08,[0x0F]=0x15,[0x10]=0x1C,[0x11]=0x17,
        [0x12]=0x1E,[0x13]=0x1F,[0x14]=0x20,[0x15]=0x21,[0x16]=0x23,[0x17]=0x22,
        [0x18]=0x2E,[0x19]=0x26,[0x1A]=0x24,[0x1B]=0x2D,[0x1C]=0x25,[0x1D]=0x27,
        [0x1E]=0x30,[0x1F]=0x12,[0x20]=0x18,[0x21]=0x2F,[0x22]=0x0C,[0x23]=0x13,
        [0x24]=0x28,[0x25]=0x0F,[0x26]=0x0D,[0x27]=0x34,[0x28]=0x0E,[0x29]=0x33,
        [0x2A]=0x31,[0x2B]=0x36,[0x2C]=0x38,[0x2D]=0x11,[0x2E]=0x10,[0x2F]=0x37,
        [0x30]=0x2B,[0x31]=0x2C,[0x32]=0x35,[0x33]=0x2A,[0x35]=0x29,
        [0x41]=0x63,[0x43]=0x55,[0x45]=0x57,[0x47]=0x53,[0x4B]=0x54,[0x4C]=0x58,[0x4E]=0x56,
        [0x52]=0x62,[0x53]=0x59,[0x54]=0x5A,[0x55]=0x5B,[0x56]=0x5C,[0x57]=0x5D,
        [0x58]=0x5E,[0x59]=0x5F,[0x5B]=0x60,[0x5C]=0x61,
        [0x60]=0x3E,[0x61]=0x3F,[0x62]=0x40,[0x63]=0x3C,[0x64]=0x41,[0x65]=0x42,
        [0x67]=0x44,[0x6D]=0x43,[0x6F]=0x45,[0x72]=0x49,[0x73]=0x4A,[0x74]=0x4B,
        [0x75]=0x4C,[0x76]=0x3D,[0x77]=0x4D,[0x78]=0x3B,[0x79]=0x4E,[0x7A]=0x3A,
        [0x7B]=0x50,[0x7C]=0x4F,[0x7D]=0x51,[0x7E]=0x52
    };
    return code < 128 ? map[code] : 0;
}
static uint8_t PhysicalModifiers(NSEventModifierFlags flags) {
    return ((flags & NSEventModifierFlagControl) ? 1 : 0)
        | ((flags & NSEventModifierFlagCommand) ? 1 : 0)
        | ((flags & NSEventModifierFlagShift) ? 2 : 0) | ((flags & NSEventModifierFlagOption) ? 4 : 0);
}

#pragma mark - Minimal native interface

@class AnikeyApp;
@interface KeyboardSurface : NSView
@property (weak) AnikeyApp *owner;
@end
@interface CursorPad : NSView
@property (weak) AnikeyApp *owner;
@property (strong) NSTrackingArea *tracking;
@property BOOL controlling, pressed, gestureActive, scrollDragging;
@property NSPoint lastPoint;
@property CGFloat gestureDeltaX, gestureDeltaY;
@property PadAxis gestureAxis;
@property NSUInteger touchCount;
@property BOOL touchSequenceBlocked;
@property (copy) NSString *gestureFeedback;
- (void)reset;
@end
@interface AnikeyApp : NSObject <NSApplicationDelegate, NSWindowDelegate, CBCentralManagerDelegate>
@property (strong) AnikeySession *session;
@property (strong) TransportWorker *transport;
@property (strong) NSWindow *window;
@property (strong) NSPopUpButton *devices;
@property (strong) NSTextField *status;
@property (strong) NSButton *connectionButton, *refreshButton;
@property (strong) KeyboardSurface *keyboardSurface;
@property (strong) CursorPad *cursorPad;
@property (strong) NSSlider *padSizeSlider;
@property (strong) NSPopUpButton *scrollSpeedPicker;
@property double scrollScale;
@property (strong) PointerMotion *motion;
@property (strong) NSTimer *pointerTimer;
@property BOOL pointerBusy;
@property uint8_t pointerButtons;
@property NSUInteger pointerEpoch;
@property (strong) NSMutableArray<NSButton *> *inputControls;
@property (strong) NSPopover *detailsPopover;
@property (strong) NSTimer *timer;
@property (strong) CBCentralManager *bluetooth;
@property (strong) id eventMonitor;
@property (strong) NSMutableOrderedSet<NSNumber *> *heldKeys;
@property BOOL busy, paused, bluetoothAvailable, wasReady, capsState;
@property BOOL connectionPending, refreshingDevices, terminating;
@property BOOL terminationReplySent;
@property NSUInteger connectionGeneration, inputEpoch;
@property (copy) NSString *selectedAddress;
- (BOOL)canSendInput;
- (void)resetPointer;
- (void)flushPointer:(NSTimer *)timer;
- (void)sendPointerButton:(uint8_t)button;
- (void)beginPointerDrag;
- (void)endPointerDrag;
- (void)endPointerScroll;
- (NSArray<NSData *> *)takePointerReports:(uint8_t)buttons;
- (void)sendNavigationUsage:(uint16_t)usage;
- (void)performPadAction:(PadAction)action;
- (void)padNavigation:(NSButton *)sender;
- (void)resizePad:(NSSlider *)sender;
- (void)changeScrollSpeed:(id)sender;
- (void)layoutPad;
- (void)physicalKey:(unsigned short)code down:(BOOL)down flags:(NSEventModifierFlags)flags;
- (void)physicalFlags:(NSEvent *)event;
- (void)releaseInput;
- (void)startBluetooth;
- (void)rememberSelection;
- (void)refresh:(id)sender;
- (void)update:(NSTimer *)timer;
- (void)key:(NSButton *)sender;
- (void)refreshControls;
- (void)connectionAction:(id)sender;
- (void)onTransport:(void (^)(AnikeySession *session))work completion:(dispatch_block_t)completion;
- (void)enqueueInput:(void (^)(AnikeySession *session))work completion:(dispatch_block_t)completion;
@end

@implementation KeyboardSurface
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)becomeFirstResponder { self.needsDisplay = YES; return YES; }
- (BOOL)resignFirstResponder { [self.owner releaseInput]; self.needsDisplay = YES; return YES; }
- (void)mouseDown:(NSEvent *)event { (void)event; [self.window makeFirstResponder:self]; }
- (void)keyDown:(NSEvent *)event { (void)event; } // Offline typing is ignored, never buffered.
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    BOOL focused = self.window.isKeyWindow && self.window.firstResponder == self;
    BOOL available = [self.owner canSendInput];
    [(focused && available ? [NSColor.controlAccentColor colorWithAlphaComponent:0.08] : NSColor.controlBackgroundColor) setFill];
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,0.5,0.5) xRadius:10 yRadius:10];
    [shape fill]; [(focused && available ? NSColor.controlAccentColor : NSColor.separatorColor) setStroke]; [shape stroke];
    NSString *title = available ? (focused ? @"Type on your Mac" : @"Click here to type") : @"Keyboard waiting for connection";
    NSString *hint = @"⌘ acts as Ctrl · ⌘⇧Esc returns control to your Mac";
    [title drawAtPoint:NSMakePoint(16,42) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:16 weight:NSFontWeightSemibold],NSForegroundColorAttributeName:NSColor.labelColor}];
    [hint drawAtPoint:NSMakePoint(16,17) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12],NSForegroundColorAttributeName:NSColor.secondaryLabelColor}];
}
@end

@implementation CursorPad
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.allowedTouchTypes = NSTouchTypeMaskIndirect;
        self.wantsRestingTouches = NO;
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:NSCursor.crosshairCursor]; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (void)updateTrackingAreas {
    [super updateTrackingAreas]; if (self.tracking) [self removeTrackingArea:self.tracking];
    self.tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved|NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:self.tracking];
}
- (void)reset {
    self.controlling = self.pressed = self.gestureActive = self.scrollDragging = NO;
    self.touchSequenceBlocked = NO; self.touchCount = 0;
    self.gestureAxis = PadAxisUndecided; self.gestureDeltaX = self.gestureDeltaY = 0;
    self.gestureFeedback = nil; self.needsDisplay = YES;
}
- (void)mouseEntered:(NSEvent *)event {
    if (self.owner.terminating) return;
    self.controlling = YES; self.lastPoint = [self convertPoint:event.locationInWindow fromView:nil]; self.needsDisplay = YES;
}
- (void)mouseMoved:(NSEvent *)event {
    if (self.owner.terminating) return;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (!NSPointInRect(point,self.bounds)) { [self.owner resetPointer]; return; }
    if (!self.controlling) { [self mouseEntered:event]; return; } // First entry establishes an origin, never a jump.
    if (!self.gestureActive && (self.pressed || self.touchCount < 2) && !self.touchSequenceBlocked &&
        self.owner.session.mouseValidated && [self.owner canSendInput]) {
        [self.owner.motion addX:point.x-self.lastPoint.x y:point.y-self.lastPoint.y];
        self.gestureFeedback = nil;
    }
    self.lastPoint = point; self.needsDisplay = YES;
}
- (void)mouseDown:(NSEvent *)event {
    if (self.pressed || self.touchSequenceBlocked) return;
    // A physical press takes over from a scroll sequence that has not yet ended.
    if (self.gestureActive) [self.owner resetPointer];
    [self mouseMoved:event];
    if (!self.controlling) return;
    self.pressed = YES;
    self.gestureFeedback = nil; self.needsDisplay = YES;
    [self.owner beginPointerDrag];
}
- (void)mouseDragged:(NSEvent *)event {
    if (!self.pressed) return;
    [self mouseMoved:event];
    [self.owner flushPointer:nil];
}
- (void)mouseUp:(NSEvent *)event {
    if (!self.pressed) return;
    [self mouseMoved:event];
    [self.owner endPointerDrag];
    self.pressed = NO; self.needsDisplay = YES;
    self.gestureFeedback = nil;
}
- (void)rightMouseDown:(NSEvent *)event {
    if (self.pressed || self.gestureActive || self.touchSequenceBlocked) return;
    [self mouseMoved:event]; if (self.controlling) [self.owner sendPointerButton:2];
}
- (void)rightMouseUp:(NSEvent *)event { (void)event; }
- (void)scrollWheel:(NSEvent *)event {
    if (![self.owner canSendInput] || !self.owner.session.mouseValidated) { [self.owner resetPointer]; return; }
    // A held physical click owns the interaction. In particular, a late scroll
    // cancellation must not release or reinterpret a newer pointer drag.
    if (self.pressed) return;
    if (event.phase & NSEventPhaseCancelled) { [self.owner resetPointer]; return; }
    // macOS owns gestures with three or more fingers. Ignore their scroll tails
    // and inertia so they cannot move or click the phone.
    if (event.momentumPhase != NSEventPhaseNone || self.touchSequenceBlocked || self.touchCount >= 3) return;
    if (event.phase == NSEventPhaseNone) {
        if (!self.gestureActive && !self.pressed && self.owner.session.protocolMode) {
            [self.owner.motion addWheel:event.scrollingDeltaY*(event.hasPreciseScrollingDeltas ? self.owner.scrollScale/PadScrollPointsPerStep : 1.0)];
            [self.owner flushPointer:nil];
            self.gestureFeedback = @"Scrolling"; self.needsDisplay = YES;
        }
        return; // Unphased mouse wheels scroll, but cannot navigate.
    }
    if ((event.phase & NSEventPhaseBegan) || (!self.gestureActive && (event.phase & NSEventPhaseChanged))) {
        [self.owner resetPointer];
        self.controlling = YES; self.pressed = NO; self.gestureActive = YES; self.gestureAxis = PadAxisUndecided;
        self.gestureDeltaX = self.gestureDeltaY = 0; self.gestureFeedback = nil;
    }
    if (!self.gestureActive) return;
    self.gestureDeltaX += event.scrollingDeltaX; self.gestureDeltaY += event.scrollingDeltaY;
    CGFloat scroll = event.scrollingDeltaY, horizontal = event.scrollingDeltaX;
    if (self.gestureAxis == PadAxisUndecided) {
        self.gestureAxis = ScrollPadAxis(self.gestureDeltaX,self.gestureDeltaY);
        scroll = self.gestureDeltaY; // Include distance accumulated before axis lock.
        horizontal = self.gestureDeltaX;
    }
    if (self.gestureAxis == PadAxisVertical) {
        if (self.owner.session.protocolMode) {
            [self.owner.motion addWheel:scroll*(event.hasPreciseScrollingDeltas ? self.owner.scrollScale/PadScrollPointsPerStep : 1.0)];
            [self.owner flushPointer:nil];
            self.gestureFeedback = @"Scrolling";
        } else self.gestureFeedback = @"Scrolling needs report mode";
    } else if (self.gestureAxis == PadAxisHorizontal) {
        if (!self.scrollDragging && fabs(self.gestureDeltaX) >= PadContentDragDistance) {
            // Keep the paired host's existing mouse report layout: horizontal
            // content scrolling is a primary-button drag, not a new HID axis.
            [self.owner beginPointerDrag]; self.scrollDragging = self.owner.pointerButtons == 1;
            horizontal = self.gestureDeltaX;
        }
        if (self.scrollDragging) {
            [self.owner.motion addX:horizontal y:0]; [self.owner flushPointer:nil];
            self.gestureFeedback = @"Mouse drag · Select or move items";
        }
    }
    self.needsDisplay = YES;
    if (event.phase & NSEventPhaseEnded) {
        if (self.scrollDragging) [self.owner endPointerDrag];
        else [self.owner endPointerScroll];
        self.scrollDragging = NO;
        self.gestureActive = NO;
        self.gestureFeedback = nil;
    }
}
- (void)trackTouches:(NSEvent *)event {
    NSSet<NSTouch *> *touching = [event touchesMatchingPhase:NSTouchPhaseTouching inView:self];
    if (touching.count >= 3 && !self.touchSequenceBlocked) {
        [self.owner resetPointer];
        self.touchSequenceBlocked = YES;
    }
    self.touchCount = touching.count;
    if (!self.touchCount) self.touchSequenceBlocked = NO;
    self.needsDisplay = YES;
}
- (void)touchesBeganWithEvent:(NSEvent *)event { [self trackTouches:event]; }
- (void)touchesMovedWithEvent:(NSEvent *)event { [self trackTouches:event]; }
- (void)touchesEndedWithEvent:(NSEvent *)event { [self trackTouches:event]; }
- (void)touchesCancelledWithEvent:(NSEvent *)event {
    (void)event;
    // AppKit can cancel raw touches when it recognizes a scroll gesture. The
    // scroll event stream then owns its lifecycle, just as mouse-up owns a click.
    if (self.pressed || self.gestureActive) { self.touchCount = 0; return; }
    [self.owner resetPointer];
}
- (void)mouseExited:(NSEvent *)event { (void)event; [self.owner resetPointer]; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    [NSColor.controlBackgroundColor setFill];
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,0.5,0.5) xRadius:10 yRadius:10];
    [shape fill]; [(self.controlling ? NSColor.controlAccentColor : NSColor.separatorColor) setStroke]; [shape stroke];
    BOOL available = self.owner.session.mouseValidated && [self.owner canSendInput];
    NSString *title = self.gestureFeedback ?: (available ? (self.pressed ? @"Holding · Mouse drag" : @"Phone mouse pad") : @"Connect to control the phone");
    if (self.controlling) {
        NSPoint point = self.lastPoint;
        [NSColor.controlAccentColor setFill];
        CGFloat radius = (self.pressed || self.scrollDragging) ? 9 : 6;
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(point.x-radius,point.y-radius,radius*2,radius*2)] fill];
        [NSColor.labelColor setStroke];
        NSBezierPath *cross = [NSBezierPath bezierPath];
        [cross moveToPoint:NSMakePoint(point.x-11,point.y)]; [cross lineToPoint:NSMakePoint(point.x+11,point.y)];
        [cross moveToPoint:NSMakePoint(point.x,point.y-11)]; [cross lineToPoint:NSMakePoint(point.x,point.y+11)]; [cross stroke];
    }
    [title drawAtPoint:NSMakePoint(16,12) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:14 weight:NSFontWeightMedium],NSForegroundColorAttributeName:NSColor.labelColor}];
    NSDictionary *hint = @{NSFontAttributeName:[NSFont systemFontOfSize:11],NSForegroundColorAttributeName:NSColor.secondaryLabelColor};
    NSArray *guide = @[@"Move to point · Click to select/open",
                      @"2 fingers up/down: scroll · Change speed below",
                      @"Hold + drag or 2 fingers sideways: mouse drag",
                      @"May select text/items; phone swipes depend on the app."];
    for (NSUInteger i = 0; i < guide.count; i++)
        [guide[i] drawAtPoint:NSMakePoint(16,36+16*i) withAttributes:hint];
}
@end

@implementation AnikeyApp
- (instancetype)init {
    if ((self = [super init])) {
        _heldKeys = [NSMutableOrderedSet orderedSet]; _motion = [PointerMotion new];
        _inputControls = [NSMutableArray array];
        _scrollScale = 0.125;
    }
    return self;
}
- (BOOL)canSendInput { return self.session.ready && !self.session.suspended && !self.busy && !self.paused; }
- (void)changeScrollSpeed:(id)sender {
    [self resetPointer];
    NSInteger choice = self.scrollSpeedPicker.selectedItem.tag;
    self.scrollScale = choice == 3 ? 0.125 : choice == 2 ? 1.5 : choice == 1 ? 1.0 : 0.5;
    if (sender) [NSUserDefaults.standardUserDefaults setInteger:choice forKey:@"AnikeyScrollSpeed"];
}
- (void)resizePad:(NSSlider *)sender {
    [self resetPointer];
    double value = MAX(0,MIN(1,self.padSizeSlider.doubleValue));
    [self.window setContentSize:NSMakeSize(NSWidth(self.window.contentView.bounds),482+176*value)];
    [self layoutPad];
    if (sender) [NSUserDefaults.standardUserDefaults setDouble:value forKey:@"AnikeyPadSize"];
}
- (void)layoutPad {
    if (!self.cursorPad || !self.padSizeSlider) return;
    NSSize size = self.window.contentView.bounds.size;
    CGFloat width = MIN(size.width-40,360+(size.width-400)*self.padSizeSlider.doubleValue);
    self.cursorPad.frame = NSMakeRect((size.width-width)/2,68,width,MAX(104,size.height-378));
    self.cursorPad.needsDisplay = YES;
}
- (void)windowDidResize:(NSNotification *)notification {
    (void)notification; if (!self.padSizeSlider) return;
    [self resetPointer];
    self.padSizeSlider.doubleValue = MAX(0,MIN(1,(NSHeight(self.window.contentView.bounds)-482)/176));
    [self layoutPad]; [self refreshControls];
}
- (void)windowDidEndLiveResize:(NSNotification *)notification {
    (void)notification; [NSUserDefaults.standardUserDefaults setDouble:self.padSizeSlider.doubleValue forKey:@"AnikeyPadSize"];
}
- (NSTextField *)label:(NSString *)text frame:(NSRect)frame in:(NSView *)view {
    NSTextField *field = [NSTextField wrappingLabelWithString:text]; field.frame = frame;
    field.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium]; field.textColor = NSColor.secondaryLabelColor;
    [view addSubview:field]; return field;
}
- (NSButton *)button:(NSString *)title frame:(NSRect)frame in:(NSView *)view action:(SEL)action {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action]; button.frame = frame;
    button.font = [NSFont systemFontOfSize:13]; button.refusesFirstResponder = YES;
    [view addSubview:button]; return button;
}
- (NSButton *)keyButton:(NSString *)title chord:(NSString *)chord frame:(NSRect)frame in:(NSView *)view {
    NSButton *button = [self button:title frame:frame in:view action:@selector(key:)];
    button.identifier = chord; button.toolTip = chord;
    [self.inputControls addObject:button]; return button;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification; if (!self.session) self.session = [AnikeySession new];
    NSMenu *main = [NSMenu new]; NSMenuItem *appItem = [NSMenuItem new]; [main addItem:appItem];
    NSMenu *application = [[NSMenu alloc] initWithTitle:@"aniKey"];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit aniKey" action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp; [application addItem:quit]; appItem.submenu = application; NSApp.mainMenu = main;
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,620,550)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"aniKey — Bluetooth Keyboard & Mouse"; self.window.delegate = self; self.window.releasedWhenClosed = NO;
    self.window.contentMinSize = NSMakeSize(620,482);
    self.window.acceptsMouseMovedEvents = YES;
    NSView *root = self.window.contentView;
    self.devices = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(20,490,370,32) pullsDown:NO];
    self.devices.target = self; self.devices.action = @selector(selectDevice:); [root addSubview:self.devices];
    self.refreshButton = [self button:@"Refresh" frame:NSMakeRect(398,490,82,32) in:root action:@selector(refresh:)];
    self.connectionButton = [self button:@"Connect" frame:NSMakeRect(488,490,112,32) in:root action:@selector(connectionAction:)];
    self.status = [self label:@"Starting Bluetooth…" frame:NSMakeRect(20,434,480,44) in:root];
    NSButton *details = [self button:@"Details" frame:NSMakeRect(516,440,84,28) in:root action:@selector(showDetails:)];
    self.keyboardSurface = [[KeyboardSurface alloc] initWithFrame:NSMakeRect(20,340,580,80)]; self.keyboardSurface.owner = self;
    self.keyboardSurface.accessibilityElement = YES; self.keyboardSurface.accessibilityRole = NSAccessibilityGroupRole;
    self.keyboardSurface.accessibilityLabel = @"Type on your Mac keyboard"; [root addSubview:self.keyboardSurface];
    NSArray *keys = @[@"Enter",@"Tab",@"Backspace",@"Esc"];
    for (NSUInteger i = 0; i < keys.count; i++) [self keyButton:keys[i] chord:keys[i] frame:NSMakeRect(20+i*108,288,100,34) in:root];
    NSButton *paste = [self button:@"Type clipboard" frame:NSMakeRect(452,288,148,34) in:root action:@selector(pasteClipboard:)]; [self.inputControls addObject:paste];
    NSTextField *footer = [self label:@"Click the typing area to use your Mac keyboard.\nUS layout · ⌘⇧Esc returns focus to your Mac." frame:NSMakeRect(20,16,400,40) in:root];
    self.scrollSpeedPicker = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(432,22,168,28) pullsDown:NO];
    [self.scrollSpeedPicker addItemsWithTitles:@[@"Scroll: Extra slow",@"Scroll: Gentle",@"Scroll: Standard",@"Scroll: Fast"]];
    // Stable tags preserve existing saved choices when adding a slower preset.
    NSArray *speedTags = @[@3,@0,@1,@2];
    for (NSUInteger i = 0; i < speedTags.count; i++) [self.scrollSpeedPicker itemAtIndex:i].tag = [speedTags[i] integerValue];
    id savedSpeed = [NSUserDefaults.standardUserDefaults objectForKey:@"AnikeyScrollSpeed"];
    NSInteger speed = [savedSpeed isKindOfClass:NSNumber.class] ? [savedSpeed integerValue] : 3;
    if (![self.scrollSpeedPicker selectItemWithTag:speed]) [self.scrollSpeedPicker selectItemWithTag:3];
    self.scrollSpeedPicker.target = self; self.scrollSpeedPicker.action = @selector(changeScrollSpeed:);
    self.scrollSpeedPicker.accessibilityLabel = @"Two-finger scroll speed";
    self.scrollSpeedPicker.toolTip = @"Adjust two-finger vertical scrolling. Pointer movement and held-click dragging keep their speed.";
    self.scrollSpeedPicker.autoresizingMask = NSViewMinXMargin;
    [root addSubview:self.scrollSpeedPicker]; [self changeScrollSpeed:nil];
    self.cursorPad = [[CursorPad alloc] initWithFrame:NSMakeRect(110,68,400,172)]; self.cursorPad.owner = self;
    self.cursorPad.accessibilityElement = YES; self.cursorPad.accessibilityRole = NSAccessibilityGroupRole;
    self.cursorPad.accessibilityLabel = @"Phone mouse pad";
    self.cursorPad.toolTip = @"Move to point; click to select or open. Two fingers up/down scroll; adjust sensitivity with Scroll speed below. Hold and drag, or move two fingers sideways, to send a mouse drag. Android apps may select text or move items instead of swiping pages. Use Back, Home, and Recents for system navigation.";
    self.cursorPad.accessibilityHelp = self.cursorPad.toolTip;
    [root addSubview:self.cursorPad];
    [self label:@"Pad size" frame:NSMakeRect(20,252,72,20) in:root];
    self.padSizeSlider = [NSSlider sliderWithValue:0.2 minValue:0 maxValue:1 target:self action:@selector(resizePad:)];
    NSNumber *savedSize = [NSUserDefaults.standardUserDefaults objectForKey:@"AnikeyPadSize"];
    if ([savedSize isKindOfClass:NSNumber.class] && isfinite(savedSize.doubleValue)) self.padSizeSlider.doubleValue = MAX(0,MIN(1,savedSize.doubleValue));
    self.padSizeSlider.frame = NSMakeRect(92,252,146,20); self.padSizeSlider.continuous = YES;
    self.padSizeSlider.accessibilityLabel = @"Touchpad size"; self.padSizeSlider.toolTip = @"Adjust the pad area, or resize this window.";
    [root addSubview:self.padSizeSlider];
    NSArray *navigation = @[@"Back",@"Home",@"Recents"];
    for (NSUInteger i = 0; i < navigation.count; i++) {
        NSButton *button = [self button:navigation[i] frame:NSMakeRect(342+i*88,248,82,28) in:root action:@selector(padNavigation:)];
        button.tag = PadActionBack+i; button.autoresizingMask = NSViewMinXMargin|NSViewMinYMargin;
        [self.inputControls addObject:button];
    }
    for (NSView *view in root.subviews) if (NSMinY(view.frame) >= 248 && !view.autoresizingMask) view.autoresizingMask = NSViewMinYMargin;
    self.devices.autoresizingMask |= NSViewWidthSizable;
    self.refreshButton.autoresizingMask |= NSViewMinXMargin; self.connectionButton.autoresizingMask |= NSViewMinXMargin;
    self.status.autoresizingMask |= NSViewWidthSizable; details.autoresizingMask |= NSViewMinXMargin;
    self.keyboardSurface.autoresizingMask |= NSViewWidthSizable; paste.autoresizingMask |= NSViewMinXMargin;
    footer.autoresizingMask = NSViewWidthSizable;
    [self resizePad:nil];
    self.pointerTimer = [NSTimer timerWithTimeInterval:1.0/60 target:self selector:@selector(flushPointer:) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.pointerTimer forMode:NSRunLoopCommonModes];
    __weak AnikeyApp *weakSelf = self;

    self.eventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown|NSEventMaskKeyUp|NSEventMaskFlagsChanged handler:^NSEvent *(NSEvent *event) {
        AnikeyApp *app = weakSelf;
        if (!app || event.window != app.window || app.window.firstResponder != app.keyboardSurface || !app.window.isKeyWindow) return event;
        if (event.type == NSEventTypeKeyDown && event.keyCode == 0x35 && (event.modifierFlags & NSEventModifierFlagCommand) && (event.modifierFlags & NSEventModifierFlagShift)) { [app resetPointer]; [app.window makeFirstResponder:nil]; return nil; }
        if (![app canSendInput]) return event;
        if (event.type == NSEventTypeFlagsChanged) [app physicalFlags:event];
        else if (!event.isARepeat) [app physicalKey:event.keyCode down:event.type == NSEventTypeKeyDown flags:event.modifierFlags];
        return nil;
    }];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(update:) userInfo:nil repeats:YES];
    [self.window center]; [self.window makeKeyAndOrderFront:nil]; [self.window makeFirstResponder:self.keyboardSurface];
    [NSApp activateIgnoringOtherApps:YES]; [self refreshControls]; [self startBluetooth];
}
- (void)startBluetooth {
    if (self.terminating || self.bluetooth) return;
    if (!self.transport) self.transport = [TransportWorker new];
    self.paused = YES; // Manual connection: startup and timer polling never dial.
    BOOL closingPrevious = NO;
    for (NSRunningApplication *application in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"dev.anikey.local"]) {
        if (application.processIdentifier != getpid() && !application.terminated && [application.bundleURL.path.pathExtension isEqual:@"app"]) {
            [application terminate]; closingPrevious = YES;
        }
    }
    if (closingPrevious) {
        self.status.stringValue = @"Closing the previous aniKey session… This window stays responsive.";
        __weak AnikeyApp *owner = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{ [owner startBluetooth]; });
        return;
    }
    // Normal authorization/power only: no BLE advertising or HID service.
    self.bluetooth = [[CBCentralManager alloc] initWithDelegate:self queue:dispatch_get_main_queue() options:@{CBCentralManagerOptionShowPowerAlertKey:@YES}];
}
- (void)rememberSelection {
    if (self.selectedAddress) [NSUserDefaults.standardUserDefaults setObject:self.selectedAddress forKey:@"AnikeyPhone"];
}

- (void)refreshControls {
    BOOL enabled = [self canSendInput];
    for (NSButton *button in self.inputControls) {
        BOOL consumer = button.action == @selector(padNavigation:) && button.tag != PadActionRecentApps;
        button.enabled = enabled && (!consumer || self.session.protocolMode);
    }
    self.devices.enabled = !self.connectionPending && !self.refreshingDevices;
    self.refreshButton.enabled = self.bluetoothAvailable && !self.connectionPending && !self.refreshingDevices;
    self.connectionButton.title = self.connectionPending ? (self.paused ? @"Cancelling…" : @"Cancel") :
        ((!self.paused && self.session.ready) ? @"Disconnect" : @"Connect");
    self.connectionButton.enabled = self.connectionPending ? !self.paused :
        self.bluetoothAvailable && self.selectedAddress.length > 0 && !self.refreshingDevices;
    self.keyboardSurface.needsDisplay = YES; self.cursorPad.needsDisplay = YES;
    if (!enabled) [self resetPointer];
}
- (void)showDetails:(NSButton *)sender {
    NSViewController *controller = [NSViewController new]; controller.view = [[NSView alloc] initWithFrame:NSMakeRect(0,0,480,260)];
    NSString *details = [NSString stringWithFormat:@"%@\n%@\n%@",self.session.mouseValidated ? @"Mouse input available." : @"Connect to enable mouse input.",self.session.mouseDiagnostic ?: @"No mouse diagnostic has run.", self.session.lastError ?: [NSString stringWithFormat:@"%@ mode · Keyboard LEDs 0x%02X\nPairing alone is not a keyboard connection.",self.session.protocolMode ? @"Report" : @"Boot",self.session.LEDs]];
    [self label:details frame:NSMakeRect(16,16,448,228) in:controller.view];
    self.detailsPopover = [NSPopover new]; self.detailsPopover.contentViewController = controller; self.detailsPopover.behavior = NSPopoverBehaviorTransient;
    [self.detailsPopover showRelativeToRect:sender.bounds ofView:sender preferredEdge:NSRectEdgeMaxY];
}
- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    if (self.terminating) return;
    self.bluetoothAvailable = central.state == CBManagerStatePoweredOn;
    if (self.bluetoothAvailable) [self refresh:nil];
    else {
        self.paused = YES; self.connectionGeneration++; self.session.cancelRequested = YES;
        [self releaseInput]; [self onTransport:^(AnikeySession *session) { [session stop]; } completion:nil];
        self.status.stringValue = central.state == CBManagerStateUnauthorized ? @"Allow aniKey in Mac Bluetooth privacy settings, then reopen it." : @"Waiting for Bluetooth on your Mac…";
    }
    [self refreshControls];
}
- (void)onTransport:(void (^)(AnikeySession *))work completion:(dispatch_block_t)completion {
    AnikeySession *session = self.session;
    if (!self.transport) { work(session); if (completion) completion(); return; } // Recording tests.
    BOOL accepted = [self.transport perform:^{
        @try { work(session); }
        @catch (NSException *exception) {
            session.ready = NO;
            session.lastError = [NSString stringWithFormat:@"Bluetooth operation failed: %@",exception.reason ?: exception.name];
        }
        @finally { if (completion) dispatch_async(dispatch_get_main_queue(),completion); }
    }];
    if (!accepted && completion) completion();
}
- (void)enqueueInput:(void (^)(AnikeySession *))work completion:(dispatch_block_t)completion {
    NSUInteger generation = self.connectionGeneration, epoch = self.inputEpoch;
    [self onTransport:^(AnikeySession *session) {
        if (generation == self.connectionGeneration && epoch == (self.inputEpoch)
            && session.ready && !session.suspended) work(session);
    } completion:completion];
}
- (void)refresh:(id)sender {
    (void)sender; if (self.terminating || self.connectionPending || self.refreshingDevices || !self.bluetoothAvailable) return;
    NSString *preferred = self.selectedAddress ?: [NSUserDefaults.standardUserDefaults stringForKey:@"AnikeyPhone"];
    self.refreshingDevices = YES; [self refreshControls];
    __block NSArray<NSDictionary *> *entries;
    [self onTransport:^(AnikeySession *session) {
        (void)session; NSMutableArray *found = [NSMutableArray array]; NSMutableSet *addresses = [NSMutableSet set];
        for (IOBluetoothDevice *device in IOBluetoothDevice.pairedDevices) {
            NSString *address = NormalizeAddress(device.addressString);
            if (!address || [addresses containsObject:address]) continue;
            [addresses addObject:address];
            [found addObject:@{@"name":device.name ?: @"Unnamed Bluetooth device",@"address":address,
                              @"phone":@((device.classOfDevice & 0x1F00) == 0x0200)}];
        }
        entries = [found copy];
    } completion:^{
        self.refreshingDevices = NO; if (self.terminating) return;
        [self.devices removeAllItems]; [self.devices addItemWithTitle:@"Choose a device…"];
        NSMutableArray *phones = [NSMutableArray array];
        for (NSDictionary *entry in entries) {
            [self.devices addItemWithTitle:entry[@"name"]]; self.devices.lastItem.representedObject = entry[@"address"];
            if ([entry[@"phone"] boolValue]) [phones addObject:entry[@"address"]];
            if ([NormalizeAddress(preferred) isEqual:entry[@"address"]]) [self.devices selectItem:self.devices.lastItem];
        }
        if (!self.devices.selectedItem.representedObject && phones.count == 1)
            for (NSMenuItem *item in self.devices.itemArray) if ([item.representedObject isEqual:phones[0]]) [self.devices selectItem:item];
        self.selectedAddress = self.devices.selectedItem.representedObject;
        if (self.paused || !self.session.ready) self.status.stringValue = self.selectedAddress ? @"Paired device selected · Press Connect." : @"Choose your paired device, then press Connect.";
        [self refreshControls];
    }];
}
- (void)selectDevice:(id)sender {
    (void)sender; if (self.connectionPending) return;
    [self releaseInput]; self.connectionGeneration++; self.paused = YES; self.session.cancelRequested = YES;
    [self onTransport:^(AnikeySession *session) { [session stop]; } completion:nil];
    self.selectedAddress = self.devices.selectedItem.representedObject; [self rememberSelection];
    self.status.stringValue = @"Paired device selected · Press Connect."; [self refreshControls];
}
- (void)connectionAction:(id)sender {
    (void)sender;
    if (self.connectionPending || (!self.paused && self.session.ready)) {
        if (self.connectionPending && self.paused) return;
        self.paused = YES; self.connectionGeneration++; self.session.cancelRequested = YES;
        [self releaseInput]; [self onTransport:^(AnikeySession *session) { [session stop]; } completion:nil];
        self.wasReady = NO; self.status.stringValue = self.connectionPending ? @"Connection cancelled · Waiting for the Mac operation to finish." : @"Disconnected · Press Connect when ready.";
        [self refreshControls]; return;
    }
    if (!self.bluetoothAvailable || !self.selectedAddress || self.refreshingDevices || self.terminating) return;
    NSString *address = [self.selectedAddress copy]; NSUInteger generation = ++self.connectionGeneration;
    self.connectionPending = self.busy = YES; self.paused = NO; self.session.cancelRequested = NO;
    self.status.stringValue = @"Connecting input… You can cancel this attempt."; [self refreshControls];
    __block BOOL success = NO; __block NSString *error;
    [self onTransport:^(AnikeySession *session) {
        if (generation != self.connectionGeneration) return;
        success = [session connect:address]; error = [session.lastError copy];
        if (generation != self.connectionGeneration || !success) [session stop];
    } completion:^{
        self.connectionPending = self.busy = NO; if (self.terminating) return;
        if (generation != self.connectionGeneration) { [self refreshControls]; return; }
        if (success) {
            self.wasReady = YES; [self rememberSelection]; self.status.stringValue = @"Input connected";
            [self.window makeFirstResponder:self.keyboardSurface];
        } else {
            self.paused = YES; self.wasReady = NO; self.status.stringValue = ConnectionFailureStatus(error ?: self.session.lastError);
            self.status.toolTip = error ?: self.session.lastError;
        }
        [self refreshControls];
    }];
}
- (void)update:(NSTimer *)timer {
    (void)timer;
    if (Interrupted) { [NSApp terminate:nil]; return; }
    [self refreshControls]; if (self.connectionPending || self.busy || self.paused) return;
    if (self.wasReady && !self.session.ready) {
        self.wasReady = NO; self.paused = YES; [self releaseInput];
        self.status.stringValue = ConnectionFailureStatus(self.session.lastError);
        [self onTransport:^(AnikeySession *session) { [session stop]; } completion:nil]; [self refreshControls]; return;
    }
    self.wasReady = self.session.ready;
    if (self.session.ready) {
        self.status.stringValue = self.session.suspended ? @"Device suspended input · Waiting to resume." : @"Input connected";
        self.status.toolTip = self.session.lastError;
    }
}

- (void)releaseInput {
    [self resetPointer];
    self.inputEpoch++; NSUInteger generation = self.connectionGeneration;
    [self.heldKeys removeAllObjects];
    [self onTransport:^(AnikeySession *session) {
        if (generation == self.connectionGeneration && session.ready && !session.suspended) {
            [session sendReport:1 payload:KeyboardReport(0,@[])];
            if (((const uint8_t *)session.mouse.bytes)[0]) [session sendReport:10 payload:MouseReport(0,0,0)];
        }
    } completion:nil];
}
- (void)resetPointer {
    BOOL held = self.pointerButtons || (self.session.mouse.length && ((const uint8_t *)self.session.mouse.bytes)[0]);
    self.pointerEpoch++; self.pointerButtons = 0; [self.motion reset]; [self.cursorPad reset];
    if (!held) return;
    NSUInteger generation = self.connectionGeneration;
    // A release must survive motion cancellation, including a press currently
    // blocked inside writeSync. The worker evaluates actual button state later.
    [self onTransport:^(AnikeySession *session) {
        if (generation == self.connectionGeneration && session.ready && !session.suspended && ((const uint8_t *)session.mouse.bytes)[0])
            [session sendReport:10 payload:MouseReport(0,0,0)];
    } completion:nil];
}
- (void)flushPointer:(NSTimer *)timer {
    (void)timer; if (!self.session.mouseValidated) { [self.motion reset]; return; }
    if (![self canSendInput]) { [self resetPointer]; return; }
    if (self.pointerBusy) return;
    NSMutableData *report = [[self.motion takeReport] mutableCopy]; if (!report) return;
    ((uint8_t *)report.mutableBytes)[0] = self.pointerButtons;
    self.pointerBusy = YES; NSUInteger epoch = self.pointerEpoch;
    [self enqueueInput:^(AnikeySession *session) {
        if (epoch == self.pointerEpoch) [session sendReport:10 payload:report];
    } completion:^{
        self.pointerBusy = NO;
        // Coalesce input received during writeSync, then drain it immediately.
        // There is still at most one motion write queued/in flight.
        if (!self.terminating && [self canSendInput]) [self flushPointer:nil];
    }];
}
- (NSArray<NSData *> *)takePointerReports:(uint8_t)buttons {
    NSMutableArray *reports = [NSMutableArray array]; NSData *report;
    while ((report = [self.motion takeReport])) {
        NSMutableData *packet = [report mutableCopy]; ((uint8_t *)packet.mutableBytes)[0] = buttons;
        [reports addObject:packet];
    }
    return reports;
}
- (void)endPointerScroll {
    // Finishing is not cancellation: preserve the accepted wheel report and
    // one bounded final packet, even when a fast flick ends before writeSync.
    // Drop fractions and excess backlog so there is no long tail after lift.
    self.motion.x = self.motion.y = 0;
    self.motion.wheel = trunc(MAX(-8,MIN(8,self.motion.wheel)));
    [self flushPointer:nil];
}
- (void)beginPointerDrag {
    if (![self canSendInput] || !self.session.mouseValidated || self.pointerButtons) return;
    NSArray *movement = [self takePointerReports:0]; self.pointerButtons = 1;
    NSUInteger epoch = self.pointerEpoch;
    [self enqueueInput:^(AnikeySession *session) {
        for (NSData *report in movement) {
            if (epoch != self.pointerEpoch || ![session sendReport:10 payload:report]) return;
        }
        if (epoch == self.pointerEpoch) [session sendReport:10 payload:MouseReport(1,0,0)];
    } completion:nil];
}
- (void)endPointerDrag {
    if (!self.pointerButtons) return;
    self.pointerButtons = 0; NSArray *movement = [self takePointerReports:1];
    NSUInteger epoch = self.pointerEpoch, generation = self.connectionGeneration;
    [self onTransport:^(AnikeySession *session) {
        if (generation != self.connectionGeneration || !session.ready || session.suspended) return;
        for (NSData *report in movement) {
            if (epoch != self.pointerEpoch || ![session sendReport:10 payload:report]) break;
        }
        if (session.ready && ((const uint8_t *)session.mouse.bytes)[0]) [session sendReport:10 payload:MouseReport(0,0,0)];
    } completion:nil];
}
- (void)sendNavigationUsage:(uint16_t)usage {
    if (usage == 0x0224) [self performPadAction:PadActionBack];
    else if (usage == 0x0223) [self performPadAction:PadActionHome];
}
- (void)padNavigation:(NSButton *)sender { [self performPadAction:(PadAction)sender.tag]; }
- (void)performPadAction:(PadAction)action {
    if (![self canSendInput] || action < PadActionBack || action > PadActionRecentApps) return;
    if (action != PadActionRecentApps && !self.session.protocolMode) {
        self.cursorPad.gestureFeedback = @"Navigation needs report mode"; self.cursorPad.needsDisplay = YES; return;
    }
    [self resetPointer];
    self.cursorPad.gestureFeedback = action == PadActionBack ? @"Back" : action == PadActionHome ? @"Home" : @"Recent apps";
    self.cursorPad.needsDisplay = YES;
    if (action == PadActionRecentApps) [self.heldKeys removeAllObjects];
    NSUInteger generation = self.connectionGeneration, epoch = self.inputEpoch;
    __block NSString *failure = nil;
    [self enqueueInput:^(AnikeySession *session) {
        if (generation != self.connectionGeneration || epoch != self.inputEpoch) return;
        BOOL success;
        if (action == PadActionRecentApps) {
            success = [session openRecentApps];
        } else success = [session sendNavigationUsage:action == PadActionBack ? 0x0224 : 0x0223];
        if (!success) failure = [session.lastError copy];
    } completion:^{
        if (failure && generation == self.connectionGeneration) { self.status.stringValue = failure; self.status.toolTip = failure; }
    }];
}
- (void)sendPointerButton:(uint8_t)button {
    if (!self.session.mouseValidated || ![self canSendInput] || self.pointerButtons || (button != 1 && button != 2)) return;
    // Finish movement already requested at click time before sending the click.
    // PointerMotion is bounded, so this snapshot contains at most five packets.
    NSArray<NSData *> *movement = [self takePointerReports:0];
    NSUInteger epoch = self.pointerEpoch;
    [self enqueueInput:^(AnikeySession *session) {
        for (NSData *motion in movement) {
            if (epoch != self.pointerEpoch || ![session sendReport:10 payload:motion]) return;
        }
        if (epoch != self.pointerEpoch) return;
        if ([session sendReport:10 payload:MouseReport(button,0,0)]) {
            Pump(0.02);
            [session sendReport:10 payload:MouseReport(0,0,0)];
        }
    } completion:nil];
}
- (void)physicalKey:(unsigned short)code down:(BOOL)down flags:(NSEventModifierFlags)flags {
    if (![self canSendInput]) return;
    uint8_t usage = PhysicalUsage(code); if (!usage) return;
    if (down) [self.heldKeys addObject:@(usage)]; else [self.heldKeys removeObject:@(usage)];
    NSData *report = KeyboardReport(PhysicalModifiers(flags),self.heldKeys.array);
    [self enqueueInput:^(AnikeySession *session) { [session sendReport:1 payload:report]; } completion:nil];
}
- (void)physicalFlags:(NSEvent *)event {
    if (![self canSendInput]) return;
    if (event.keyCode == 0x39) {
        BOOL caps = (event.modifierFlags & NSEventModifierFlagCapsLock) != 0;
        if (caps != self.capsState) {
            self.capsState = caps;
            [self enqueueInput:^(AnikeySession *session) { [session tap:(Key){0x39,0}]; } completion:nil];
        }
    } else {
        NSData *report = KeyboardReport(PhysicalModifiers(event.modifierFlags),self.heldKeys.array);
        [self enqueueInput:^(AnikeySession *session) { [session sendReport:1 payload:report]; } completion:nil];
    }
}
- (void)key:(NSButton *)sender {
    if (![self canSendInput]) return;
    Key key = {0}; NSString *error = nil;
    if (!ParseChord(sender.identifier ?: sender.title,&key,&error)) { self.status.stringValue = error; return; }
    // A button tap is queued, not an exclusive typing operation. Changing the
    // input epoch here would discard earlier clicks still waiting on the worker.
    [self.heldKeys removeAllObjects];
    NSUInteger generation = self.connectionGeneration, epoch = self.inputEpoch;
    __block NSString *failure = nil;
    [self enqueueInput:^(AnikeySession *session) {
        if (![session sendReport:1 payload:KeyboardReport(0,@[])] || ![session tap:key waitAfterRelease:NO])
            failure = [session.lastError copy];
    } completion:^{
        if (generation == self.connectionGeneration && epoch == self.inputEpoch && !self.paused) {
            if (failure) { self.status.stringValue = failure; self.status.toolTip = failure; }
            else [self.window makeFirstResponder:self.keyboardSurface];
        }
        [self refreshControls];
    }];
}
- (void)pasteClipboard:(id)sender {
    (void)sender; if (![self canSendInput]) return;
    NSString *text = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString]; if (!text.length) return;
    NSString *error = nil; if (!ValidateText(text,&error)) { self.status.stringValue = error; return; }
    self.busy = YES; [self releaseInput]; NSUInteger generation = self.connectionGeneration, epoch = self.inputEpoch;
    [self enqueueInput:^(AnikeySession *session) {
        for (NSUInteger i = 0; i < text.length; i++) {
            if (generation != self.connectionGeneration || epoch != self.inputEpoch || session.cancelRequested || !session.ready) break;
            Key key = {0}; ASCIIKey([text characterAtIndex:i],&key);
            if (![session tap:key]) break;
        }
    } completion:^{
        if (generation == self.connectionGeneration && !self.connectionPending) self.busy = NO;
        if (generation == self.connectionGeneration && epoch == self.inputEpoch && !self.paused) [self.window makeFirstResponder:self.keyboardSurface];
        [self refreshControls];
    }];
}
- (void)windowDidResignKey:(NSNotification *)notification { (void)notification; [self releaseInput]; self.keyboardSurface.needsDisplay = YES; }
- (void)windowDidBecomeKey:(NSNotification *)notification { (void)notification; self.keyboardSurface.needsDisplay = YES; }
- (void)applicationDidResignActive:(NSNotification *)notification { (void)notification; [self releaseInput]; }
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { (void)app; return YES; }
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app {
    if (self.terminating) return NSTerminateLater;
    self.terminating = YES; self.paused = YES; self.connectionGeneration++; self.session.cancelRequested = YES;
    [self.pointerTimer invalidate]; [self.timer invalidate]; if (self.eventMonitor) { [NSEvent removeMonitor:self.eventMonitor]; self.eventMonitor = nil; } [self releaseInput];
    if (!self.transport) { [self.session stop]; return NSTerminateNow; }
    [self.window orderOut:nil];
    dispatch_block_t reply = ^{
        if (!self.terminationReplySent) { self.terminationReplySent = YES; [app replyToApplicationShouldTerminate:YES]; }
    };
    [self onTransport:^(AnikeySession *session) {
        @try { [session stop]; } @finally { [self.transport finish]; }
    } completion:reply];
    // A stuck OS call cannot prevent Quit. Transient services/channels also close
    // on process exit; the Bluetooth bond belongs to macOS and is never removed.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),reply);
    return NSTerminateLater;
}
- (BOOL)windowShouldClose:(NSWindow *)window { (void)window; return YES; }
@end

#ifndef ANIKEY_TEST
static void Usage(void) {
    puts("aniKey — macOS Classic Bluetooth HID keyboard for Android\n"
         "Usage: anikey [--device ADDRESS] [--dry-run] [--delay-ms 0..2000] COMMAND\n"
         "       anikey --gui\n"
         "       anikey --help | --version\n"
         "Commands:\n"
         "  mouse-test ACTION     One diagnostic step/click; mouse remains unavailable\n"
         "  list                  List paired devices\n"
         "  check                 Open HID channels, then close; sends no keypresses\n"
         "  pin DIGITS            Type digits, then Enter (one attempt)\n"
         "  text 'TEXT'           Type US-layout ASCII\n"
         "  key ctrl+a            Tap one key/chord (F1–F12, navigation, modifiers)\n"
         "Dry-run prints HIDP packets and never accesses Bluetooth. Options precede COMMAND.\n"
         "Exit codes: 0 success, 1 transport/input failure, 2 invalid arguments.");
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        signal(SIGINT, InterruptHandler); signal(SIGTERM, InterruptHandler);
        AnikeySession *session = [AnikeySession new];
        NSString *address = nil; BOOL gui = NO; int index = 1;
        while (index < argc && strncmp(argv[index],"--",2) == 0) {
            NSString *option = @(argv[index++]);
            if ([option isEqual:@"--help"]) { Usage(); return 0; }
            if ([option isEqual:@"--version"]) {
                NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
                if (!version.length) { fprintf(stderr,"Missing version metadata; build with the embedded Info.plist.\n"); return 1; }
                printf("aniKey %s\n",version.UTF8String); return 0;
            }
            if ([option isEqual:@"--dry-run"]) { session.dryRun = YES; session.trace = YES; }
            else if ([option isEqual:@"--gui"]) gui = YES;
            else if ([option isEqual:@"--device"] || [option isEqual:@"--delay-ms"]) {
                if (index == argc) { fprintf(stderr,"Missing value for %s\n",option.UTF8String); return 2; }
                NSString *value = @(argv[index++]);
                if ([option isEqual:@"--device"]) {
                    address = NormalizeAddress(value);
                    if (!address) { fprintf(stderr,"Invalid Bluetooth address.\n"); return 2; }
                } else {
                    NSInteger delay;
                    if (!ParseInteger(value,0,2000,&delay)) { fprintf(stderr,"--delay-ms requires an integer in 0..2000.\n"); return 2; }
                    session.keyDelayMS = delay;
                }
            } else { fprintf(stderr,"Unknown option: %s\n",option.UTF8String); return 2; }
        }
        // Finder passes no arguments; make the app useful when opened normally.
        BOOL bundleLaunch = argc == 1 && [NSBundle.mainBundle.bundlePath.pathExtension isEqual:@"app"];
        if (gui || bundleLaunch) {
            if (index != argc || session.dryRun || address) { fprintf(stderr,"--gui accepts only --delay-ms; select the device in the window.\n"); return 2; }
            [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
            AnikeyApp *delegate = [AnikeyApp new]; delegate.session = session; NSApp.delegate = delegate;
            [NSApp run]; return 0;
        }
        NSMutableArray<NSString *> *args = [NSMutableArray array];
        for (; index < argc; index++) [args addObject:@(argv[index])];
        NSString *error = nil;
        if (!ValidateCommand(args,&error)) { fprintf(stderr,"%s\n",error.UTF8String); return 2; }
        if ([args[0] isEqual:@"list"]) {
            if (session.dryRun) { fprintf(stderr,"list cannot be used with --dry-run.\n"); return 2; }
            NSArray *devices = IOBluetoothDevice.pairedDevices;
            for (IOBluetoothDevice *device in devices) printf("%s\t%s\n", device.addressString.UTF8String, (device.name ?: @"Unnamed device").UTF8String);
            if (!devices.count) fprintf(stderr,"No paired devices found. Check Bluetooth settings and permission.\n");
            return 0;
        }
        if (!session.dryRun && !address) { fprintf(stderr,"--device ADDRESS is required unless --dry-run is set.\n"); return 2; }
        if (![session connect:address]) { fprintf(stderr,"%s\n",session.lastError.UTF8String); [session stop]; return 1; }
        BOOL success = ExecuteCommand(session,args);
        if (success && [args[0] isEqual:@"check"]) puts(session.dryRun ? "DRY RUN: check skipped; no Bluetooth accessed." : "HID control and interrupt channels opened. No keys sent.");
        Pump(0.1); [session stop];
        if (session.lastError) success = NO;
        if (!success) fprintf(stderr,"%s\n",(session.lastError ?: @"Command failed.").UTF8String);
        return success ? 0 : 1;
    }
}
#endif
