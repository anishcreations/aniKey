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
    if ((self = [super init])) { self.ready = YES; self.dryRun = YES; self.keyDelayMS = 0; self.packets = [NSMutableArray array]; self.failAt = -1; }
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
@property (strong) IOBluetoothDevice *device;
@property (strong) id retainedDelegate;
@property NSUInteger closes;
- (IOReturn)setDelegate:(id)delegate;
- (IOReturn)closeChannel;
@end
@implementation MockChannel
- (IOReturn)setDelegate:(id)delegate { self.retainedDelegate = delegate; return kIOReturnSuccess; }
- (IOReturn)closeChannel { self.closes++; return kIOReturnSuccess; }
@end
@interface MockOpenDevice : NSObject
@property (strong) MockChannel *channel;
@property IOReturn result;
@property BOOL earlyData, earlyCompletion, omitChannel;
- (IOReturn)openL2CAPChannelSync:(IOBluetoothL2CAPChannel **)channel withPSM:(BluetoothL2CAPPSM)psm delegate:(AnikeySession *)delegate;
@end
@implementation MockOpenDevice
- (IOReturn)openL2CAPChannelSync:(IOBluetoothL2CAPChannel **)channel withPSM:(BluetoothL2CAPPSM)psm delegate:(AnikeySession *)delegate {
    self.channel.PSM = psm; self.channel.device = (IOBluetoothDevice *)self;
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
    unsigned bits[4][3] = {{0}}; // report ID × Input/Output/Feature
    BOOL keyboardArray = NO, modifierBits = NO, ledBits = NO;
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
            if (tag == 8) { reportID = value; Check(reportID == 1,@"Only report ID 1 is declared"); }
            if (tag == 9) count = value;
        } else if (type == 0) {
            if (tag == 10) depth++;
            else if (tag == 12) { Check(depth > 0,@"Collection end is balanced"); depth--; }
            else if (tag == 8 || tag == 9 || tag == 11) {
                Check(reportID == 1, @"Main item has a report ID");
                unsigned direction = tag == 8 ? 0 : tag == 9 ? 1 : 2;
                bits[reportID][direction] += size*count;
                if (reportID == 1 && direction == 0 && size == 8 && count == 6 && value == 0 && usagePage == 7) keyboardArray = YES;
                if (reportID == 1 && direction == 0 && size == 1 && count == 8 && value == 2) modifierBits = YES;
                if (reportID == 1 && direction == 1 && size == 1 && count == 5 && usagePage == 8) ledBits = YES;
            }
        }
    }
    Check(depth == 0,@"All collections close");
    Check(bits[1][0] == 64 && bits[1][1] == 8 && bits[2][0] == 0 && bits[3][0] == 0,@"Only keyboard input and LEDs are advertised");
    Check(keyboardArray && modifierBits && ledBits,@"Descriptor defines keyboard modifiers, usages and LEDs");
    TestSession *session = [TestSession new];
    Check(![session sendReport:2 payload:ParseHex(@"00 00 00 00")] && ![session sendReport:3 payload:ParseHex(@"00 00")] && !session.packets.count,@"Removed report IDs cannot emit packets");
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
    Check([[[record getAttributeDataElement:0x0202] getNumberValue] unsignedIntValue] == 0x40,@"SDP identifies only a keyboard");
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
    attributes[@0x0206] = [IOBluetoothSDPDataElement withElementValue:@[@[SDPNumber(0x22,1),@{@"DataElementType":@4,@"DataElementValue":ParseHex(@"05 0C") }]]];
    record = [IOBluetoothSDPServiceRecord withServiceDictionary:attributes device:nil];
    Check(!ServiceHasExpectedDescriptor(record),@"Publication guard rejects a different consumer-only layout");
    Check(!ServiceHasExpectedDescriptor(nil),@"Publication guard rejects a missing record");
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
    [session handlePacket:ParseHex(@"41 02") control:YES]; Expect(session,4,YES,@"02");
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
    Check(app.inputControls.count == 5,@"Only four basic keys and clipboard typing appear");
    Check(session.connectCount == 0 && app.connectionButton.enabled,@"Startup stays idle with manual Connect");
    [app.connectionButton performClick:nil];
    Check(session.ready && session.connectCount == 1 && [app.connectionButton.title isEqual:@"Disconnect"],@"Connect performs exactly one attempt");
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
    [app.timer invalidate]; [NSEvent removeMonitor:app.eventMonitor]; [app.session stop]; [app.window orderOut:nil];
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 3 && strcmp(argv[1],"--ui-smoke") == 0) { UISmokeTest(@(argv[2])); ResponsiveConnectionTest(); BoundedQuitTest(); }
        else { DescriptorTests(); InputTests(); ProtocolTests(); ForwardingTests(); ConnectionLifecycleTests(); WorkerTests(); }
        printf("PASS: %u checks (no Bluetooth accessed)\n",Checks);
    }
    return 0;
}
