#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <Foundation/Foundation.h>

static void ZiHostLog(NSString *message) {
    fprintf(stderr, "[zi-webview-host] %s\n", message.UTF8String);
}

static NSString *ZiJSONString(id value) {
    if (!value) value = [NSNull null];
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingFragmentsAllowed error:&error];
    if (!data || error) return @"null";
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"null";
}

static void ZiWriteEvent(NSDictionary *event) {
    NSString *line = ZiJSONString(event);
    fprintf(stdout, "%s\n", line.UTF8String);
    fflush(stdout);
}

static NSString *ZiString(NSDictionary *dict, NSString *key) {
    id value = dict[key];
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSNumber *ZiNumber(NSDictionary *dict, NSString *key) {
    id value = dict[key];
    return [value isKindOfClass:NSNumber.class] ? value : nil;
}

static BOOL ZiBool(NSDictionary *dict, NSString *key, BOOL fallback) {
    NSNumber *value = ZiNumber(dict, key);
    return value ? value.boolValue : fallback;
}

static NSString *ZiJSONStringLiteral(NSString *value) {
    return ZiJSONString(value ?: @"");
}

static NSDictionary *ZiParseJSONLine(NSString *line) {
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return nil;
    NSError *error = nil;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![value isKindOfClass:NSDictionary.class]) return nil;
    return value;
}

static NSString *const ZiBridgeJS = @
"(() => {\n"
"  if (window.zi && window.zi.invoke) return;\n"
"  let nextId = 1;\n"
"  const pending = new Map();\n"
"  function post(obj) {\n"
"    window.webkit.messageHandlers.zi.postMessage(obj);\n"
"  }\n"
"  window.zi = {\n"
"    invoke(command, payload) {\n"
"      const id = String(nextId++);\n"
"      post({ type: 'invoke', id, command, payload: payload === undefined ? null : payload });\n"
"      return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));\n"
"    },\n"
"    close() { post({ type: 'close' }); },\n"
"    __resolve(id, ok, value) {\n"
"      const entry = pending.get(String(id));\n"
"      if (!entry) return;\n"
"      pending.delete(String(id));\n"
"      if (ok) entry.resolve(value); else entry.reject(value);\n"
"    }\n"
"  };\n"
"})();\n";

@interface ZiWebViewHost : NSObject <NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate>
@property(nonatomic, copy) NSString *windowId;
@property(nonatomic, copy) NSString *title;
@property(nonatomic) NSInteger width;
@property(nonatomic) NSInteger height;
@property(nonatomic) BOOL floating;
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic) BOOL emittedClosed;
@end

@implementation ZiWebViewHost

- (instancetype)initWithArguments:(NSArray<NSString *> *)args {
    self = [super init];
    if (!self) return nil;
    _windowId = @"main";
    _title = @"zi";
    _width = 800;
    _height = 600;
    _floating = NO;
    for (NSUInteger i = 1; i < args.count; i++) {
        NSString *arg = args[i];
        if ([arg isEqualToString:@"--id"] && i + 1 < args.count) {
            _windowId = args[++i];
        } else if ([arg isEqualToString:@"--title"] && i + 1 < args.count) {
            _title = args[++i];
        } else if ([arg isEqualToString:@"--width"] && i + 1 < args.count) {
            _width = MAX(1, args[++i].integerValue);
        } else if ([arg isEqualToString:@"--height"] && i + 1 < args.count) {
            _height = MAX(1, args[++i].integerValue);
        } else if ([arg isEqualToString:@"--floating"]) {
            _floating = YES;
        }
    }
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self setupWindow];
    [self setupWebView];
    [self startStdinReader];
}

- (void)setupWindow {
    NSRect rect = NSMakeRect(0, 0, self.width, self.height);
    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    self.window = [[NSWindow alloc] initWithContentRect:rect styleMask:style backing:NSBackingStoreBuffered defer:NO];
    self.window.title = self.title;
    self.window.delegate = self;
    if (self.floating) self.window.level = NSFloatingWindowLevel;
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (WKWebViewConfiguration *)webViewConfiguration {
    WKUserContentController *controller = [[WKUserContentController alloc] init];
    WKUserScript *script = [[WKUserScript alloc] initWithSource:ZiBridgeJS injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES];
    [controller addUserScript:script];
    [controller addScriptMessageHandler:self name:@"zi"];
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.userContentController = controller;
    return config;
}

- (void)setupWebView {
    self.webView = [[WKWebView alloc] initWithFrame:self.window.contentView.bounds configuration:[self webViewConfiguration]];
    self.webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.webView.navigationDelegate = self;
    [self.window.contentView addSubview:self.webView];
    [self.webView loadHTMLString:@"<html><body></body></html>" baseURL:nil];
}

- (void)startStdinReader {
    __weak ZiWebViewHost *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char *raw = NULL;
        size_t cap = 0;
        while (getline(&raw, &cap, stdin) != -1) {
            @autoreleasepool {
                NSString *line = [[NSString alloc] initWithUTF8String:raw];
                line = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (line.length == 0) continue;
                NSDictionary *command = ZiParseJSONLine(line);
                if (!command) {
                    ZiWriteEvent(@{ @"type": @"error", @"window_id": weakSelf.windowId ?: @"main", @"message": @"invalid JSON command" });
                    continue;
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf handleCommand:command];
                });
            }
        }
        if (raw) free(raw);
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf closeAndExit];
        });
    });
}

