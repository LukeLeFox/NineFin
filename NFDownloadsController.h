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

/*
 * Player locale con resume e coda di sync offline, lo stesso
 * usato dalla libreria Scaricati.
 */
+ (UIViewController *)offlinePlayerForFileURL:(NSURL *)url;

/*
 * Salva la posizione come resume locale e la mette in coda
 * per la sincronizzazione con Jellyfin.
 */
+ (void)recordOfflinePosition:(double)seconds
                  forFileURL:(NSURL *)url;


@end
