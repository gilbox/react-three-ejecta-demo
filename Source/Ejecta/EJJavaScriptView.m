#import "EJJavaScriptView.h"
#import "EJTimer.h"
#import "EJBindingBase.h"
#import "EJClassLoader.h"
#import <objc/runtime.h>


// Block function callbacks
JSValueRef EJBlockFunctionCallAsFunction(
	JSContextRef ctx, JSObjectRef function, JSObjectRef thisObject, size_t argc, const JSValueRef argv[], JSValueRef* exception
) {
	JSValueRef (^block)(JSContextRef ctx, size_t argc, const JSValueRef argv[]) = JSObjectGetPrivate(function);
	JSValueRef ret = block(ctx, argc, argv);
	return ret ? ret : JSValueMakeUndefined(ctx);
}

void EJBlockFunctionFinalize(JSObjectRef object) {
	JSValueRef (^block)(JSContextRef ctx, size_t argc, const JSValueRef argv[]) = JSObjectGetPrivate(object);
	[block release];
}


#pragma mark -
#pragma mark Ejecta view Implementation

@implementation EJJavaScriptView

@synthesize appFolder;

@synthesize pauseOnEnterBackground;
@synthesize isPaused;
@synthesize hasScreenCanvas;
@synthesize jsGlobalContext;
@synthesize exitOnMenuPress;

@synthesize currentRenderingContext;
@synthesize openGLContext;

@synthesize windowEventsDelegate;
@synthesize touchDelegate;
@synthesize deviceMotionDelegate;
@synthesize screenRenderingContext;

@synthesize backgroundQueue;
@synthesize classLoader;

- (id)initWithFrame:(CGRect)frame {
	return [self initWithFrame:frame appFolder:EJECTA_DEFAULT_APP_FOLDER];
}

- (id)initWithFrame:(CGRect)frame appFolder:(NSString *)folder {
	if( self = [super initWithFrame:frame] ) {
        [self setupWithAppFolder:folder];
	}
	return self;
}

-(void)awakeFromNib {
    [self setupWithAppFolder:EJECTA_DEFAULT_APP_FOLDER];
}

