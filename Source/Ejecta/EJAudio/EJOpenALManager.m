#import "EJOpenALManager.h"

@implementation EJOpenALManager
@synthesize buffers;

-(id)init {
	if( self = [super init] ) {
		buffers = [[NSMutableDictionary alloc] init];
		device = alcOpenDevice(NULL);
		if( device ) {
			context = alcCreateContext( device, NULL );
			alcMakeContextCurrent( context );
		}
	}
	return self;
}

- (void)dealloc {
	alcDestroyContext( context );
	alcCloseDevice( device );
	[super dealloc];
}

@end
