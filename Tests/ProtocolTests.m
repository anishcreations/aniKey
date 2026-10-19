// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Anish Aryal

#define ANIKEY_TEST 1
#import "../Sources/Anikey.m"

static unsigned Checks = 0;
static void Check(BOOL condition, NSString *message) {
    Checks++;
    if (!condition) { fprintf(stderr,"FAIL: %s\n",message.UTF8String); exit(1); }
}
static NSData *ParseHex(NSString *hex) {
    NSMutableData *data = [NSMutableData data];
    for (NSString *part in [hex componentsSeparatedByString:@" "]) {
        unsigned value = 0; [[NSScanner scannerWithString:part] scanHexInt:&value];
        uint8_t byte = (uint8_t)value; [data appendBytes:&byte length:1];
    }
    return data;
}
@interface TestSession : AnikeySession
@property (strong) NSMutableArray<NSDictionary *> *packets;
@property NSInteger failAt;
@property NSUInteger connectCount;
@property BOOL connectFailure;
@end
@interface SlowTestSession : TestSession
@property BOOL enteredConnect, connectOnMain;
@property NSTimeInterval blockDuration;
@end
@implementation SlowTestSession
- (BOOL)connect:(NSString *)address {
    self.enteredConnect = YES; self.connectOnMain = NSThread.isMainThread;
    Pump(self.blockDuration > 0 ? self.blockDuration : 0.35); // Uninterruptible SDK call, including nested run-loop pumping.
    return [super connect:address];
}
@end
@interface SlowWriteSession : TestSession
@property BOOL enteredWrite, writeOnMain;
@end
@implementation SlowWriteSession
- (BOOL)writePacket:(NSData *)packet control:(BOOL)control {
    self.writeOnMain |= NSThread.isMainThread;
    if (!self.enteredWrite) { self.enteredWrite = YES; Pump(0.15); }
    return [super writePacket:packet control:control];
}
@end
@interface TerminationReplySpy : NSObject
@property NSUInteger replies;
@property BOOL allowed;
- (void)replyToApplicationShouldTerminate:(BOOL)allowed;
@end
@implementation TerminationReplySpy
- (void)replyToApplicationShouldTerminate:(BOOL)allowed { self.replies++; self.allowed = allowed; }
@end
@implementation TestSession
- (instancetype)init {
    if ((self = [super init])) { self.ready = YES; self.dryRun = YES; self.mouseValidated = YES; self.keyDelayMS = 0; self.packets = [NSMutableArray array]; self.failAt = -1; }
    return self;
}
- (BOOL)writePacket:(NSData *)packet control:(BOOL)control {
    if ((NSInteger)self.packets.count == self.failAt) { self.ready = NO; self.lastError = @"Simulated write failure"; return NO; }
    [self.packets addObject:@{@"control": @(control), @"data":packet}]; return YES;
}
- (BOOL)connect:(NSString *)address {
    (void)address; self.connectCount++;
    if (self.connectFailure) { self.lastError = @"Simulated connection failure"; self.ready = NO; return NO; }
    self.ready = YES; self.lastError = nil; return YES;
}
@end
@interface ServiceRemovalSpy : NSObject
@property NSUInteger removals;
- (IOReturn)removeServiceRecord;
@end
@implementation ServiceRemovalSpy
- (IOReturn)removeServiceRecord { self.removals++; return kIOReturnSuccess; }
@end
@interface MockChannel : NSObject
@property BluetoothL2CAPPSM PSM;
@property BluetoothL2CAPChannelID localChannelID, remoteChannelID;
@property (strong) IOBluetoothDevice *device;
@property (strong) id retainedDelegate;
@property NSUInteger closes, delegateRegistrations;
@property BOOL completeOnDelegate;
@property IOReturn delegateStatus, openStatus;
- (IOReturn)setDelegate:(id)delegate;
- (IOReturn)closeChannel;
@end
@implementation MockChannel
- (instancetype)init { if ((self = [super init])) { _localChannelID = 0x40; _remoteChannelID = 0x41; } return self; }
- (IOReturn)setDelegate:(id)delegate {
    self.retainedDelegate = delegate;
    if (delegate) {
        self.delegateRegistrations++;
        if (self.completeOnDelegate && self.delegateStatus == kIOReturnSuccess)
            [delegate l2capChannelOpenComplete:(IOBluetoothL2CAPChannel *)self status:self.openStatus];
    }
    return self.delegateStatus;
}
- (IOReturn)closeChannel { self.closes++; return kIOReturnSuccess; }
@end
@interface MockOpenDevice : NSObject
@property (strong) MockChannel *channel;
@property IOReturn result;
@property BOOL earlyData, earlyCompletion, omitChannel;
@property BluetoothL2CAPPSM returnedPSM;
- (IOReturn)openL2CAPChannelAsync:(IOBluetoothL2CAPChannel **)channel withPSM:(BluetoothL2CAPPSM)psm delegate:(AnikeySession *)delegate;
@end
@implementation MockOpenDevice
- (IOReturn)openL2CAPChannelAsync:(IOBluetoothL2CAPChannel **)channel withPSM:(BluetoothL2CAPPSM)psm delegate:(AnikeySession *)delegate {
    self.channel.completeOnDelegate = YES;
    self.channel.PSM = self.returnedPSM ?: psm; self.channel.device = (IOBluetoothDevice *)self;
    self.channel.retainedDelegate = delegate;
    if (self.earlyCompletion) [delegate l2capChannelOpenComplete:(IOBluetoothL2CAPChannel *)self.channel status:kIOReturnSuccess];
    if (self.earlyData) {
        uint8_t getProtocol[] = {0x60};
        [delegate l2capChannelData:(IOBluetoothL2CAPChannel *)self.channel data:getProtocol length:1];
    }
    *channel = self.omitChannel ? nil : (IOBluetoothL2CAPChannel *)self.channel;
    return self.result;
}
@end
static void Expect(TestSession *session, NSUInteger index, BOOL control, NSString *hex) {
    Check(index < session.packets.count, @"Expected packet exists");
    NSDictionary *packet = session.packets[index];
    Check([packet[@"control"] boolValue] == control, @"Packet uses correct channel");
    Check([packet[@"data"] isEqual:ParseHex(hex)], [NSString stringWithFormat:@"Packet expected %@, got %@", hex, Hex(packet[@"data"])]);
}