- (void)handleCommand:(NSDictionary *)command {
    NSString *type = ZiString(command, @"type");
    if (!type) {
        [self emitError:@"missing command type"];
        return;
    }
    if ([type isEqualToString:@"html"]) {
        NSString *base64 = ZiString(command, @"html_base64");
        NSData *data = base64 ? [[NSData alloc] initWithBase64EncodedString:base64 options:0] : nil;
        NSString *html = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        if (!html) { [self emitError:@"html command requires base64 html_base64"]; return; }
        [self.webView loadHTMLString:html baseURL:nil];
    } else if ([type isEqualToString:@"file"]) {
        NSString *path = ZiString(command, @"path");
        NSString *readRoot = ZiString(command, @"read_root");
        if (!path || !readRoot) { [self emitError:@"file command requires path and read_root"]; return; }
        NSURL *fileURL = [NSURL fileURLWithPath:path];
        NSURL *rootURL = [NSURL fileURLWithPath:readRoot isDirectory:YES];
        [self.webView loadFileURL:fileURL allowingReadAccessToURL:rootURL];
    } else if ([type isEqualToString:@"eval"]) {
        NSString *js = ZiString(command, @"js");
        if (!js) { [self emitError:@"eval command requires js"]; return; }
        [self.webView evaluateJavaScript:js completionHandler:nil];
    } else if ([type isEqualToString:@"bridge_response"]) {
        [self handleBridgeResponse:command];
    } else if ([type isEqualToString:@"close"]) {
        [self closeAndExit];
    } else {
        [self emitError:[NSString stringWithFormat:@"unknown command type: %@", type]];
    }
}

- (void)handleBridgeResponse:(NSDictionary *)command {
    NSString *bridgeId = ZiString(command, @"id");
    if (!bridgeId) { [self emitError:@"bridge_response requires id"]; return; }
    BOOL ok = ZiBool(command, @"ok", NO);
    id value = command[@"result"] ?: command[@"error"] ?: [NSNull null];
    NSString *js = [NSString stringWithFormat:@"window.zi&&window.zi.__resolve(%@,%@,%@)", ZiJSONStringLiteral(bridgeId), ok ? @"true" : @"false", ZiJSONString(value)];
    [self.webView evaluateJavaScript:js completionHandler:nil];
}

- (void)emitReady {
    ZiWriteEvent(@{ @"type": @"ready", @"window_id": self.windowId });
}

- (void)emitError:(NSString *)message {
    ZiWriteEvent(@{ @"type": @"error", @"window_id": self.windowId, @"message": message ?: @"unknown error" });
}

- (void)closeAndExit {
    if (self.emittedClosed) return;
    self.emittedClosed = YES;
    ZiWriteEvent(@{ @"type": @"closed", @"window_id": self.windowId });
    [NSApp terminate:nil];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [self emitReady];
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    id body = message.body;
    if (![body isKindOfClass:NSDictionary.class]) {
        [self emitError:@"invalid bridge message body"];
        return;
    }
    NSDictionary *dict = body;
    NSString *type = ZiString(dict, @"type");
    if ([type isEqualToString:@"close"]) {
        [self closeAndExit];
        return;
    }
    if (![type isEqualToString:@"invoke"]) {
        [self emitError:@"unknown bridge message type"];
        return;
    }
    NSString *bridgeId = ZiString(dict, @"id");
    NSString *command = ZiString(dict, @"command");
    if (!bridgeId || !command) {
        [self emitError:@"bridge invoke requires id and command"];
        return;
    }
    id payload = dict[@"payload"] ?: [NSNull null];
    ZiWriteEvent(@{
        @"type": @"bridge",
        @"window_id": self.windowId,
        @"id": bridgeId,
        @"command": command,
        @"payload": payload,
    });
}

- (void)windowWillClose:(NSNotification *)notification {
    [self closeAndExit];
}

@end

int zi_webview_host_main(void) {
    @autoreleasepool {
        NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
        NSApplication *app = NSApplication.sharedApplication;
        ZiWebViewHost *delegate = [[ZiWebViewHost alloc] initWithArguments:args];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
        (void)delegate;
    }
    return 0;
}