-(void)setupWithAppFolder:(NSString*)folder {
    oldSize = self.frame.size;
    appFolder = [folder retain];
    
    isPaused = false;
	exitOnMenuPress = true;
    
    // CADisplayLink (and NSNotificationCenter?) retains it's target, but this
    // is causing a retain loop - we can't completely release the scriptView
    // from the outside.
    // So we're using a "weak proxy" that doesn't retain the scriptView; we can
    // then just invalidate the CADisplayLink in our dealloc and be done with it.
    proxy = [[EJNonRetainingProxy proxyWithTarget:self] retain];
    
    self.pauseOnEnterBackground = YES;
    
    // Limit all background operations (image & sound loading) to one thread
    backgroundQueue = [[NSOperationQueue alloc] init];
    backgroundQueue.maxConcurrentOperationCount = 1;
    
    timers = [[EJTimerCollection alloc] initWithScriptView:self];
    
    displayLink = [[CADisplayLink displayLinkWithTarget:proxy selector:@selector(run:)] retain];
    [displayLink setFrameInterval:1];
    [displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    
    // Create the global JS context in its own group, so it can be released properly
    jsGlobalContext = JSGlobalContextCreateInGroup(NULL, NULL);
    jsUndefined = JSValueMakeUndefined(jsGlobalContext);
    JSValueProtect(jsGlobalContext, jsUndefined);
    
    // Attach all native class constructors to 'Ejecta'
    classLoader = [[EJClassLoader alloc] initWithScriptView:self name:@"Ejecta"];
    
    
    // Retain the caches here, so even if they're currently unused in JavaScript,
    // they will persist until the last scriptView is released
    textureCache = [[EJSharedTextureCache instance] retain];
    openALManager = [[EJSharedOpenALManager instance] retain];
    openGLContext = [[EJSharedOpenGLContext instance] retain];
    
    // Create the OpenGL context for Canvas2D
    glCurrentContext = openGLContext.glContext2D;
    [EAGLContext setCurrentContext:glCurrentContext];
    
    [self loadScriptAtPath:EJECTA_BOOT_JS];
}

- (void)dealloc {
	// Wait until all background operations are finished. If we would just release the
	// backgroundQueue it would cancel running operations (such as texture loading) and
	// could keep some dependencies dangling
	[backgroundQueue waitUntilAllOperationsAreFinished];
	[backgroundQueue release];
	
	// Careful, order is important! The JS context has to be released first; it will release
	// the canvas objects which still need the openGLContext to be present, to release
	// textures etc.
	// Set 'jsGlobalContext' to null before releasing it, because it may be referenced by
	// bound objects' dealloc method
	JSValueUnprotect(jsGlobalContext, jsUndefined);
	JSGlobalContextRef ctxref = jsGlobalContext;
	jsGlobalContext = NULL;
	JSGlobalContextRelease(ctxref);
	
	// Remove from notification center
	self.pauseOnEnterBackground = false;
	
	// Remove from display link
	[displayLink invalidate];
	[displayLink release];
	
	[textureCache release];
	[openALManager release];
	[classLoader release];
	
	if( jsBlockFunctionClass ) {
		JSClassRelease(jsBlockFunctionClass);
	}
	[screenRenderingContext finish];
	[screenRenderingContext release];
	[currentRenderingContext release];
	
	[touchDelegate release];
	[windowEventsDelegate release];
	[deviceMotionDelegate release];
	
	[timers release];
	
	[openGLContext release];
	[appFolder release];
	[proxy release];
	[super dealloc];
}

- (void)setPauseOnEnterBackground:(BOOL)pauses {
	NSArray *pauseN = @[
		UIApplicationWillResignActiveNotification,
		UIApplicationDidEnterBackgroundNotification,
		UIApplicationWillTerminateNotification
	];
	NSArray *resumeN = @[
		UIApplicationWillEnterForegroundNotification,
		UIApplicationDidBecomeActiveNotification
	];
	
	if (pauses) {
		[self observeKeyPaths:pauseN selector:@selector(pause)];
		[self observeKeyPaths:resumeN selector:@selector(resume)];
	} 
	else {
		[self removeObserverForKeyPaths:pauseN];
		[self removeObserverForKeyPaths:resumeN];
	}
	pauseOnEnterBackground = pauses;
}

- (void)removeObserverForKeyPaths:(NSArray*)keyPaths {
	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	for( NSString *name in keyPaths ) {
		[nc removeObserver:proxy name:name object:nil];
	}
}

- (void)observeKeyPaths:(NSArray*)keyPaths selector:(SEL)selector {
	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	for( NSString *name in keyPaths ) {
		[nc addObserver:proxy selector:selector name:name object:nil];
	}
}

- (void)layoutSubviews {
	[super layoutSubviews];
	
	// Check if we did resize
	CGSize newSize = self.bounds.size;
	if( newSize.width != oldSize.width || newSize.height != oldSize.height ) {
		[windowEventsDelegate resize];
		oldSize = newSize;
	}
}


#pragma mark -
#pragma mark Script loading and execution

- (NSString *)pathForResource:(NSString *)path {
	char specialPathName[16];
	if( sscanf(path.UTF8String, "${%15[^}]", specialPathName) ) {
		NSString *searchPath;
		if( strcmp(specialPathName, "Documents") == 0 ) {
			searchPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
		}
		else if( strcmp(specialPathName, "Library") == 0 ) {
			searchPath = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES)[0];
		}
		else if( strcmp(specialPathName, "Caches") == 0 ) {
			searchPath = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES)[0];
		}
		else if( strcmp(specialPathName, "tmp") == 0 ) {
			searchPath = NSTemporaryDirectory();
		}
		
		if( searchPath ) {
			return [searchPath stringByAppendingPathComponent:[path substringFromIndex:strlen(specialPathName)+3]];
		}
	}
	
	return [NSString stringWithFormat:@"%@/%@%@", NSBundle.mainBundle.resourcePath, appFolder, path];
}

- (void)loadScriptAtPath:(NSString *)path {
	NSString *script = [NSString stringWithContentsOfFile:[self pathForResource:path]
		encoding:NSUTF8StringEncoding error:NULL];
	
	[self evaluateScript:script sourceURL:path];
}

- (JSValueRef)evaluateScript:(NSString *)script {
	return [self evaluateScript:script sourceURL:NULL];
}

