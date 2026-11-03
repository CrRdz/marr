#import <AppKit/AppKit.h>
#import <os/log.h>

// Loaded by the system's Dock plug-in host, independently of the Marr process.
// Only draws bundled artwork; no preferences, network access or bundle writes.
@interface MarrDockTilePlugIn : NSObject <NSDockTilePlugIn>
@property(nonatomic, weak) NSDockTile *tile;
@property(nonatomic, strong) NSImageView *iconView;
@end

@implementation MarrDockTilePlugIn

- (void)setDockTile:(NSDockTile *)dockTile {
    if (self.iconView && self.tile.contentView == self.iconView) {
        self.tile.contentView = nil;
    }
    self.iconView = nil;
    self.tile = dockTile;
    if (!dockTile) { return; }

    NSBundle *bundle = [NSBundle bundleForClass:self.class];
    NSURL *url = [bundle URLForResource:@"Marr-Dock-512@2x" withExtension:@"png"];
    NSImage *image = url ? [[NSImage alloc] initWithContentsOfURL:url] : nil;
    if (!image) {
        os_log_error(OS_LOG_DEFAULT, "MarrDockTile: missing bundled circular artwork");
        return;
    }

    NSImageView *view = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, dockTile.size.width, dockTile.size.height)];
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    view.imageScaling = NSImageScaleProportionallyUpOrDown;
    view.imageAlignment = NSImageAlignCenter;
    view.image = image;
    self.iconView = view;
    dockTile.contentView = view;
    [dockTile display];
    os_log_info(OS_LOG_DEFAULT, "MarrDockTile: installed circular content view in system host");
}

@end