static void DescriptorTests(void) {
    // Parse HID short items independently of the encoder; check bit totals and fields.
    const uint8_t *p = ReportDescriptor().bytes;
    NSUInteger length = ReportDescriptor().length, index = 0;
    unsigned reportID = 0, size = 0, count = 0, depth = 0, usagePage = 0;
    unsigned bits[11][3] = {{0}}; // report ID × Input/Output/Feature
    BOOL keyboardArray = NO, modifierBits = NO, ledBits = NO, relativeMouse = NO;
    while (index < length) {
        uint8_t header = p[index++];
        Check(header != 0xFE, @"Descriptor uses short items");
        unsigned n = header & 3; if (n == 3) n = 4;
        Check(index+n <= length, @"Descriptor item fits");
        uint32_t value = 0;
        for (unsigned j = 0; j < n; j++) value |= (uint32_t)p[index+j] << (8*j);
        index += n;
        unsigned type = (header >> 2) & 3, tag = header >> 4;
        if (type == 1) {
            if (tag == 0) usagePage = value;
            if (tag == 7) size = value;
            if (tag == 8) { reportID = value; Check(reportID == 1 || reportID == 2 || reportID == 10,@"Keyboard, navigation and mouse report IDs are separate"); }
            if (tag == 9) count = value;
        } else if (type == 2 && tag == 0 && usagePage == 12) {
            Check(value == 1 || value == 0x0224 || value == 0x0223,@"Consumer collection exposes only Back and Home usages");
        } else if (type == 0) {
            if (tag == 10) depth++;
            else if (tag == 12) { Check(depth > 0,@"Collection end is balanced"); depth--; }
            else if (tag == 8 || tag == 9 || tag == 11) {
                Check(reportID == 1 || reportID == 2 || reportID == 10, @"Main item has a report ID");
                unsigned direction = tag == 8 ? 0 : tag == 9 ? 1 : 2;
                bits[reportID][direction] += size*count;
                if (reportID == 1 && direction == 0 && size == 8 && count == 6 && value == 0 && usagePage == 7) keyboardArray = YES;
                if (reportID == 1 && direction == 0 && size == 1 && count == 8 && value == 2) modifierBits = YES;
                if (reportID == 1 && direction == 1 && size == 1 && count == 5 && usagePage == 8) ledBits = YES;
                if (reportID == 10 && direction == 0 && size == 8 && count == 4 && value == 6 && usagePage == 1) relativeMouse = YES;
            }
        }
    }
    Check(depth == 0,@"All collections close");
    Check(bits[1][0] == 64 && bits[1][1] == 8 && bits[10][0] == 40 && bits[2][0] == 16,@"Keyboard, mouse, navigation and LEDs have the expected report sizes");
    Check(keyboardArray && modifierBits && ledBits,@"Descriptor defines keyboard modifiers, usages and LEDs");
    Check(relativeMouse,@"Mouse axes are explicitly relative, not absolute or consumer usages");
    TestSession *session = [TestSession new];
    Check(![session sendReport:10 payload:ParseHex(@"00 00 00 00")] && ![session sendReport:3 payload:ParseHex(@"00 00")] && !session.packets.count,@"Mouse rejects malformed lengths and unadvertised report IDs");
    NSDictionary *dictionary = ServiceDictionary();
    NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
    for (NSString *attribute in dictionary) {
        if ([attribute isEqual:@"LocalAttributes"]) continue;
        IOBluetoothSDPDataElement *element = [IOBluetoothSDPDataElement withElementValue:dictionary[attribute]];
        Check(element != nil, [@"SDK parses SDP attribute " stringByAppendingString:attribute]);
        unsigned attributeID = 0; [[NSScanner scannerWithString:attribute] scanHexInt:&attributeID];
        attributes[@(attributeID)] = element;
    }
    // Unlike publishing, this constructor expects numeric IDs and parsed elements.
    IOBluetoothSDPServiceRecord *record = [IOBluetoothSDPServiceRecord withServiceDictionary:attributes device:nil];
    Check(record != nil,@"SDK parses local SDP record without publishing it");
    Check([[[record getAttributeDataElement:0x0202] getNumberValue] unsignedIntValue] == 0xC0,@"SDP identifies a keyboard and mouse");
    BluetoothL2CAPPSM psm = 0;
    IOReturn parsed = [record getL2CAPPSM:&psm];
    Check(parsed == kIOReturnSuccess && psm == 0x11,[NSString stringWithFormat:@"SDP advertises control PSM 0x11 (status=0x%08X, psm=%u, attribute=%@)",(unsigned)parsed,psm,[record getAttributeDataElement:4]]);
    NSArray *additional = [[record getAttributeDataElement:0x000D] getArrayValue];
    NSArray *protocols = [additional[0] getArrayValue];
    NSArray *l2cap = [protocols[0] getArrayValue];
    Check([[l2cap[1] getNumberValue] intValue] == 0x13,@"SDP advertises interrupt PSM 0x13");
    NSArray *descriptors = [[record getAttributeDataElement:0x0206] getArrayValue];
    NSArray *entry = [descriptors[0] getArrayValue];
    Check([[entry[0] getNumberValue] intValue] == 0x22,@"SDP uses report descriptor type 0x22");
    Check([[(IOBluetoothSDPDataElement *)entry[1] getValue] isEqual:ReportDescriptor()],@"SDP preserves binary descriptor bytes as a text-string element");
    Check(ServiceHasExpectedDescriptor(record),@"Publication guard accepts the exact advertised layout");
    Check(ServiceValidationError(record) == nil,@"Full local SDP validation accepts correct endpoints and descriptor");
    NSDictionary *original = [attributes copy];
    attributes[@4] = [IOBluetoothSDPDataElement withElementValue:@[@[SDPUUID(0x0100),SDPNumber(0x1001,2)],@[SDPUUID(0x0011)]]];
    record = [IOBluetoothSDPServiceRecord withServiceDictionary:attributes device:nil];
    Check([ServiceValidationError(record) containsString:@"control PSM"],@"Remapped control PSM is rejected");
    [attributes setDictionary:original];
    attributes[@0x000D] = [IOBluetoothSDPDataElement withElementValue:@[@[@[SDPUUID(0x0100),SDPNumber(0x1003,2)],@[SDPUUID(0x0011)]]]];
    record = [IOBluetoothSDPServiceRecord withServiceDictionary:attributes device:nil];
    Check([ServiceValidationError(record) containsString:@"interrupt PSM"],@"Remapped interrupt PSM is rejected");
    [attributes removeObjectForKey:@0x000D];
    record = [IOBluetoothSDPServiceRecord withServiceDictionary:attributes device:nil];
    Check([ServiceValidationError(record) containsString:@"malformed"],@"Missing interrupt endpoint is rejected");
    [attributes setDictionary:original];
    attributes[@0x000D] = [IOBluetoothSDPDataElement withElementValue:@[@[@[SDPUUID(0x0100),SDPNumber(0x13,2)],@[SDPUUID(0x9999)]]]];
    record = [IOBluetoothSDPServiceRecord withServiceDictionary:attributes device:nil];
    Check([ServiceValidationError(record) containsString:@"malformed"],@"Wrong interrupt protocol UUID is rejected");
    [attributes setDictionary:original];
    attributes[@0x0206] = [IOBluetoothSDPDataElement withElementValue:@[@[SDPNumber(0x22,1),@{@"DataElementType":@4,@"DataElementValue":ParseHex(@"05 0C") }]]];
    record = [IOBluetoothSDPServiceRecord withServiceDictionary:attributes device:nil];
    Check(!ServiceHasExpectedDescriptor(record),@"Publication guard rejects a different consumer-only layout");
    Check([ServiceValidationError(record) containsString:@"descriptor mismatch"],@"Descriptor mismatch blocks the transport");
    Check(!ServiceHasExpectedDescriptor(nil),@"Publication guard rejects a missing record");
}

static void MouseTests(void) {
    AnikeySession *blocked = [AnikeySession new]; blocked.ready = YES; blocked.dryRun = YES;
    Check(!blocked.mouseValidated && ![blocked sendReport:10 payload:MouseReport(0,1,0)],@"Production mouse output is blocked by default");
    Check([blocked.mouseDiagnostic containsString:@"blocked"] && [blocked.mouseDiagnostic containsString:@"PSM=0x0013"],@"Blocked mouse diagnostic names the endpoint without keyboard content");
    blocked.lastError = nil;
    Check([blocked tap:(Key){4,0}],@"Keyboard remains available while mouse is blocked");
    TestSession *probe = [TestSession new]; probe.mouseValidated = NO;
    Check([probe probeMouse:@"right"],@"An explicit diagnostic can send one bounded movement step");
    Expect(probe,0,NO,@"A1 0A 00 01 00 00 00");
    Check(!probe.mouseProbeRemaining && !probe.mouseValidated,@"Probe cannot leave continuous mouse input enabled");
    Check(![probe sendReport:10 payload:MouseReport(0,50,0)] && probe.packets.count == 1,@"Further movement is blocked after probe budget expires");
    probe.lastError = nil; [probe.packets removeAllObjects];
    Check([probe probeMouse:@"left-click"],@"Explicit click test sends only a press and release");
    Expect(probe,0,NO,@"A1 0A 01 00 00 00 00"); Expect(probe,1,NO,@"A1 0A 00 00 00 00 00");
    NSString *diagnostic = probe.mouseDiagnostic;
    Check([diagnostic containsString:@"report=10"] && [diagnostic containsString:@"payload=5"] && [diagnostic containsString:@"wire=7"] && [diagnostic containsString:@"mode=report"] && [diagnostic containsString:@"channel=interrupt"],@"Mouse diagnostic includes framing, protocol and channel");
    [probe tap:(Key){0x04,0}]; Check([probe.mouseDiagnostic isEqual:diagnostic],@"Keyboard input never enters mouse diagnostics");
    Check(![probe sendReport:2 payload:MouseReport(0,1,0)],@"Report-mode mouse can never be transmitted as consumer report ID 2");
    probe.mouseValidated = YES;
    for (NSString *invalid in @[@"04 00 00 00 00",@"00 80 00 00 00",@"00 00 00 01 00",@"00 00 00 00 80"])
        Check(![probe sendReport:10 payload:ParseHex(invalid)],@"Invalid buttons, reserved Z and out-of-range axes/wheel are rejected");
    PointerMotion *motion = [PointerMotion new];
    [motion addX:0.4 y:-0.4]; Check(![motion takeReport],@"Fractional points are accumulated");
    [motion addX:0.8 y:-0.8]; Check([[motion takeReport] isEqual:ParseHex(@"00 01 FF 00 00")],@"Signed movement preserves subpixel remainder");
    [motion reset]; [motion addX:300 y:-260];
    Check([[motion takeReport] isEqual:ParseHex(@"00 7F 81 00 00")],@"Large movement splits into legal signed deltas");
    Check([[motion takeReport] isEqual:ParseHex(@"00 7F 81 00 00")],@"Large movement is not wrapped");
    Check([[motion takeReport] isEqual:ParseHex(@"00 2E FA 00 00")] && ![motion takeReport],@"Remaining motion is preserved exactly");
    [motion addX:NAN y:INFINITY]; Check(![motion takeReport],@"Invalid motion is ignored");
    [motion addX:100000 y:-100000]; Check(motion.x == 512 && motion.y == -512,@"Pending motion is bounded");
    [motion reset]; Check(![motion takeReport],@"Reset discards pending motion");
    [motion addWheel:0.4]; Check(![motion takeReport],@"Small scroll deltas retain fractions");
    [motion addWheel:1.8]; Check([[motion takeReport] isEqual:ParseHex(@"00 00 00 00 02")],@"Scrolling sets only the wheel byte");
    [motion reset]; [motion addWheel:-1000];
    Check(motion.wheel == -32 && [[motion takeReport] isEqual:ParseHex(@"00 00 00 00 F8")],@"Scroll backlog and packet size are bounded");
    [motion reset]; Check(![motion takeReport],@"Cancellation discards pending scrolling");
    TestSession *session = [TestSession new];
    Check([session sendReport:10 payload:MouseReport(0,-127,127)],@"Mouse input sends signed relative values");
    Expect(session,0,NO,@"A1 0A 00 81 7F 00 00");
    [session handlePacket:ParseHex(@"41 0A") control:YES]; Expect(session,1,YES,@"A1 0A 00 00 00 00 00");
    [session handlePacket:ParseHex(@"70") control:YES];
    Check([session sendReport:10 payload:MouseReport(1,0,0)],@"Boot protocol uses the required three-byte ID-2 report");
    Expect(session,3,NO,@"A1 02 01 00 00");
    [session stop]; Expect(session,4,NO,@"A1 02 00 00 00");
    session = [TestSession new];
    Check([session sendReport:10 payload:MouseWheelReport(0,0,0,-2)],@"Vertical scrolling uses the existing mouse ID and payload");
    Expect(session,0,NO,@"A1 0A 00 00 00 00 FE");
    [session handlePacket:ParseHex(@"41 0A") control:YES]; Expect(session,1,YES,@"A1 0A 00 00 00 00 00");
    session.protocolMode = 0;
    Check(![session sendReport:10 payload:MouseWheelReport(0,0,0,1)] && session.packets.count == 2,@"Boot protocol cannot silently discard wheel bytes");
    session = [TestSession new]; session.suspended = YES;
    Check(![session sendReport:10 payload:MouseReport(0,1,1)] && !session.packets.count,@"Suspended mouse input is rejected");
    session.suspended = NO; session.ready = NO;
    Check(![session sendReport:10 payload:MouseReport(0,1,1)] && !session.packets.count,@"Offline mouse input is rejected");
}