- (JSValueRef)evaluateScript:(NSString *)script sourceURL:(NSString *)sourceURL {
	if( !script || script.length == 0 ) {
		NSLog(
			@"Error: The script %@ does not exist or appears to be empty.",
			sourceURL ? sourceURL : @"[Anonymous]"
		);
		return NULL;
	}
    
	JSStringRef scriptJS = JSStringCreateWithCFString((CFStringRef)script);
	JSStringRef sourceURLJS = NULL;
    
	if( [sourceURL length] > 0 ) {
		sourceURLJS = JSStringCreateWithCFString((CFStringRef)sourceURL);
	}
    
	JSValueRef exception = NULL;
	JSValueRef ret = JSEvaluateScript(jsGlobalContext, scriptJS, NULL, sourceURLJS, 0, &exception );
	[self logException:exception ctx:jsGlobalContext];
	
	JSStringRelease( scriptJS );
    
	if ( sourceURLJS ) {
		JSStringRelease( sourceURLJS );
	}
	return ret;
}

- (JSValueRef)loadModuleWithId:(NSString *)moduleId module:(JSValueRef)module exports:(JSValueRef)exports {
	NSString *path = [moduleId stringByAppendingString:@".js"];
	NSString *script = [NSString stringWithContentsOfFile:[self pathForResource:path]
		encoding:NSUTF8StringEncoding error:NULL];
	
	if( !script ) {
		NSLog(@"Error: Can't Find Module %@", moduleId );
		return NULL;
	}
	
	NSLog(@"Loading Module: %@", moduleId );
	
	JSStringRef scriptJS = JSStringCreateWithCFString((CFStringRef)script);
	JSStringRef pathJS = JSStringCreateWithCFString((CFStringRef)path);
	JSStringRef parameterNames[] = {
		JSStringCreateWithUTF8CString("module"),
		JSStringCreateWithUTF8CString("exports"),
	};
	
	JSValueRef exception = NULL;
	JSObjectRef func = JSObjectMakeFunction(jsGlobalContext, NULL, 2, parameterNames, scriptJS, pathJS, 0, &exception );
	
	JSStringRelease( scriptJS );
	JSStringRelease( pathJS );
	JSStringRelease(parameterNames[0]);
	JSStringRelease(parameterNames[1]);
	
	if( exception ) {
		[self logException:exception ctx:jsGlobalContext];
		return NULL;
	}
	
	JSValueRef params[] = { module, exports };
	return [self invokeCallback:func thisObject:NULL argc:2 argv:params];
}

- (JSValueRef)invokeCallback:(JSObjectRef)callback thisObject:(JSObjectRef)thisObject argc:(size_t)argc argv:(const JSValueRef [])argv {
	if( !jsGlobalContext ) { return NULL; } // May already have been released
	
	JSValueRef exception = NULL;
	JSValueRef result = JSObjectCallAsFunction(jsGlobalContext, callback, thisObject, argc, argv, &exception );
	[self logException:exception ctx:jsGlobalContext];
	return result;
}

- (void)logException:(JSValueRef)exception ctx:(JSContextRef)ctxp {
	if( !exception ) { return; }
	
	JSStringRef jsLinePropertyName = JSStringCreateWithUTF8CString("line");
	JSStringRef jsFilePropertyName = JSStringCreateWithUTF8CString("sourceURL");
	
	JSObjectRef exObject = JSValueToObject( ctxp, exception, NULL );
	JSValueRef line = JSObjectGetProperty( ctxp, exObject, jsLinePropertyName, NULL );
	JSValueRef file = JSObjectGetProperty( ctxp, exObject, jsFilePropertyName, NULL );
	
	NSLog(
		@"%@ at line %@ in %@",
		JSValueToNSString( ctxp, exception ),
		JSValueToNSString( ctxp, line ),
		JSValueToNSString( ctxp, file )
	);
	
	JSStringRelease( jsLinePropertyName );
	JSStringRelease( jsFilePropertyName );
}

- (JSValueRef)jsValueForPath:(NSString *)objectPath {
	JSValueRef obj = JSContextGetGlobalObject( jsGlobalContext  );
	
	NSArray *pathComponents = [objectPath componentsSeparatedByString:@"."];
	for( NSString *p in pathComponents) {
		JSStringRef name = JSStringCreateWithCFString((CFStringRef)p);
		obj = JSObjectGetProperty( jsGlobalContext, (JSObjectRef)obj, name, NULL);
		JSStringRelease(name);
		
		if( !obj ) { break; }
	}
	return obj;
}


#pragma mark -
#pragma mark Run loop

