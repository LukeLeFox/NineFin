#import <UIKit/UIKit.h>

@interface NFDownloadsController : UITableViewController

@property (copy, nonatomic) BOOL (^onlineAvailableHandler)(void);
@property (copy, nonatomic) void (^openOnlineHandler)(void);

@property (copy, nonatomic)
void (^syncOnlineHandler)(
    void (^completion)(
        NSInteger synced,
        NSInteger resolved,
        NSInteger pending));


@end
