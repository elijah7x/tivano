// Build only on the lead host; see README.md. No target-process code is called.
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <libproc.h>
#import <sys/proc_info.h>
#import <time.h>
#import <unistd.h>

static double stamp(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static void emit(NSDictionary *record) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
    fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); fflush(stdout);
}
static int blocked(NSString *reason) {
    emit(@{@"kind": @"blocked", @"monotonicSeconds": @(stamp()), @"reason": reason});
    return 2;
}
static id attr(AXUIElementRef element, CFStringRef name) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, name, &value) != kAXErrorSuccess) return nil;
    return CFBridgingRelease(value);
}
static BOOL axRect(AXUIElementRef element, CGRect *rect) {
    id p = attr(element, kAXPositionAttribute), s = attr(element, kAXSizeAttribute);
    if (!p || !s || CFGetTypeID((__bridge CFTypeRef)p) != AXValueGetTypeID() ||
        CFGetTypeID((__bridge CFTypeRef)s) != AXValueGetTypeID()) return NO;
    CGPoint point; CGSize size;
    if (!AXValueGetValue((__bridge AXValueRef)p, kAXValueCGPointType, &point) ||
        !AXValueGetValue((__bridge AXValueRef)s, kAXValueCGSizeType, &size)) return NO;
    *rect = (CGRect){point, size}; return YES;
}
static NSString *guardWindow(pid_t pid, NSDictionary *report, CGRect relativeRegion) {
    NSDictionary *state = report[@"windowState"];
    if (![state[@"appActive"] boolValue] || ![state[@"keyWindow"] boolValue] ||
        ![state[@"occlusionVisible"] boolValue] || ![state[@"interruption"] isEqual:@"none"])
        return @"probe foreground/window guard unavailable";
    if (NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != pid)
        return @"test PID is not frontmost";
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    CGEventRef cursor = CGEventCreate(NULL);
    if (!cursor) return @"cursor unavailable";
    CGPoint point = CGEventGetLocation(cursor); CFRelease(cursor);
    NSDictionary *target = nil;
    for (NSDictionary *w in windows) {
        CGRect r;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds], &r)) continue;
        if ([w[(id)kCGWindowAlpha] doubleValue] <= 0 || !CGRectContainsPoint(r, point)) continue;
        // Dock reports full-display bounds even over pass-through pixels. Require the
        // exact system Dock/layer/rectangle here; the AX hit/window proof below still applies.
        NSRunningApplication *owner = [NSRunningApplication runningApplicationWithProcessIdentifier:[w[(id)kCGWindowOwnerPID] intValue]];
        if ([owner.executableURL.path isEqual:@"/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"] &&
            [w[(id)kCGWindowLayer] intValue] == 20 && CGRectEqualToRect(r, CGDisplayBounds(CGMainDisplayID()))) {
            static BOOL recorded = NO;
            if (!recorded) {
                emit(@{@"kind": @"system-dock-bounds-deferred-to-AX", @"window": w[(id)kCGWindowNumber]});
                recorded = YES;
            }
            continue;
        }
        if ([w[(id)kCGWindowOwnerPID] intValue] != pid ||
            ![w[(id)kCGWindowNumber] isEqual:state[@"captureWindowNumber"]]) return @"cursor covered by another window";
        target = w; break;
    }
    if (!target) return @"target window not under cursor";
    CGRect bounds;
    if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)target[(id)kCGWindowBounds], &bounds) ||
        bounds.size.width != 1200 || bounds.size.height != 800) return @"unexpected window bounds";
    CGRect region = CGRectOffset(relativeRegion, bounds.origin.x, bounds.origin.y);
    if (!CGRectContainsRect(bounds, region) || !CGRectContainsPoint(region, point)) return @"cursor outside operator-attested timeline region";
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    id focused = attr(app, kAXFocusedWindowAttribute);
    CGRect focusedRect;
    BOOL focusedOK = focused && axRect((__bridge AXUIElementRef)focused, &focusedRect) && CGRectEqualToRect(bounds, focusedRect);
    CFRelease(app);
    if (!focusedOK) return @"focused AX window does not match capture window";
    AXUIElementRef system = AXUIElementCreateSystemWide(), hit = NULL;
    AXError error = AXUIElementCopyElementAtPosition(system, point.x, point.y, &hit);
    CFRelease(system);
    if (error != kAXErrorSuccess || !hit) return @"AX hit test unavailable";
    BOOL scrollFound = NO, windowFound = NO;
    NSMutableArray *ancestry = [NSMutableArray array];
    for (int depth = 0; hit && depth < 64; depth++) {
        pid_t owner = 0;
        if (AXUIElementGetPid(hit, &owner) != kAXErrorSuccess || owner != pid) break;
        NSString *role = attr(hit, kAXRoleAttribute);
        CGRect r;
        [ancestry addObject:@{@"role": role ?: @"missing", @"hasBounds": @(axRect(hit, &r)),
                              @"bounds": axRect(hit, &r) ? NSStringFromRect(NSRectFromCGRect(r)) : @"missing",
                              @"focusedWindow": @(CFEqual(hit, (__bridge CFTypeRef)focused))}];
        if ([role isEqual:(__bridge NSString *)kAXScrollAreaRole] && axRect(hit, &r) &&
            r.size.width > 400 && r.size.height > 120 && CGRectContainsRect(r, region)) scrollFound = YES;
        if (CFEqual(hit, (__bridge CFTypeRef)focused)) { windowFound = YES; break; }
        id parent = attr(hit, kAXParentAttribute);
        CFRelease(hit); hit = parent ? (AXUIElementRef)CFRetain((__bridge CFTypeRef)parent) : NULL;
    }
    if (hit) CFRelease(hit);
    if (!scrollFound || !windowFound) emit(@{@"kind": @"AX-routing-blocked", @"ancestry": ancestry});
    return scrollFound && windowFound ? nil : @"no reliable timeline AX scroll-area ancestry; do not guess coordinates";
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (!AXIsProcessTrusted() || !CGPreflightPostEventAccess() || !CGPreflightScreenCaptureAccess())
            return blocked(@"Accessibility, event-posting or Screen Recording permission missing; grant manually, never by this helper");
        if (argc == 2 && strcmp(argv[1], "--preflight") == 0) { emit(@{@"kind": @"permissions-present"}); return 0; }
        if (argc != 8) return blocked(@"expected PID executable report x y width height");
        pid_t pid = (pid_t)strtol(argv[1], NULL, 10);
        NSString *executable = @(argv[2]), *reportPath = @(argv[3]);
        CGRect region = CGRectMake(atof(argv[4]), atof(argv[5]), atof(argv[6]), atof(argv[7]));
        if (pid <= 1 || region.size.width <= 0 || region.size.height <= 0) return blocked(@"invalid target");
        struct proc_bsdinfo identity = {0};
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &identity, sizeof(identity)) != sizeof(identity)) return blocked(@"initial process identity unavailable");
        double start = stamp(), previous = start;
        BOOL sawReport = NO;
        unsigned long events = 0;
        while (stamp() - start < 140) {
            @autoreleasepool {
                double now = stamp();
                NSData *terminalData = [NSData dataWithContentsOfFile:reportPath];
                id terminal = terminalData ? [NSJSONSerialization JSONObjectWithData:terminalData options:0 error:nil] : nil;
                // The probe terminates immediately after its atomic final report; no post-exit RSS is invented.
                if (sawReport && [terminal isKindOfClass:NSDictionary.class] &&
                    [terminal[@"pid"] intValue] == pid && [terminal[@"status"] isEqual:@"completed"]) {
                    emit(@{@"kind": @"completed", @"monotonicSeconds": @(now), @"injectedEvents": @(events),
                           @"reason": @"terminal report observed; resource series ends at last live sample"}); return 0;
                }
                struct proc_bsdinfo bsd = {0}; struct proc_taskinfo task = {0};
                char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
                if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd)) != sizeof(bsd) ||
                    bsd.pbi_start_tvsec != identity.pbi_start_tvsec || bsd.pbi_start_tvusec != identity.pbi_start_tvusec ||
                    proc_pidpath(pid, path, sizeof(path)) <= 0 || ![executable isEqual:@(path)])
                    return blocked(@"process exited or identity changed before terminal report");
                if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, sizeof(task)) != sizeof(task)) return blocked(@"RSS/CPU sampling failed");
                NSData *data = [NSData dataWithContentsOfFile:reportPath];
                NSDictionary *report = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                if (report && ![report isKindOfClass:NSDictionary.class]) return blocked(@"invalid report");
                if (report && [report[@"pid"] intValue] != pid) return blocked(@"report PID mismatch");
                if (sawReport && !report) return blocked(@"report missing after first observation");
                sawReport |= report != nil;
                NSMutableArray *running = [NSMutableArray array];
                for (NSDictionary *phase in report[@"phases"]) if ([phase[@"status"] isEqual:@"running"]) [running addObject:phase[@"name"]];
                if (running.count > 1) return blocked(@"ambiguous phase");
                NSString *phase = running.firstObject ?: @"outside-observed-running-phase";
                emit(@{@"kind": @"sample", @"monotonicSeconds": @(now), @"actualIntervalSeconds": @(now - previous),
                       @"pid": @(pid), @"processStartSeconds": @(bsd.pbi_start_tvsec), @"processStartMicroseconds": @(bsd.pbi_start_tvusec),
                       @"rssBytes": @(task.pti_resident_size), @"cpuUserNanoseconds": @(task.pti_total_user),
                       @"cpuSystemNanoseconds": @(task.pti_total_system), @"observedPhase": phase,
                       @"reportElapsedSeconds": report[@"elapsedSeconds"] ?: NSNull.null,
                       @"reportPhaseLog": report[@"phaseLog"] ?: @[], @"injectedEvents": @(events)});
                previous = now;
                if (report && ![report[@"status"] isEqual:@"running"]) {
                    if (![report[@"status"] isEqual:@"completed"]) return blocked(@"probe blocked/failed");
                    emit(@{@"kind": @"completed", @"monotonicSeconds": @(stamp()), @"injectedEvents": @(events)}); return 0;
                }
                // Idle phases remain untouched. Existing probe requires accepted wheel input during load.
                if ([phase isEqual:@"three-thread-load"]) {
                    if (!AXIsProcessTrusted() || !CGPreflightPostEventAccess() || !CGPreflightScreenCaptureAccess())
                        return blocked(@"input/observation permission lost");
                    NSString *problem = guardWindow(pid, report, region);
                    if (problem) return blocked(problem);
                    int delta = ((int)((now - start) / 1.0) % 2 == 0) ? 24 : -24;
                    CGEventRef event = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 1, delta);
                    if (!event) return blocked(@"scroll event creation failed");
                    CGEventRef cursor = CGEventCreate(NULL);
                    if (!cursor) { CFRelease(event); return blocked(@"cursor unavailable before post"); }
                    CGEventSetLocation(event, CGEventGetLocation(cursor)); CFRelease(cursor);
                    problem = guardWindow(pid, report, region);
                    if (problem) { CFRelease(event); return blocked(problem); }
                    // Session event stream, not a direct handler call or scroll-offset write.
                    CGEventPost(kCGHIDEventTap, event); CFRelease(event); events++;
                    emit(@{@"kind": @"injected-system-wheel", @"monotonicSeconds": @(stamp()), @"deltaPixels": @(delta), @"pid": @(pid)});
                }
                usleep(100000);
            }
        }
        return blocked(@"140 second helper deadline");
    }
}
