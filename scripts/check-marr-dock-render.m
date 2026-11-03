#import <AppKit/AppKit.h>
@interface TestTile : NSDockTile
@property(nonatomic,strong) NSView *testView;
@property(nonatomic) NSUInteger displays;
@end
@implementation TestTile
- (NSSize)size { return NSMakeSize(128,128); }
- (NSView *)contentView { return self.testView; }
- (void)setContentView:(NSView *)view { self.testView=view; }
- (void)display { self.displays++; }
@end
static void require(BOOL condition, NSString *message) { if(!condition){ NSLog(@"FAIL: %@",message); exit(1); } }
int main(int argc, const char *argv[]) { @autoreleasepool {
 require(argc==2,@"Supply plug-in bundle");
 NSBundle *bundle=[NSBundle bundleWithPath:[NSString stringWithUTF8String:argv[1]]];
 NSError *error=nil;
 require([bundle loadAndReturnError:&error],error.description?:@"Cannot load bundle");
 Class cls=bundle.principalClass;
 require([cls conformsToProtocol:@protocol(NSDockTilePlugIn)],@"Principal class must implement NSDockTilePlugIn");
 id<NSDockTilePlugIn> plugin=[[cls alloc]init];
 TestTile *tile=[TestTile new];
 [plugin setDockTile:tile];
 require([tile.contentView isKindOfClass:NSImageView.class] && tile.displays==1,@"Attach must draw custom view");
 NSImageView *view=(NSImageView *)tile.contentView;
 require(view.autoresizingMask==(NSViewWidthSizable|NSViewHeightSizable),@"Dock magnification resizing");
 NSBitmapImageRep *pixels=[NSBitmapImageRep imageRepWithData:view.image.TIFFRepresentation];
 NSInteger w=pixels.pixelsWide,h=pixels.pixelsHigh; NSUInteger opaque=0;
 for(NSInteger y=0;y<h;y++) for(NSInteger x=0;x<w;x++) {
  double dx=(x+0.5-w/2.0),dy=(y+0.5-h/2.0),alpha=[pixels colorAtX:x y:y].alphaComponent;
  if(hypot(dx,dy)>w*864.0/2048.0+2) require(alpha==0,@"Pixels outside circle must be transparent");
  if(alpha>0.5)opaque++;
 }
 require(opaque>w*h/10,@"Artwork must not be blank");
 [plugin setDockTile:nil]; require(tile.contentView==nil,@"Detach must clear only its own content view");
 [plugin setDockTile:tile]; require(tile.contentView!=nil && tile.displays==2,@"Reattach must redraw");
 NSView *replacement=[NSView new]; tile.contentView=replacement;
 [plugin setDockTile:nil]; require(tile.contentView==replacement,@"Detach must preserve replacement content");
 NSLog(@"PASS: dynamic loading, circular alpha, attach/detach/reattach and view ownership");
} return 0; }