static void NavigationTests(void) {
    TestSession *session = [TestSession new];
    Check([session sendNavigationUsage:0x0224],@"Back sends a press/release pair");
    Expect(session,0,NO,@"A1 02 01 00"); Expect(session,1,NO,@"A1 02 00 00");
    Check([session sendNavigationUsage:0x0223],@"Home sends a press/release pair");
    Expect(session,2,NO,@"A1 02 04 00"); Expect(session,3,NO,@"A1 02 00 00");
    for (unsigned bit = 0; bit < 16; bit++) if (bit != 0 && bit != 2) {
        uint16_t value = (uint16_t)(1U << bit);
        Check(![session sendReport:2 payload:Bytes((uint8_t[]){value & 255,value >> 8},2)],@"Every other consumer bit is rejected without transmission");
    }
    Check(![session sendReport:2 payload:ParseHex(@"05 00")] && session.packets.count == 4,@"Combined navigation bits are rejected");
    session.protocolMode = 0;
    Check(![session sendNavigationUsage:0x0224] && ![session sendReport:2 payload:ParseHex(@"00 00")] && session.packets.count == 4,@"Consumer packets cannot collide with boot mouse ID 2");
    [session handlePacket:ParseHex(@"41 02") control:YES]; Expect(session,4,YES,@"A1 02 00 00 00");
    session.protocolMode = 1; session.consumerControls = 4;
    [session handlePacket:ParseHex(@"41 02") control:YES]; Expect(session,5,YES,@"A1 02 04 00");
    [session disconnect]; Expect(session,6,NO,@"A1 02 00 00");
    session = [TestSession new];
    Check([session openRecentApps],@"Recents delivers a complete held Windows+Tab shortcut");
    Expect(session,0,NO,@"A1 01 00 00 00 00 00 00 00 00");
    Expect(session,1,NO,@"A1 01 08 00 00 00 00 00 00 00");
    Expect(session,2,NO,@"A1 01 08 00 2B 00 00 00 00 00");
    Expect(session,3,NO,@"A1 01 08 00 00 00 00 00 00 00");
    Expect(session,4,NO,@"A1 01 00 00 00 00 00 00 00 00");
    session = [TestSession new]; session.failAt = 2;
    Check(![session openRecentApps] && session.packets.count == 2,@"Recents stops on a failed stage and does not try another shortcut");
}

static void InputTests(void) {
    TestSession *session = [TestSession new];
    Check(ExecuteCommand(session,@[@"pin",@"1234"]),@"PIN command succeeds");
    Check(session.packets.count == 10,@"PIN has exactly five press/release pairs");
    NSArray *expected = @[@"A1 01 00 00 1E 00 00 00 00 00", @"A1 01 00 00 1F 00 00 00 00 00",
        @"A1 01 00 00 20 00 00 00 00 00", @"A1 01 00 00 21 00 00 00 00 00", @"A1 01 00 00 28 00 00 00 00 00"];
    for (NSUInteger i = 0; i < 5; i++) { Expect(session,2*i,NO,expected[i]); Expect(session,2*i+1,NO,@"A1 01 00 00 00 00 00 00 00 00"); }
    session = [TestSession new];
    Check([session typeText:@"A!0"],@"ASCII shifted and unshifted text succeeds");
    Expect(session,0,NO,@"A1 01 02 00 04 00 00 00 00 00");
    Expect(session,2,NO,@"A1 01 02 00 1E 00 00 00 00 00");
    Expect(session,4,NO,@"A1 01 00 00 27 00 00 00 00 00");
    for (unichar c = 32; c <= 126; c++) { Key key; Check(ASCIIKey(c,&key),@"Every printable ASCII character maps"); }
    session = [TestSession new];
    Check(![session typeText:@"abcé"],@"Unsupported Unicode is rejected");
    Check(session.packets.count == 0,@"Unicode rejection happens before any prefix is sent");
    Key key; NSString *error = nil;
    Check(ParseChord(@"ctrl+shift+a",&key,&error) && key.modifiers == 3 && key.usage == 4,@"Chord maps modifiers and usage");
    Check(ParseChord(@"F12",&key,&error) && key.usage == 0x45,@"F12 maps correctly");
    Check(!ParseChord(@"f1junk",&key,&error),@"Malformed function key is rejected");
    Check(!ParseChord(@"hyper+a",&key,&error),@"Unknown modifier is rejected");
    session = [TestSession new]; session.failAt = 3;
    Check(!ExecuteCommand(session,@[@"pin",@"1234"]) && session.packets.count == 3,@"A write failure stops PIN input without retry or Enter");
    session = [TestSession new];
    [session sendReport:1 payload:KeyboardReport(1,@[@4])];
    [session stop];
    Expect(session,1,NO,@"A1 01 00 00 00 00 00 00 00 00");
    Check(!session.ready,@"Orderly stop releases held keys");
}

static void ProtocolTests(void) {
    TestSession *session = [TestSession new];
    [session handlePacket:ParseHex(@"60") control:YES]; Expect(session,0,YES,@"A0 01");
    [session handlePacket:ParseHex(@"70") control:YES]; Expect(session,1,YES,@"00");
    Check(session.protocolMode == 0,@"Host can select boot mode");
    Check([session tap:(Key){0x28,0}],@"Boot keyboard works");
    Expect(session,2,NO,@"A1 01 00 00 28 00 00 00 00 00");
    [session handlePacket:ParseHex(@"41 02") control:YES]; Expect(session,4,YES,@"A1 02 00 00 00");
    [session handlePacket:ParseHex(@"41 03") control:YES]; Expect(session,5,YES,@"02");
    [session handlePacket:ParseHex(@"71") control:YES]; Expect(session,6,YES,@"00");
    [session handlePacket:ParseHex(@"52 01 07") control:YES]; Expect(session,7,YES,@"00");
    Check(session.LEDs == 7,@"SET_REPORT updates keyboard LEDs");
    [session handlePacket:ParseHex(@"42 01") control:YES]; Expect(session,8,YES,@"A2 01 07");
    [session handlePacket:ParseHex(@"A2 01 02") control:NO];
    Check(session.LEDs == 2 && session.packets.count == 9,@"Interrupt LED DATA generates no handshake");
    [session handlePacket:ParseHex(@"41") control:YES]; Expect(session,9,YES,@"04");
    [session handlePacket:ParseHex(@"72") control:YES]; Expect(session,10,YES,@"04");
    [session handlePacket:ParseHex(@"13") control:YES];
    Check(![session tap:(Key){4,0}] && session.packets.count == 11,@"Suspend prevents input");
    [session handlePacket:ParseHex(@"14") control:YES]; Check([session tap:(Key){4,0}],@"Resume permits input");
    [session handlePacket:ParseHex(@"15") control:YES]; Check(!session.ready,@"Virtual unplug closes input");
    // Every transaction nibble at short lengths must be safe, including incomplete requests.
    for (unsigned header = 0; header < 256; header++) {
        for (unsigned length = 0; length <= 4; length++) {
            uint8_t bytes[] = {(uint8_t)header,1,0,0};
            TestSession *fuzz = [TestSession new];
            [fuzz handlePacket:Bytes(bytes,length) control:YES];
            [fuzz handlePacket:Bytes(bytes,length) control:NO];
        }
    }
    Check(YES,@"All short control/interrupt packets handled without out-of-bounds reads");
}

@interface SmokeApp : AnikeyApp
@end
@implementation SmokeApp
- (void)startBluetooth { [self refresh:nil]; }
- (void)rememberSelection {} // Tests must never alter the user's remembered phone.
- (void)refresh:(id)sender {
    (void)sender;
    [self.devices removeAllItems]; [self.devices addItemWithTitle:@"Android phone — test transport (no Bluetooth)"];
    self.devices.lastItem.representedObject = @"AA-BB-CC-DD-EE-FF";
    self.selectedAddress = @"AA-BB-CC-DD-EE-FF"; self.bluetoothAvailable = YES; [self refreshControls];
}
@end
static void ForwardingTests(void) {
    SmokeApp *app = [SmokeApp new]; TestSession *session = [TestSession new]; app.session = session;
    app.heldKeys = [NSMutableOrderedSet orderedSet];
    Check(PhysicalUsage(0x00) == 4 && PhysicalUsage(0x24) == 0x28 && PhysicalUsage(0x30) == 0x2B,@"Physical A, Enter and Tab map to HID");
    Check(PhysicalUsage(0x7A) == 0x3A && PhysicalUsage(0x6F) == 0x45 && PhysicalUsage(0x7B) == 0x50,@"Physical F1/F12 and navigation map to HID");
    Check(PhysicalModifiers(NSEventModifierFlagCommand|NSEventModifierFlagShift) == 3,@"Mac Command shortcuts map to Android Ctrl");
    [app physicalKey:0x00 down:YES flags:NSEventModifierFlagShift];
    Expect(session,0,NO,@"A1 01 02 00 04 00 00 00 00 00");
    [app physicalKey:0x01 down:YES flags:NSEventModifierFlagControl];
    Expect(session,1,NO,@"A1 01 01 00 04 16 00 00 00 00");
    [app physicalKey:0x00 down:NO flags:NSEventModifierFlagControl];
    Expect(session,2,NO,@"A1 01 01 00 16 00 00 00 00 00");
    [app physicalKey:0x01 down:NO flags:0];
    Expect(session,3,NO,@"A1 01 00 00 00 00 00 00 00 00");
    for (unsigned short code = 0; code < 7; code++) [app physicalKey:code down:YES flags:0];
    Expect(session,10,NO,@"A1 01 00 00 01 01 01 01 01 01");
    [app physicalKey:0x06 down:NO flags:0];
    Expect(session,11,NO,@"A1 01 00 00 04 16 07 09 0B 0A");
    [app releaseInput];
    Expect(session,12,NO,@"A1 01 00 00 00 00 00 00 00 00");
    Check(session.packets.count == 13,@"Focus loss sends exactly one keyboard release");
    Check(!app.heldKeys.count,@"Focus loss releases held input");
    session.ready = NO;
    [app physicalKey:0x00 down:YES flags:0];
    Check(session.packets.count == 13 && !app.heldKeys.count,@"Disconnected typing is never buffered");
    app.bluetoothAvailable = YES; app.selectedAddress = @"AA-BB-CC-DD-EE-FF"; session.connectFailure = YES;
    [app update:nil]; Check(session.connectCount == 0,@"Timer polling never connects automatically");
    [app connectionAction:nil]; Check(session.connectCount == 1 && !session.ready,@"Manual Connect performs one attempt");
    for (unsigned i = 0; i < 10; i++) [app update:nil];
    Check(session.connectCount == 1,@"A failed connection remains idle instead of retrying");
    session.connectFailure = NO; [app connectionAction:nil];
    Check(session.ready && session.connectCount == 2 && session.packets.count == 13,@"Manual reconnect succeeds without replaying old input");
}