- (void)run:(CADisplayLink *)sender {
	if(isPaused) { return; }
	
	// We rather poll for device motion updates at the beginning of each frame instead of
	// spamming out updates that will never be seen.
	[deviceMotionDelegate triggerDeviceMotionEvents];
	
	// Check all timers
	[timers update];
	
	// Redraw the canvas
	self.currentRenderingContext = screenRenderingContext;
	[screenRenderingContext present];
}


- (void)pause {
	if( isPaused ) { return; }
	
	[windowEventsDelegate pause];
	[displayLink removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
	[screenRenderingContext finish];
	isPaused = true;
}

- (void)resume {
	if( !isPaused ) { return; }
	
	[windowEventsDelegate resume];
	[EAGLContext setCurrentContext:glCurrentContext];
	[displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
	isPaused = false;
}

- (void)clearCaches {
	JSGarbageCollect(jsGlobalContext);
	
	// Release all texture storages that haven't been bound in
	// the last 5 seconds
	[textureCache releaseStoragesOlderThan:5];
}

- (void)setCurrentRenderingContext:(EJCanvasContext *)renderingContext {
	if( renderingContext != currentRenderingContext ) {
		[currentRenderingContext flushBuffers];
		[currentRenderingContext release];
		
		// Switch GL Context if different
		if( renderingContext && renderingContext.glContext != glCurrentContext ) {
			glFlush();
			glCurrentContext = renderingContext.glContext;
			[EAGLContext setCurrentContext:glCurrentContext];
		}
		
		[renderingContext prepare];
		currentRenderingContext = [renderingContext retain];
	}
}


#pragma mark -
#pragma mark Touch handlers

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
	[touchDelegate triggerEvent:@"touchstart" all:event.allTouches changed:touches remaining:event.allTouches];
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
	NSMutableSet *remaining = [event.allTouches mutableCopy];
	[remaining minusSet:touches];
	
	[touchDelegate triggerEvent:@"touchend" all:event.allTouches changed:touches remaining:remaining];
	[remaining release];
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
	[self touchesEnded:touches withEvent:event];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
	[touchDelegate triggerEvent:@"touchmove" all:event.allTouches changed:touches remaining:event.allTouches];
}

-(void)pressesBegan:(NSSet*)presses withEvent:(UIPressesEvent *)event {
	if( exitOnMenuPress && ((UIPress *)presses.anyObject).type == UIPressTypeMenu ) {
		return [super pressesBegan:presses withEvent:event];
	}
}


//TODO: Does this belong in this class?
#pragma mark
#pragma mark Timers

- (JSValueRef)createTimer:(JSContextRef)ctxp argc:(size_t)argc argv:(const JSValueRef [])argv repeat:(BOOL)repeat {
	if( argc != 2 || !JSValueIsObject(ctxp, argv[0]) || !JSValueIsNumber(jsGlobalContext, argv[1]) ) {
		return NULL;
	}
	
	JSObjectRef func = JSValueToObject(ctxp, argv[0], NULL);
	float interval = JSValueToNumberFast(ctxp, argv[1])/1000;
	
	// Make sure short intervals (< 18ms) run each frame
	if( interval < 0.018 ) {
		interval = 0;
	}
	
	int timerId = [timers scheduleCallback:func interval:interval repeat:repeat];
	return JSValueMakeNumber( ctxp, timerId );
}

- (JSValueRef)deleteTimer:(JSContextRef)ctxp argc:(size_t)argc argv:(const JSValueRef [])argv {
	if( argc != 1 || !JSValueIsNumber(ctxp, argv[0]) ) return NULL;
	
	[timers cancelId:JSValueToNumberFast(ctxp, argv[0])];
	return NULL;
}

- (JSObjectRef)createFunctionWithBlock:(JSValueRef (^)(JSContextRef ctx, size_t argc, const JSValueRef argv[]))block {
	if( !jsBlockFunctionClass ) {
		JSClassDefinition blockFunctionClassDef = kJSClassDefinitionEmpty;
		blockFunctionClassDef.callAsFunction = EJBlockFunctionCallAsFunction;
		blockFunctionClassDef.finalize = EJBlockFunctionFinalize;
		jsBlockFunctionClass = JSClassCreate(&blockFunctionClassDef);
	}
	
	return JSObjectMake( jsGlobalContext, jsBlockFunctionClass, (void *)Block_copy(block) );
}

@end