// Synthetic AppKit event values exercise gesture arbitration without touching
// Bluetooth or changing the user's system trackpad gesture settings.
@interface PadTestTouch : NSObject
@property (strong) id identity, device;
@property NSTouchPhase phase;
@property NSPoint normalizedPosition;
@property NSSize deviceSize;
@end
@implementation PadTestTouch
@end
@interface PadTestEvent : NSObject
@property NSEventPhase phase, momentumPhase;
@property CGFloat scrollingDeltaX, scrollingDeltaY;
@property BOOL hasPreciseScrollingDeltas;
@property (strong) NSArray<PadTestTouch *> *touches;
- (NSSet *)touchesMatchingPhase:(NSTouchPhase)phase inView:(NSView *)view;
@end
@implementation PadTestEvent
- (NSSet *)touchesMatchingPhase:(NSTouchPhase)phase inView:(NSView *)view {
    (void)view; NSMutableSet *result = [NSMutableSet set];
    for (PadTestTouch *touch in self.touches) if (touch.phase & phase) [result addObject:touch];
    return result;
}
@end
static NSEvent *PadScroll(NSEventPhase phase, double x, double y, NSEventPhase momentum) {
    PadTestEvent *event = [PadTestEvent new]; event.phase = phase; event.momentumPhase = momentum;
    event.scrollingDeltaX = x; event.scrollingDeltaY = y; event.hasPreciseScrollingDeltas = YES;
    return (NSEvent *)event;
}
static NSEvent *PadTouches(NSUInteger count, NSTouchPhase phase, double y) {
    PadTestEvent *event = [PadTestEvent new]; NSMutableArray *touches = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        PadTestTouch *touch = [PadTestTouch new]; touch.identity = @(i); touch.device = @1;
        touch.phase = phase; touch.normalizedPosition = NSMakePoint(0.2+0.1*i,y); touch.deviceSize = NSMakeSize(100,100);
        [touches addObject:touch];
    }
    event.touches = touches; return (NSEvent *)event;
}
static void PadGestureTests(void) {
    AnikeyApp *app = [AnikeyApp new]; TestSession *session = [TestSession new]; app.session = session;
    app.scrollScale = 1;
    CursorPad *pad = [[CursorPad alloc] initWithFrame:NSMakeRect(0,0,400,140)]; app.cursorPad = pad; pad.owner = app;
    [pad scrollWheel:PadScroll(NSEventPhaseBegan,0,0,0)];
    [pad scrollWheel:PadScroll(NSEventPhaseChanged,0,-24,0)]; [app flushPointer:nil];
    Expect(session,0,NO,@"A1 0A 00 00 00 00 FE");
    [pad scrollWheel:PadScroll(NSEventPhaseEnded,0,0,0)];
    [pad scrollWheel:PadScroll(NSEventPhaseNone,0,-120,NSEventPhaseChanged)]; [app flushPointer:nil];
    Check(session.packets.count == 1,@"Lifting fingers stops scroll; inertia is not forwarded");
    for (NSNumber *direction in @[@-1,@1]) {
        [session.packets removeAllObjects];
        [pad scrollWheel:PadScroll(NSEventPhaseBegan,0,0,0)];
        [pad scrollWheel:PadScroll(NSEventPhaseChanged,45*direction.intValue,0,0)]; [app flushPointer:nil];
        Check(session.packets.count == 2 && app.pointerButtons == 1,@"Two-finger horizontal scrolling holds content instead of navigating");
        Expect(session,0,NO,@"A1 0A 01 00 00 00 00");
        Expect(session,1,NO,direction.intValue > 0 ? @"A1 0A 01 2D 00 00 00" : @"A1 0A 01 D3 00 00 00");
        [pad scrollWheel:PadScroll(NSEventPhaseEnded,0,0,0)];
        Expect(session,2,NO,@"A1 0A 00 00 00 00 00");
        Check(session.packets.count == 3 && !app.pointerButtons,@"Either sideways scroll releases content without a Back or Home report");
    }
    [session.packets removeAllObjects];
    [pad scrollWheel:PadScroll(NSEventPhaseBegan,0,0,0)];
    [pad scrollWheel:PadScroll(NSEventPhaseChanged,8,0,0)];
    [pad scrollWheel:PadScroll(NSEventPhaseEnded,0,0,0)];
    Check(!session.packets.count,@"Tiny horizontal scroll jitter cannot click phone content");
    [pad scrollWheel:PadScroll(NSEventPhaseBegan,0,0,0)];
    [pad scrollWheel:PadScroll(NSEventPhaseChanged,22,22,0)];
    [pad scrollWheel:PadScroll(NSEventPhaseEnded,0,0,0)]; [app flushPointer:nil];
    Check(session.packets.count == 1,@"Diagonal content motion scrolls instead of being discarded or navigating");
    Expect(session,0,NO,@"A1 0A 00 00 00 00 01");
    [session.packets removeAllObjects];
    [pad scrollWheel:PadScroll(NSEventPhaseBegan,0,0,0)];
    [pad scrollWheel:PadScroll(NSEventPhaseChanged,0,24,0)]; [app flushPointer:nil];
    [pad scrollWheel:PadScroll(NSEventPhaseChanged,90,12,0)]; [app flushPointer:nil];
    [pad scrollWheel:PadScroll(NSEventPhaseEnded,0,0,0)];
    Check(session.packets.count == 2,@"A scroll stays a scroll even when the finger changes direction");
    Expect(session,0,NO,@"A1 0A 00 00 00 00 02"); Expect(session,1,NO,@"A1 0A 00 00 00 00 01");
    [session.packets removeAllObjects];
    [pad scrollWheel:PadScroll(NSEventPhaseBegan,50,0,0)];
    [pad scrollWheel:PadScroll(NSEventPhaseCancelled,0,0,0)];
    Check(session.packets.count == 3 && !app.pointerButtons,@"Cancelling horizontal content sliding releases its held button without navigating");
    Expect(session,2,NO,@"A1 0A 00 00 00 00 00");
    [session.packets removeAllObjects];
    [pad scrollWheel:PadScroll(NSEventPhaseBegan,50,0,0)];
    [pad scrollWheel:PadScroll(NSEventPhaseCancelled,0,0,NSEventPhaseChanged)];
    Check(session.packets.count == 3 && !app.pointerButtons,@"Cancellation releases a content drag even when the event also carries momentum");
    Expect(session,2,NO,@"A1 0A 00 00 00 00 00");
    [session.packets removeAllObjects];
    [pad touchesBeganWithEvent:PadTouches(3,NSTouchPhaseBegan,0.2)];
    [pad scrollWheel:PadScroll(NSEventPhaseBegan,0,100,0)]; [app flushPointer:nil];
    Check(!session.packets.count,@"macOS three-finger gestures cannot leak wheel input");
    [pad touchesMovedWithEvent:PadTouches(3,NSTouchPhaseMoved,0.7)];
    [pad touchesEndedWithEvent:PadTouches(3,NSTouchPhaseEnded,0.7)];
    [pad scrollWheel:PadScroll(NSEventPhaseEnded,0,0,0)];
    Check(!session.packets.count,@"Three-finger up is left to macOS without a navigation or scroll tail");
    [pad touchesBeganWithEvent:PadTouches(3,NSTouchPhaseBegan,0.7)];
    [pad touchesMovedWithEvent:PadTouches(3,NSTouchPhaseMoved,0.2)];
    [pad touchesEndedWithEvent:PadTouches(3,NSTouchPhaseEnded,0.2)];
    Check(!session.packets.count,@"Three-finger down cannot send Recents to the phone");
    [pad touchesBeganWithEvent:PadTouches(3,NSTouchPhaseBegan,0.2)];
    [pad touchesBeganWithEvent:PadTouches(4,NSTouchPhaseBegan,0.3)];
    [pad touchesEndedWithEvent:PadTouches(4,NSTouchPhaseEnded,0.8)];
    Check(!session.packets.count,@"Four-finger system gestures cannot be mistaken for Home");
    [pad touchesBeganWithEvent:PadTouches(3,NSTouchPhaseBegan,0.2)];
    [pad touchesCancelledWithEvent:PadTouches(3,NSTouchPhaseCancelled,0.8)];
    Check(!session.packets.count && !pad.touchSequenceBlocked,@"Cancelling touches ends the ignored sequence");
    app.transport = [TransportWorker new];
    [app.transport perform:^{ Pump(0.1); }];
    [pad scrollWheel:PadScroll(NSEventPhaseBegan,0,0,0)];
    [pad scrollWheel:PadScroll(NSEventPhaseChanged,0,48,0)]; [app flushPointer:nil];
    [pad mouseExited:PadScroll(NSEventPhaseEnded,0,0,0)];
    __block BOOL drained = NO;
    [app onTransport:^(AnikeySession *transport) { (void)transport; } completion:^{ drained = YES; }];
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime+2;
    while (!drained && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.005);
    Check(drained && !session.packets.count,@"Pad exit discards scroll queued behind a blocked write");
    [app.transport finish];
    while (app.transport.thread && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.005);
    Check(!app.transport.thread,@"Gesture worker terminates after cancellation");
}
static void PadScrollResponsivenessTests(void) {
    AnikeyApp *app = [AnikeyApp new]; TestSession *session = [TestSession new]; app.session = session;
    CursorPad *pad = [[CursorPad alloc] initWithFrame:NSMakeRect(0,0,400,140)]; app.cursorPad = pad; pad.owner = app;
    Check(app.scrollScale == 0.125,@"Two-finger scrolling starts with extra-slow sensitivity");
    [pad scrollWheel:PadScroll(NSEventPhaseBegan,0,12,0)];
    Check(!session.packets.count && app.motion.wheel == 0.125,@"Extra-slow scrolling retains small movements without a jump");
    [pad scrollWheel:PadScroll(NSEventPhaseChanged,0,84,0)];
    Check(session.packets.count == 1,@"A complete wheel step is sent without waiting for the timer");
    Expect(session,0,NO,@"A1 0A 00 00 00 00 01");
    [pad scrollWheel:PadScroll(NSEventPhaseEnded,0,0,0)];
    [session.packets removeAllObjects];
    // A latched AppKit scroll may reach the view after its began event.
    [pad scrollWheel:PadScroll(NSEventPhaseChanged,30,0,0)];
    Check(app.pointerButtons == 1 && session.packets.count == 2,@"A sideways stream can start from its first changed event");
    [pad touchesCancelledWithEvent:PadTouches(2,NSTouchPhaseCancelled,0.5)];
    Check(pad.gestureActive && app.pointerButtons == 1,@"Raw touch cancellation does not abort a recognized sideways scroll");
    [pad scrollWheel:PadScroll(NSEventPhaseChanged,-20,0,0)];
    Expect(session,2,NO,@"A1 0A 01 EC 00 00 00");
    [pad scrollWheel:PadScroll(NSEventPhaseEnded,0,0,0)];
    Expect(session,3,NO,@"A1 0A 00 00 00 00 00");
    Check(!app.pointerButtons && !pad.gestureActive,@"Scroll completion releases after raw touch ownership changes");
    app.scrollSpeedPicker = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [app.scrollSpeedPicker addItemsWithTitles:@[@"Extra slow",@"Gentle",@"Standard",@"Fast"]];
    NSArray *tags = @[@3,@0,@1,@2];
    for (NSUInteger i = 0; i < tags.count; i++) [app.scrollSpeedPicker itemAtIndex:i].tag = [tags[i] integerValue];
    [app.scrollSpeedPicker selectItemWithTag:3]; [app changeScrollSpeed:nil];
    Check(app.scrollScale == 0.125,@"Extra slow is four times slower than Gentle");
    for (NSNumber *index in @[@0,@1,@2]) {
        [app.scrollSpeedPicker selectItemWithTag:index.integerValue]; [app changeScrollSpeed:nil];
        Check(app.scrollScale == 0.5+0.5*index.integerValue,@"Each scroll speed has the expected multiplier");
    }
    [session.packets removeAllObjects];
    [pad scrollWheel:PadScroll(NSEventPhaseBegan,0,24,0)];
    Expect(session,0,NO,@"A1 0A 00 00 00 00 03");
    [pad scrollWheel:PadScroll(NSEventPhaseCancelled,0,0,0)];
    [session.packets removeAllObjects];
    PadTestEvent *wheel = (PadTestEvent *)PadScroll(NSEventPhaseNone,0,1,0); wheel.hasPreciseScrollingDeltas = NO;
    [pad scrollWheel:(NSEvent *)wheel];
    Expect(session,0,NO,@"A1 0A 00 00 00 00 01");
    Check(session.packets.count == 1,@"Physical mouse-wheel detents keep their original sensitivity and send immediately");
}
static void PadScrollCompletionTests(void) {
    AnikeyApp *app = [AnikeyApp new]; TestSession *session = [TestSession new]; app.session = session;
    app.scrollScale = 1;
    CursorPad *pad = [[CursorPad alloc] initWithFrame:NSMakeRect(0,0,400,140)]; app.cursorPad = pad; pad.owner = app;
    app.transport = [TransportWorker new];
    for (NSUInteger scenario = 0; scenario < 3; scenario++) {
        [app resetPointer]; [session.packets removeAllObjects];
        [app.transport perform:^{ Pump(0.1); }];
        [pad scrollWheel:PadScroll(NSEventPhaseBegan,0,0,0)];
        [pad scrollWheel:PadScroll(NSEventPhaseChanged,0,-24,0)]; [app flushPointer:nil];
        if (scenario == 1) [pad scrollWheel:PadScroll(NSEventPhaseChanged,0,-1200,0)];
        [pad scrollWheel:PadScroll(NSEventPhaseEnded,0,0,0)];
        if (scenario == 2) [pad mouseExited:PadScroll(NSEventPhaseEnded,0,0,0)];
        __block BOOL drained = NO;
        [app onTransport:^(AnikeySession *transport) { (void)transport; } completion:^{ drained = YES; }];
        NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime+2;
        while ((!drained || app.pointerBusy) && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.005);
        Check(drained && !app.pointerBusy,@"Finished scroll writes drain without a timer");
        if (scenario == 0) {
            Check(session.packets.count == 1,@"A fast flick survives normal finger lift before its queued write starts");
            Expect(session,0,NO,@"A1 0A 00 00 00 00 FE");
        } else if (scenario == 1) {
            Check(session.packets.count == 2,@"Lifting fingers retains at most one bounded final scroll packet");
            Expect(session,0,NO,@"A1 0A 00 00 00 00 FE"); Expect(session,1,NO,@"A1 0A 00 00 00 00 F8");
        } else Check(!session.packets.count,@"Leaving the pad still cancels a completed flick waiting behind a blocked write");
        Check(![app.motion takeReport] && !app.pointerButtons,@"Finished scrolling leaves no backlog or held input");
    }
    [app.transport finish]; NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime+2;
    while (app.transport.thread && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.005);
    Check(!app.transport.thread,@"Scroll completion worker shuts down cleanly");
}
static NSEvent *PadMouse(CursorPad *pad, NSEventType type, double x, double y) {
    return [NSEvent mouseEventWithType:type location:[pad convertPoint:NSMakePoint(x,y) toView:nil]
        modifierFlags:0 timestamp:0 windowNumber:pad.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
}
static void PadInteractionTests(void) {
    AnikeyApp *app = [AnikeyApp new]; TestSession *session = [TestSession new]; app.session = session;
    app.scrollScale = 0.5;
    app.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,400,160) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    app.window.releasedWhenClosed = NO;
    CursorPad *pad = [[CursorPad alloc] initWithFrame:NSMakeRect(0,0,400,160)]; app.cursorPad = pad; pad.owner = app;
    [app.window.contentView addSubview:pad];
    for (NSArray *delta in @[@[@60,@0],@[@-60,@0],@[@0,@-40],@[@0,@50],@[@50,@50],@[@12,@0]]) {
        [app resetPointer]; [session.packets removeAllObjects];
        [pad mouseDown:PadMouse(pad,NSEventTypeLeftMouseDown,200,80)];
        Check(session.packets.count == 1 && app.pointerButtons == 1,@"Native mouse-down immediately holds the phone button");
        Expect(session,0,NO,@"A1 0A 01 00 00 00 00");
        int x = [delta[0] intValue], y = [delta[1] intValue];
        [pad mouseDragged:PadMouse(pad,NSEventTypeLeftMouseDragged,200+x,80+y)];
        Check(session.packets.count == 2 && app.pointerButtons == 1,@"Dragging sends held movement before mouse-up, in every direction");
        uint8_t movement[] = {0xA1,0x0A,1,(uint8_t)x,(uint8_t)y,0,0};
        Expect(session,1,NO,Hex(Bytes(movement,sizeof(movement))));
        [pad mouseUp:PadMouse(pad,NSEventTypeLeftMouseUp,200+x,80+y)];
        Expect(session,2,NO,@"A1 0A 00 00 00 00 00");
        Check(session.packets.count == 3 && !app.pointerButtons,@"A content drag releases exactly once and never emits Back/Home");
    }
    [app resetPointer]; [session.packets removeAllObjects];
    [pad mouseDown:PadMouse(pad,NSEventTypeLeftMouseDown,200,80)];
    [pad mouseUp:PadMouse(pad,NSEventTypeLeftMouseUp,200,80)];
    Expect(session,0,NO,@"A1 0A 01 00 00 00 00"); Expect(session,1,NO,@"A1 0A 00 00 00 00 00");
    Check(session.packets.count == 2,@"A short click remains one phone tap");
    [app resetPointer]; [session.packets removeAllObjects];
    [pad mouseDown:PadMouse(pad,NSEventTypeLeftMouseDown,200,80)];
    [pad mouseDragged:PadMouse(pad,NSEventTypeLeftMouseDragged,260,80)];
    [pad mouseDown:PadMouse(pad,NSEventTypeLeftMouseDown,260,80)];
    [pad scrollWheel:PadScroll(NSEventPhaseBegan,0,100,0)];
    [pad scrollWheel:PadScroll(NSEventPhaseCancelled,0,0,0)];
    [pad touchesCancelledWithEvent:PadTouches(1,NSTouchPhaseCancelled,0.5)];
    Check(session.packets.count == 2 && app.pointerButtons == 1 && pad.pressed,@"Duplicate presses, scroll events and raw touch cancellation cannot interrupt a held physical drag");
    [pad mouseUp:PadMouse(pad,NSEventTypeLeftMouseUp,260,80)];
    Expect(session,2,NO,@"A1 0A 00 00 00 00 00");
    [app resetPointer];
    [session.packets removeAllObjects];
    [pad mouseDown:PadMouse(pad,NSEventTypeLeftMouseDown,200,80)];
    [pad mouseDragged:PadMouse(pad,NSEventTypeLeftMouseDragged,500,80)];
    [pad mouseUp:PadMouse(pad,NSEventTypeLeftMouseUp,500,80)];
    Check(session.packets.count == 2 && !pad.pressed && !app.pointerButtons,@"Leaving the pad releases a held drag without sending outside movement");
    Expect(session,1,NO,@"A1 0A 00 00 00 00 00");
    [app resetPointer]; [session.packets removeAllObjects];
    [pad scrollWheel:PadScroll(NSEventPhaseBegan,0,24,0)];
    [pad mouseDown:PadMouse(pad,NSEventTypeLeftMouseDown,200,80)];
    Check(!pad.gestureActive && pad.pressed && app.pointerButtons == 1,@"Clicking takes over immediately from an unfinished scroll gesture");
    [pad mouseUp:PadMouse(pad,NSEventTypeLeftMouseUp,200,80)];
    Check(session.packets.count == 3,@"Scroll is delivered immediately; clicking then produces one tap without replaying it");
    Expect(session,0,NO,@"A1 0A 00 00 00 00 01");
    Expect(session,1,NO,@"A1 0A 01 00 00 00 00"); Expect(session,2,NO,@"A1 0A 00 00 00 00 00");
    [app.window orderOut:nil];
}
static void PadDragTests(void) {
    AnikeyApp *app = [AnikeyApp new]; TestSession *session = [TestSession new]; app.session = session;
    [app beginPointerDrag];
    Check(app.pointerButtons == 1,@"Pressing starts a held phone button");
    Expect(session,0,NO,@"A1 0A 01 00 00 00 00");
    [app.motion addX:20 y:-12]; [app flushPointer:nil];
    Expect(session,1,NO,@"A1 0A 01 14 F4 00 00");
    [app sendPointerButton:2]; Check(session.packets.count == 2,@"Secondary clicks cannot replace an active drag");
    [app.motion addX:2 y:3]; [app endPointerDrag];
    Expect(session,2,NO,@"A1 0A 01 02 03 00 00"); Expect(session,3,NO,@"A1 0A 00 00 00 00 00");
    Check(!app.pointerButtons && ((const uint8_t *)session.mouse.bytes)[0] == 0,@"Release flushes final held movement then lets go");
    [app.motion addX:1 y:0]; [app flushPointer:nil]; Expect(session,4,NO,@"A1 0A 00 01 00 00 00");
    [session.packets removeAllObjects];
    [app beginPointerDrag]; [app.motion addX:100 y:100]; [app releaseInput];
    Expect(session,0,NO,@"A1 0A 01 00 00 00 00"); Expect(session,1,NO,@"A1 0A 00 00 00 00 00");
    Expect(session,2,NO,@"A1 01 00 00 00 00 00 00 00 00");
    Check(session.packets.count == 3 && ![app.motion takeReport],@"Focus loss releases the drag and discards movement");
    [session.packets removeAllObjects];
    app.transport = [TransportWorker new];
    [app.transport perform:^{ Pump(0.1); }];
    [app beginPointerDrag]; [app endPointerDrag];
    __block BOOL drained = NO;
    [app onTransport:^(AnikeySession *transport) { (void)transport; } completion:^{ drained = YES; }];
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime+2;
    while (!drained && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.005);
    Check(drained && session.packets.count == 2,@"A quick click queued before the worker runs preserves both press and release");
    Expect(session,0,NO,@"A1 0A 01 00 00 00 00"); Expect(session,1,NO,@"A1 0A 00 00 00 00 00");
    [app.transport finish];
    while (app.transport.thread && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.005);
    SlowWriteSession *slow = [SlowWriteSession new]; app.session = slow; app.transport = [TransportWorker new];
    [app beginPointerDrag]; deadline = NSProcessInfo.processInfo.systemUptime+2;
    while (!slow.enteredWrite && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.005);
    Check(slow.enteredWrite,@"The press is inside a blocked Bluetooth write");
    [app.motion addX:80 y:-50]; [app flushPointer:nil]; [app resetPointer];
    drained = NO;
    [app onTransport:^(AnikeySession *transport) { (void)transport; } completion:^{ drained = YES; }];
    while (!drained && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.005);
    Check(drained && slow.packets.count == 2,@"Cancellation drops queued dragging but preserves release after a blocked press completes");
    Expect(slow,0,NO,@"A1 0A 01 00 00 00 00"); Expect(slow,1,NO,@"A1 0A 00 00 00 00 00");
    Check(!app.pointerButtons && ((const uint8_t *)slow.mouse.bytes)[0] == 0,@"Cancellation leaves no held phone button");
    [app.transport finish];
    while (app.transport.thread && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.005);
    Check(!app.transport.thread,@"Drag worker shuts down cleanly");
    slow = [SlowWriteSession new]; app.session = slow; app.transport = [TransportWorker new];
    [app beginPointerDrag]; deadline = NSProcessInfo.processInfo.systemUptime+2;
    while (!slow.enteredWrite && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.005);
    Check(slow.enteredWrite,@"Continuous-drag test starts with a slow press write");
    [app.motion addX:20 y:0]; [app flushPointer:nil];
    [app.motion addX:30 y:-10]; [app flushPointer:nil];
    while ((slow.packets.count < 3 || app.pointerBusy) && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.005);
    Check(slow.packets.count == 3 && app.pointerButtons == 1,@"Pending drag motion drains after write completion without a timer or release");
    Expect(slow,0,NO,@"A1 0A 01 00 00 00 00");
    Expect(slow,1,NO,@"A1 0A 01 14 00 00 00");
    Expect(slow,2,NO,@"A1 0A 01 1E F6 00 00");
    [app endPointerDrag]; drained = NO;
    [app onTransport:^(AnikeySession *transport) { (void)transport; } completion:^{ drained = YES; }];
    while (!drained && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.005);
    Check(drained && slow.packets.count == 4,@"A continuous drag finishes with exactly one release");
    Expect(slow,3,NO,@"A1 0A 00 00 00 00 00");
    [app.transport finish];
    while (app.transport.thread && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.005);
    Check(!app.transport.thread,@"Continuous-drag worker shuts down");
}
static void ConnectionLifecycleTests(void) {
    TestSession *session = [TestSession new]; session.connecting = YES; session.ready = NO;
    MockOpenDevice *device = [MockOpenDevice new]; device.channel = [MockChannel new]; device.result = kIOReturnError;
    session.device = (IOBluetoothDevice *)device;
    Check(![session openPSM:0x11],@"A failed open is not treated as a connection just because a channel object exists");
    Check(device.channel.closes == 1 && device.channel.retainedDelegate == nil && session.control == nil,@"Failed channel objects are closed and their retained delegates detached");
    Check([session.lastError containsString:@"0xE00002BC"] && session.openingPSM == 0,@"Actual open status is preserved and pending PSM cleared");
    device.channel = [MockChannel new]; device.result = kIOReturnSuccess; device.earlyData = YES;
    Check([session openPSM:0x11],@"Successful open with data dispatched before return works");
    Expect(session,0,YES,@"A0 01");
    Check(device.channel.delegateRegistrations == 1,@"Async submission explicitly registers its delegate to start the modern bridge");
    Check(session.control == (IOBluetoothL2CAPChannel *)device.channel && !session.ready,@"Early control messages can be answered without enabling input prematurely");
    ServiceRemovalSpy *service = [ServiceRemovalSpy new]; session.service = (IOBluetoothSDPServiceRecord *)service;
    [session disconnect];
    Check(device.channel.closes == 1 && device.channel.retainedDelegate == nil,@"Disconnect closes owned channels without retaining delegates");
    Check(session.service == (IOBluetoothSDPServiceRecord *)service && service.removals == 0,@"Connection cleanup preserves the service for a retry");
    [session stop]; Check(service.removals == 1 && session.service == nil,@"Explicit stop removes the transient service");

    session = [TestSession new]; session.connecting = YES; session.ready = NO;
    device = [MockOpenDevice new]; device.channel = [MockChannel new]; device.result = kIOReturnError;
    device.earlyCompletion = YES; session.device = (IOBluetoothDevice *)device;
    Check(![session openPSM:0x13] && device.channel.closes == 1 && !session.interrupt,@"Failure after an early completion cleans up the adopted channel exactly once");
    device.channel = [MockChannel new]; device.result = kIOReturnSuccess; device.omitChannel = YES;
    Check(![session openPSM:0x11] && device.channel.closes == 1,@"Success status without a returned channel cleans up early ownership and fails");
    [session stop];
    session = [TestSession new]; session.ready = NO; session.connecting = YES;
    device = [MockOpenDevice new]; device.channel = [MockChannel new]; device.result = kIOReturnSuccess; device.returnedPSM = 0x1001;
    session.device = (IOBluetoothDevice *)device;
    Check(![session openPSM:0x11] && !session.control && device.channel.closes == 1,@"A successful SDK call on the wrong PSM is closed and blocked");
    device.returnedPSM = 0; device.channel = [MockChannel new]; device.channel.localChannelID = 0;
    Check([session openPSM:0x11] && session.control && device.channel.closes == 0,@"Zero legacy CIDs do not invalidate a successful matching-PSM open");
    [session stop];
    session = [TestSession new]; session.ready = NO; session.connecting = YES;
    device = [MockOpenDevice new]; device.channel = [MockChannel new]; device.result = kIOReturnSuccess;
    device.channel.delegateStatus = kIOReturnNotPermitted; session.device = (IOBluetoothDevice *)device;
    Check(![session openPSM:0x11] && !session.control && device.channel.closes == 1,@"Delegate registration failure closes the submitted channel");
    device.channel = [MockChannel new]; device.channel.openStatus = kIOReturnNotOpen;
    Check(![session openPSM:0x11] && !session.control && device.channel.closes == 1,@"Failed open callback blocks input despite successful submission");
    [session stop];
    NSString *status = ConnectionFailureStatus(@"Opening control PSM 0x0011: IOReturn 0xE00002BC");
    Check([status containsString:@"control PSM 0x0011"] && [status containsString:@"0xE00002BC"] && [status containsString:@"Press Connect"],@"Main failure status exposes the stage and points to manual Connect");
    Check(ConnectionFailureStatus(@"A very long publication error. Additional detail explaining the failure that does not fit in the compact main window.").length < 130,@"Long errors get a compact first sentence; Details retains the full error");
}
static void CheckBounds(NSView *parent) {
    for (NSView *view in parent.subviews) {
        Check(NSContainsRect(NSInsetRect(parent.bounds,-1,-1),view.frame),@"Control fits inside its parent");
        CheckBounds(view);
    }
}
static void WorkerTests(void) {
    TransportWorker *worker = [TransportWorker new]; NSMutableArray *order = [NSMutableArray array];
    __block BOOL finished = NO;
    [worker perform:^{ [order addObject:@"start"]; Pump(0.08); [order addObject:@"end"]; }];
    [worker perform:^{ [order addObject:@"second"]; dispatch_async(dispatch_get_main_queue(),^{ finished = YES; }); }];
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime+2;
    while (!finished && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.01);
    Check(finished && [order isEqual:@[@"start",@"end",@"second"]],@"Nested SDK run-loop pumping cannot reenter queued transport operations");
    [worker perform:^{ [worker finish]; }];
    while (worker.thread && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.01);
    Check(worker.thread == nil,@"Worker run-loop thread shuts down cleanly");

    SmokeApp *app = [SmokeApp new]; SlowWriteSession *session = [SlowWriteSession new]; app.session = session;
    app.transport = [TransportWorker new];
    [app physicalKey:0x00 down:YES flags:0];
    deadline = NSProcessInfo.processInfo.systemUptime+2;
    while (!session.enteredWrite && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.005);
    Check(session.enteredWrite && !session.writeOnMain,@"GUI packet writes run off the main thread even when the SDK write blocks");
    [app physicalKey:0x01 down:YES flags:0]; // Queued behind the blocked A press.
    [app releaseInput]; // Focus loss must discard the queued S press and release A.
    finished = NO;
    [app onTransport:^(AnikeySession *transport) { (void)transport; } completion:^{ finished = YES; }];
    while (!finished && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.01);
    Check(finished && session.packets.count == 2,@"Focus loss drops stale queued key events while preserving the neutral release");
    Expect(session,0,NO,@"A1 01 00 00 04 00 00 00 00 00");
    Expect(session,1,NO,@"A1 01 00 00 00 00 00 00 00 00");
    [app onTransport:^(AnikeySession *transport) { [transport stop]; [app.transport finish]; } completion:nil];
    while (app.transport.thread && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.01);
    Check(!app.transport.thread,@"Packet worker closes without retaining a background thread");

    app = [SmokeApp new]; session = [SlowWriteSession new]; app.session = session;
    app.transport = [TransportWorker new];
    [app.transport perform:^{ Pump(0.1); }];
    for (unsigned i = 0; i < 100; i++) { [app.motion addX:1 y:1]; [app flushPointer:nil]; }
    Check(app.pointerBusy && app.motion.x == 99,@"High-rate movement coalesces behind at most one pending transport operation");
    [app resetPointer]; finished = NO;
    [app onTransport:^(AnikeySession *transport) { (void)transport; } completion:^{ finished = YES; }];
    deadline = NSProcessInfo.processInfo.systemUptime+2;
    while (!finished && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.005);
    Check(finished && !app.pointerBusy && !session.packets.count,@"Pad exit cancels queued motion before it reaches the wire");
    [app.transport perform:^{ Pump(0.1); }];
    [app.motion addX:50 y:50]; [app sendPointerButton:1]; [app resetPointer]; finished = NO;
    [app onTransport:^(AnikeySession *transport) { (void)transport; } completion:^{ finished = YES; }];
    while (!finished && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.005);
    Check(finished && !session.packets.count,@"Pad exit discards motion and click snapshots waiting behind a blocked operation");
    [app.motion addX:20 y:-10]; [app flushPointer:nil];
    while (!session.enteredWrite && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.005);
    Check(session.enteredWrite && !session.writeOnMain,@"Mouse writes stay off AppKit even when blocked");
    for (unsigned i = 0; i < 100; i++) { [app.motion addX:1 y:1]; [app flushPointer:nil]; }
    [app releaseInput]; finished = NO;
    [app onTransport:^(AnikeySession *transport) { (void)transport; } completion:^{ finished = YES; }];
    while (!finished && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.005);
    Check(finished && session.packets.count == 2 && app.motion.x == 0,@"Focus loss discards accumulated motion behind a slow write");
    Expect(session,0,NO,@"A1 0A 00 14 F6 00 00");
    Expect(session,1,NO,@"A1 01 00 00 00 00 00 00 00 00");
    [app onTransport:^(AnikeySession *transport) { [transport stop]; [app.transport finish]; } completion:nil];
    while (app.transport.thread && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.005);
    Check(!app.transport.thread,@"Pointer worker shuts down cleanly");
}
static void ResponsiveConnectionTest(void) {
    SmokeApp *app = [SmokeApp new]; SlowTestSession *session = [SlowTestSession new]; session.ready = NO; app.session = session;
    [app applicationDidFinishLaunching:[NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:NSApp]];
    app.transport = [TransportWorker new];
    __block NSUInteger ticks = 0;
    NSTimer *heartbeat = [NSTimer scheduledTimerWithTimeInterval:0.01 repeats:YES block:^(NSTimer *timer) { (void)timer; ticks++; }];
    NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
    [app connectionAction:nil];
    Check(NSProcessInfo.processInfo.systemUptime-start < 0.15,@"Manual Connect returns immediately while the SDK operation blocks elsewhere");
    NSTimeInterval deadline = start+2;
    while (!session.enteredConnect && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.005);
    Check(session.enteredConnect && !session.connectOnMain,@"Bluetooth connection work runs off AppKit's main thread");
    Check(app.connectionPending && app.connectionButton.enabled && [app.connectionButton.title isEqual:@"Cancel"],@"Cancel remains available during a pending connection");
    Check([app windowShouldClose:app.window],@"The window can close during a pending connection");
    [app connectionAction:nil];
    Check(app.paused && session.cancelRequested && ![app canSendInput],@"Cancel immediately stops input without waiting for the SDK call");
    while (app.connectionPending && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.01);
    Check(!app.connectionPending && !session.ready && session.connectCount == 1,@"A late connection success is discarded and cleaned up after cancellation");
    Check(ticks >= 5,@"The main run loop remains responsive throughout the slow connection");
    for (unsigned i = 0; i < 20; i++) [app update:nil];
    Check(session.connectCount == 1 && [app.connectionButton.title isEqual:@"Connect"],@"Cancellation does not start another attempt");
    [app connectionAction:nil];
    TerminationReplySpy *termination = [TerminationReplySpy new];
    start = NSProcessInfo.processInfo.systemUptime;
    Check([app applicationShouldTerminate:(NSApplication *)termination] == NSTerminateLater,@"Quit during a pending connection starts asynchronous cleanup");
    Check(NSProcessInfo.processInfo.systemUptime-start < 0.15 && !app.window.visible,@"Quit hides the window immediately instead of refusing or beachballing");
    Check([app applicationShouldTerminate:(NSApplication *)termination] == NSTerminateLater,@"Repeated Quit shares the pending cleanup");
    while (!termination.replies && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.01);
    Check(termination.replies == 1 && termination.allowed && !session.ready,@"Cleanup replies to Quit exactly once with input disconnected");
    while (app.transport.thread && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.01);
    Check(app.transport.thread == nil,@"The connection worker exits after orderly Quit");
    [heartbeat invalidate];
    [app.window orderOut:nil];
}
static void BoundedQuitTest(void) {
    SmokeApp *app = [SmokeApp new]; SlowTestSession *session = [SlowTestSession new];
    session.ready = NO; session.blockDuration = 2.3; app.session = session;
    [app applicationDidFinishLaunching:[NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:NSApp]];
    app.transport = [TransportWorker new]; [app connectionAction:nil];
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime+5;
    while (!session.enteredConnect && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.005);
    Check(session.enteredConnect,@"Bounded-Quit test has an SDK call actively blocked");
    TerminationReplySpy *termination = [TerminationReplySpy new]; NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
    [app applicationShouldTerminate:(NSApplication *)termination];
    while (!termination.replies && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.005);
    Check(termination.replies == 1 && NSProcessInfo.processInfo.systemUptime-start < 2.2 && app.connectionPending,
          @"Quit finishes within its grace period even before the blocked SDK call returns");
    while (app.transport.thread && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.005);
    Check(!app.transport.thread && termination.replies == 1 && !session.ready,@"Late cleanup cannot reply to Quit twice or resurrect the connection");
}
static void UISmokeTest(NSString *destination) {
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    SmokeApp *app = [SmokeApp new]; TestSession *session = [TestSession new]; session.ready = NO; app.session = session;
    [app applicationDidFinishLaunching:[NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:NSApp]]; Pump(0.2);
    Check(app.window.visible && app.devices.numberOfItems == 1,@"Native window opens with device picker");
    Check(app.window.firstResponder == app.keyboardSurface && app.keyboardSurface.acceptsFirstResponder,@"Native keyboard area receives focus without a Send button");
    Check([app.window.title containsString:@"Bluetooth Keyboard"] && NSApp.mainMenu.numberOfItems >= 1,@"Keyboard title and native Quit menu exist");
    Check(app.inputControls.count == 8,@"Keyboard and navigation controls appear without separate mouse buttons");
    Check(session.connectCount == 0 && app.connectionButton.enabled,@"Startup stays idle with manual Connect");
    [app.connectionButton performClick:nil];
    Check(session.ready && session.connectCount == 1 && [app.connectionButton.title isEqual:@"Disconnect"],@"Connect performs exactly one attempt");
    [session.packets removeAllObjects];
    [app beginPointerDrag]; [app.motion addX:24 y:-16];
    NSTimeInterval trackingDeadline = NSProcessInfo.processInfo.systemUptime+0.08;
    while (NSProcessInfo.processInfo.systemUptime < trackingDeadline)
        [NSRunLoop.currentRunLoop runMode:NSEventTrackingRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    Check(session.packets.count == 2 && app.pointerButtons == 1,@"Pointer timer continues sending held motion during native mouse tracking");
    Expect(session,1,NO,@"A1 0A 01 18 F0 00 00");
    [app endPointerDrag]; Expect(session,2,NO,@"A1 0A 00 00 00 00 00");
    [app.pointerTimer invalidate];
    app.transport = [TransportWorker new];
    NSArray *expectedKeys = @[@"A1 01 00 00 28 00 00 00 00 00",@"A1 01 00 00 2B 00 00 00 00 00",@"A1 01 00 00 2A 00 00 00 00 00"];
    for (NSUInteger i = 0; i < expectedKeys.count; i++) {
        [session.packets removeAllObjects];
        [app.inputControls[i] performClick:nil];
        __block BOOL sent = NO;
        [app onTransport:^(AnikeySession *transport) { (void)transport; } completion:^{ sent = YES; }];
        NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 2;
        while (!sent && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.005);
        Check(sent && !app.busy && session.packets.count == 3,@"Native key button sends one neutral, one press and one release through the worker");
        Expect(session,0,NO,@"A1 01 00 00 00 00 00 00 00 00");
        Expect(session,1,NO,expectedKeys[i]);
        Expect(session,2,NO,@"A1 01 00 00 00 00 00 00 00 00");
    }
    [session.packets removeAllObjects]; session.keyDelayMS = 50;
    NSTimeInterval clickStart = NSProcessInfo.processInfo.systemUptime;
    for (NSUInteger i = 0; i < 3; i++) [app key:app.inputControls[i]];
    Check(NSProcessInfo.processInfo.systemUptime-clickStart < 0.05 && !app.busy,@"Rapid key clicks do not block AppKit or lock out the following click");
    __block BOOL burstSent = NO;
    [app onTransport:^(AnikeySession *transport) { (void)transport; } completion:^{ burstSent = YES; }];
    NSTimeInterval burstDeadline = NSProcessInfo.processInfo.systemUptime + 2;
    while (!burstSent && NSProcessInfo.processInfo.systemUptime < burstDeadline) Pump(0.005);
    Check(burstSent && session.packets.count == 9,@"All three quick clicks are preserved in order");
    for (NSUInteger i = 0; i < 3; i++) {
        Expect(session,i*3+1,NO,expectedKeys[i]);
        Expect(session,i*3+2,NO,@"A1 01 00 00 00 00 00 00 00 00");
    }
    [session.packets removeAllObjects];
    [app.transport perform:^{ Pump(0.1); }];
    [app key:app.inputControls[0]]; [app key:app.inputControls[1]];
    [app releaseInput];
    __block BOOL cancelled = NO;
    [app onTransport:^(AnikeySession *transport) { (void)transport; } completion:^{ cancelled = YES; }];
    burstDeadline = NSProcessInfo.processInfo.systemUptime + 2;
    while (!cancelled && NSProcessInfo.processInfo.systemUptime < burstDeadline) Pump(0.005);
    Check(cancelled && session.packets.count == 1,@"Focus loss discards queued button clicks and sends only a neutral release");
    Expect(session,0,NO,@"A1 01 00 00 00 00 00 00 00 00");
    __block BOOL drained = NO;
    [app onTransport:^(AnikeySession *transport) { (void)transport; [app.transport finish]; } completion:^{ drained = YES; }];
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 2;
    while ((!drained || app.transport.thread) && NSProcessInfo.processInfo.systemUptime < deadline) Pump(0.005);
    Check(drained && !app.transport.thread,@"Native key button worker shuts down");
    app.transport = nil;
    [session.packets removeAllObjects];
    NSPoint start = [app.cursorPad convertPoint:NSMakePoint(20,20) toView:nil];
    NSPoint end = [app.cursorPad convertPoint:NSMakePoint(50,40) toView:nil];
    NSEvent *press = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:start modifierFlags:0 timestamp:0 windowNumber:app.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
    NSEvent *move = [NSEvent mouseEventWithType:NSEventTypeMouseMoved location:end modifierFlags:0 timestamp:0 windowNumber:app.window.windowNumber context:nil eventNumber:1 clickCount:0 pressure:0];
    [app.cursorPad mouseMoved:move];
    Check(app.motion.x == 0 && app.motion.y == 0,@"Pad does not send motion before activation");
    session.mouseValidated = NO; [app refreshControls];
    [app.cursorPad mouseDown:press]; [app.cursorPad mouseDragged:move]; [app flushPointer:nil];
    Check(app.cursorPad.controlling && NSEqualPoints(app.cursorPad.lastPoint,NSMakePoint(50,40)),@"Local marker follows the drag during preview");
    Check(!session.packets.count && app.motion.x == 0,@"Preview never transmits movement");
    [app sendPointerButton:2]; Check(!session.packets.count,@"Calling secondary click cannot bypass mouse validation");
    [app.cursorPad mouseUp:press]; Check(app.cursorPad.controlling && !app.cursorPad.pressed,@"Mouse release clears click feedback while hover stays active");
    session.mouseValidated = YES; [app refreshControls]; // Test fixture only, never a production setting.
    [app resetPointer]; [app.cursorPad mouseEntered:press];
    Check(app.motion.x == 0,@"Entering the pad establishes an origin without a jump");
    [app.cursorPad mouseMoved:move]; [app flushPointer:nil];
    Expect(session,0,NO,@"A1 0A 00 1E 14 00 00");
    [app.cursorPad mouseDown:move]; [app.cursorPad mouseUp:move];
    Expect(session,1,NO,@"A1 0A 01 00 00 00 00"); Expect(session,2,NO,@"A1 0A 00 00 00 00 00");
    Check(session.packets.count == 3 && app.cursorPad.controlling && !app.cursorPad.pressed && !app.pointerButtons,@"Clicking and releasing the pad sends one complete tap");
    [app.cursorPad mouseDown:move]; [app.cursorPad mouseUp:move];
    Expect(session,3,NO,@"A1 0A 01 00 00 00 00"); Expect(session,4,NO,@"A1 0A 00 00 00 00 00");
    [app.cursorPad rightMouseDown:move];
    Expect(session,5,NO,@"A1 0A 02 00 00 00 00"); Expect(session,6,NO,@"A1 0A 00 00 00 00 00");
    [app.motion addX:12 y:-6]; [app sendPointerButton:1];
    Expect(session,7,NO,@"A1 0A 00 0C FA 00 00");
    Expect(session,8,NO,@"A1 0A 01 00 00 00 00"); Expect(session,9,NO,@"A1 0A 00 00 00 00 00");
    Check(app.motion.x == 0,@"A pad click finishes pending movement before pressing the mouse button");
    [app.motion addX:60 y:-40]; [app.cursorPad mouseExited:move]; [app flushPointer:nil];
    Check(!app.cursorPad.controlling && app.motion.x == 0 && session.packets.count == 10,@"Leaving the pad discards remaining motion");
    [app releaseInput];
    CheckBounds(app.window.contentView);
    [app.motion addWheel:12]; app.padSizeSlider.doubleValue = 0; [app resizePad:nil];
    Check(NSHeight(app.cursorPad.frame) == 104 && NSWidth(app.cursorPad.frame) == 360 && ![app.motion takeReport],@"Small pad size cancels pending input and fits its minimum area");
    app.padSizeSlider.doubleValue = 1; [app resizePad:nil]; Pump(0.05);
    Check(fabs(NSHeight(app.cursorPad.frame)-280) < 1 && fabs(NSWidth(app.cursorPad.frame)-580) < 1,
        [NSString stringWithFormat:@"Pad size slider expands its area (pad=%@, content=%@, frame=%@, screen=%@, slider=%.3f)",NSStringFromRect(app.cursorPad.frame),NSStringFromRect(app.window.contentView.bounds),NSStringFromRect(app.window.frame),NSStringFromRect(app.window.screen.visibleFrame),app.padSizeSlider.doubleValue]);
    [app.window setContentSize:NSMakeSize(800,720)];
    [app windowDidResize:[NSNotification notificationWithName:NSWindowDidResizeNotification object:app.window]];
    Check(NSWidth(app.cursorPad.frame) == 760 && NSHeight(app.cursorPad.frame) == 342,@"Window resizing expands the usable pad");
    CheckBounds(app.window.contentView);
    [app.window setContentSize:NSMakeSize(620,550)]; app.padSizeSlider.doubleValue = 0.35; [app resizePad:nil];
    CheckBounds(app.window.contentView);

    [app.connectionButton performClick:nil];
    Check(!session.ready && [app.connectionButton.title isEqual:@"Connect"],@"Disconnect returns to idle");
    NSUInteger count = session.packets.count;
    for (NSButton *button in app.inputControls) Check(!button.enabled,@"Disconnected inputs are disabled");
    [app physicalKey:0x00 down:YES flags:0]; Check(session.packets.count == count,@"Offline typing is not queued");
    NSView *view = app.window.contentView;
    NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
    Check([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:destination atomically:YES],@"Native window render saved");
    [app.pointerTimer invalidate]; [app.timer invalidate]; [NSEvent removeMonitor:app.eventMonitor]; [app.session stop]; [app.window orderOut:nil];
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 3 && strcmp(argv[1],"--ui-smoke") == 0) { UISmokeTest(@(argv[2])); PadGestureTests(); PadScrollResponsivenessTests(); PadScrollCompletionTests(); PadInteractionTests(); PadDragTests(); ResponsiveConnectionTest(); BoundedQuitTest(); }
        else { DescriptorTests(); MouseTests(); NavigationTests(); InputTests(); ProtocolTests(); ForwardingTests(); ConnectionLifecycleTests(); WorkerTests(); }
        printf("PASS: %u checks (no Bluetooth accessed)\n",Checks);
    }
    return 0;
}
