#import "NFDownloadsController.h"
#import "NFDownloadManager.h"
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>

static NSString *NFOfflineMetaKey(NSString *filename) {
    return [@"NineFin.DownloadMeta."
        stringByAppendingString:filename ?: @""];
}

static NSURL *NFOfflineArtworkURL(NSString *filename) {
    NSURL *documents =
        [[[NSFileManager defaultManager]
            URLsForDirectory:NSDocumentDirectory
            inDomains:NSUserDomainMask] firstObject];

    NSURL *dir =
        [documents URLByAppendingPathComponent:
            @"NineFinDownloadArtwork"
            isDirectory:YES];

    NSString *base =
        [filename stringByDeletingPathExtension];

    return [dir URLByAppendingPathComponent:
        [base stringByAppendingPathExtension:@"jpg"]];
}

static NSString *NFOfflineTime(double seconds) {
    if (!isfinite(seconds) || seconds < 0)
        seconds = 0;

    NSInteger value = (NSInteger)seconds;
    NSInteger h = value / 3600;
    NSInteger m = (value % 3600) / 60;
    NSInteger sec = value % 60;

    if (h > 0)
        return [NSString stringWithFormat:
            @"%ld:%02ld:%02ld",
            (long)h, (long)m, (long)sec];

    return [NSString stringWithFormat:
        @"%ld:%02ld",
        (long)m, (long)sec];
}


static CGFloat NFDownloadsUIScale(CGFloat width) {
    /*
     * Scala continua:
     *
     * 320 pt  -> 1.00
     * 768 pt  -> ~1.05
     * 1024 pt -> 1.08
     *
     * Niente distinzione artificiale portrait/landscape.
     */
    CGFloat t =
        (width - 320.0) /
        (1024.0 - 320.0);

    t = MAX(0.0, MIN(1.0, t));

    return 1.0 + (0.08 * t);
}


static CGFloat __attribute__((unused))
NFDownloadsRowHeight(CGFloat width) {
    return 106.0 * NFDownloadsUIScale(width);
}


static void *NFOfflineResumeContext =
    &NFOfflineResumeContext;


@interface NFOfflinePlayerController : AVPlayerViewController

@property (copy, nonatomic) NSString *resumeKey;
@property (strong, nonatomic) id progressObserver;
@property (assign, nonatomic) BOOL observingReady;
@property (assign, nonatomic) BOOL resumeApplied;
@property (assign, nonatomic) BOOL didFinish;

- (void)applySavedResume;

@end


@implementation NFOfflinePlayerController


- (void)saveCurrentPosition {
    if (self.didFinish ||
        !self.resumeKey.length ||
        !self.player)
        return;

    Float64 seconds =
        CMTimeGetSeconds(
            self.player.currentTime);

    if (!isfinite(seconds) ||
        seconds < 1.0)
        return;

    NSUserDefaults *defaults =
        [NSUserDefaults standardUserDefaults];

    /*
     * Resume locale immediato.
     */
    [defaults setDouble:seconds
        forKey:self.resumeKey];


    /*
     * Coda di sincronizzazione Jellyfin.
     *
     * Il filename è già univoco per server + item.
     */
    NSString *prefix =
        @"NineFin.OfflineResume.";

    if ([self.resumeKey hasPrefix:prefix]) {

        NSString *filename =
            [self.resumeKey
                substringFromIndex:
                    prefix.length];

        NSString *metaKey =
            NFOfflineMetaKey(filename);

        NSDictionary *oldMeta =
            [defaults
                dictionaryForKey:metaKey];

        NSMutableDictionary *meta =
            [oldMeta isKindOfClass:
                [NSDictionary class]]
                ? [oldMeta mutableCopy]
                : [NSMutableDictionary dictionary];

        long long ticks =
            (long long)(
                seconds * 10000000.0);

        meta[@"offlinePositionTicks"] =
            @(ticks);

        meta[@"offlinePlayed"] =
            @NO;

        meta[@"offlineDirty"] =
            @YES;

        meta[@"offlineUpdatedAt"] =
            @([[NSDate date]
                timeIntervalSince1970]);

        [defaults setObject:meta
            forKey:metaKey];
    }

    [defaults synchronize];
}


- (void)applySavedResume {
    if (self.resumeApplied ||
        !self.player ||
        !self.player.currentItem)
        return;

    self.resumeApplied = YES;

    double saved =
        [[NSUserDefaults standardUserDefaults]
            doubleForKey:self.resumeKey];

    if (!isfinite(saved) || saved <= 1.0) {
        [self.player play];
        return;
    }

    Float64 duration =
        CMTimeGetSeconds(
            self.player.currentItem.duration);

    if (isfinite(duration) &&
        duration > 10.0) {

        saved = MIN(
            saved,
            duration - 5.0);
    }

    if (saved < 0.0)
        saved = 0.0;

    NSLog(
        @"NineFin offline resume: %.1f s",
        saved);

    CMTime target =
        CMTimeMakeWithSeconds(
            saved,
            600);

    __weak NFOfflinePlayerController *weakSelf =
        self;

    [self.player
        seekToTime:target
        toleranceBefore:kCMTimeZero
        toleranceAfter:kCMTimeZero
        completionHandler:^(BOOL finished) {

            dispatch_async(
                dispatch_get_main_queue(), ^{

                NFOfflinePlayerController *vc =
                    weakSelf;

                if (!vc)
                    return;

                NSLog(
                    @"NineFin offline seek: %@",
                    finished
                        ? @"OK"
                        : @"interrotto");

                [vc.player play];
            });
        }];
}


- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];

    AVPlayerItem *item =
        self.player.currentItem;

    if (!item)
        return;

    __weak NFOfflinePlayerController *weakSelf =
        self;

    if (!self.progressObserver) {
        self.progressObserver =
            [self.player
                addPeriodicTimeObserverForInterval:
                    CMTimeMake(5, 1)
                queue:dispatch_get_main_queue()
                usingBlock:^(CMTime time) {

                    NFOfflinePlayerController *vc =
                        weakSelf;

                    if (vc)
                        [vc saveCurrentPosition];
                }];
    }

    [[NSNotificationCenter defaultCenter]
        removeObserver:self
        name:AVPlayerItemDidPlayToEndTimeNotification
        object:item];

    [[NSNotificationCenter defaultCenter]
        addObserver:self
        selector:@selector(playbackFinished:)
        name:AVPlayerItemDidPlayToEndTimeNotification
        object:item];

    double saved =
        [[NSUserDefaults standardUserDefaults]
            doubleForKey:self.resumeKey];

    if (!isfinite(saved) || saved <= 1.0) {
        self.resumeApplied = YES;
        [self.player play];
        return;
    }

    /*
     * Se il file è già pronto non serve KVO.
     */
    if (item.status ==
        AVPlayerItemStatusReadyToPlay) {

        [self applySavedResume];
        return;
    }

    /*
     * Su iOS 9 NON usiamo Initial.
     * Aspettiamo solo un vero cambio di stato.
     */
    if (!self.observingReady) {
        self.observingReady = YES;

        [item addObserver:self
            forKeyPath:@"status"
            options:NSKeyValueObservingOptionNew
            context:NFOfflineResumeContext];
    }
}


- (void)observeValueForKeyPath:(NSString *)keyPath
                       ofObject:(id)object
                         change:(NSDictionary *)change
                        context:(void *)context {

    if (context != NFOfflineResumeContext) {
        [super observeValueForKeyPath:keyPath
            ofObject:object
            change:change
            context:context];

        return;
    }

    AVPlayerItem *item =
        self.player.currentItem;

    if (!item)
        return;

    if (item.status ==
        AVPlayerItemStatusReadyToPlay) {

        /*
         * Non rimuoviamo il KVO da dentro la callback.
         * Verrà rimosso in dealloc.
         */
        [self applySavedResume];

    } else if (item.status ==
        AVPlayerItemStatusFailed) {

        NSLog(@"NineFin offline player failed: %@",
            item.error);
    }
}


- (void)playbackFinished:(NSNotification *)note {
    if (note.object != self.player.currentItem)
        return;

    self.didFinish = YES;

    NSUserDefaults *defaults =
        [NSUserDefaults standardUserDefaults];

    if (self.resumeKey.length) {

        /*
         * Fine naturale:
         * il resume locale non serve più.
         */
        [defaults removeObjectForKey:
            self.resumeKey];

        NSString *prefix =
            @"NineFin.OfflineResume.";

        if ([self.resumeKey hasPrefix:prefix]) {

            NSString *filename =
                [self.resumeKey
                    substringFromIndex:
                        prefix.length];

            NSString *metaKey =
                NFOfflineMetaKey(filename);

            NSDictionary *oldMeta =
                [defaults
                    dictionaryForKey:metaKey];

            NSMutableDictionary *meta =
                [oldMeta isKindOfClass:
                    [NSDictionary class]]
                    ? [oldMeta mutableCopy]
                    : [NSMutableDictionary dictionary];

            /*
             * Stato locale della libreria Scaricati.
             */
            meta[@"played"] = @YES;

            /*
             * Stato pending da inviare a Jellyfin
             * al prossimo ritorno online.
             */
            meta[@"offlinePlayed"] = @YES;
            meta[@"offlinePositionTicks"] = @0;
            meta[@"offlineDirty"] = @YES;

            meta[@"offlineUpdatedAt"] =
                @([[NSDate date]
                    timeIntervalSince1970]);

            [defaults setObject:meta
                forKey:metaKey];
        }

        [defaults synchronize];
    }

    NSLog(
        @"NineFin offline playback finished: pending sync");
}


- (void)viewWillDisappear:(BOOL)animated {
    [self saveCurrentPosition];

    [super viewWillDisappear:animated];
}


- (void)dealloc {
    [[NSNotificationCenter defaultCenter]
        removeObserver:self];

    if (self.observingReady &&
        self.player.currentItem) {

        [self.player.currentItem
            removeObserver:self
            forKeyPath:@"status"
            context:NFOfflineResumeContext];

        self.observingReady = NO;
    }

    if (self.progressObserver &&
        self.player) {

        [self.player
            removeTimeObserver:self.progressObserver];

        self.progressObserver = nil;
    }
}

@end


@interface NFDownloadsController ()
@property (strong, nonatomic) NSArray *files;
@property (strong, nonatomic) NSArray *activeDownloads;
@property (strong, nonatomic) NSTimer *downloadRefreshTimer;
@property (assign, nonatomic) BOOL onlineMode;
@end

@implementation NFDownloadsController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"Scaricati";

    if (self.openOnlineHandler) {
        self.navigationItem.leftBarButtonItem =
            [[UIBarButtonItem alloc]
                initWithTitle:@"Vai online e sincronizza"
                style:UIBarButtonItemStylePlain
                target:self
                action:@selector(openOnlinePressed)];
    }
    self.tableView.rowHeight = 88;
    self.tableView.backgroundColor =
        [UIColor colorWithRed:0.055 green:0.075 blue:0.105 alpha:1];

    self.tableView.separatorColor =
        [UIColor colorWithRed:0.105 green:0.135 blue:0.185 alpha:1];

    self.tableView.tableFooterView = [[UIView alloc] init];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc]
            initWithTitle:@"Elimina"
            style:UIBarButtonItemStylePlain
            target:self
            action:@selector(deleteMenuPressed)];
}

- (void)openOnlinePressed {

    /*
     * Dopo una sincronizzazione riuscita
     * lo stesso pulsante diventa "Home".
     */
    if (self.onlineMode) {

        if (self.openOnlineHandler)
            self.openOnlineHandler();

        return;
    }


    /*
     * Prima verifichiamo che la rete
     * sia effettivamente disponibile.
     */
    if (self.onlineAvailableHandler &&
        !self.onlineAvailableHandler()) {

        UIAlertController *alert =
            [UIAlertController
                alertControllerWithTitle:
                    @"Ancora offline"
                message:
                    @"La rete non è ancora disponibile."
                preferredStyle:
                    UIAlertControllerStyleAlert];

        [alert addAction:
            [UIAlertAction
                actionWithTitle:@"OK"
                style:UIAlertActionStyleDefault
                handler:nil]];

        [self presentViewController:alert
            animated:YES
            completion:nil];

        return;
    }


    UIBarButtonItem *button =
        self.navigationItem.leftBarButtonItem;

    button.title = @"Sincronizzo…";
    button.enabled = NO;


    /*
     * Lo Step 3 collegherà questo handler
     * alla coda NFRunOfflineSyncQueue().
     */
    if (!self.syncOnlineHandler) {

        /*
         * Stato di sicurezza:
         * non navighiamo via dalla schermata.
         */
        button.title =
            @"Vai online e sincronizza";

        button.enabled = YES;

        return;
    }


    __weak NFDownloadsController *weakSelf =
        self;

    self.syncOnlineHandler(
        ^(NSInteger synced,
          NSInteger resolved,
          NSInteger pending) {

        (void)resolved;

        dispatch_async(
            dispatch_get_main_queue(), ^{

            NFDownloadsController *vc =
                weakSelf;

            if (!vc)
                return;

            UIBarButtonItem *barButton =
                vc.navigationItem.leftBarButtonItem;


            /*
             * Tutto riconciliato:
             * rimaniamo in Scaricati,
             * ma ora il pulsante porta alla Home.
             */
            if (pending <= 0) {

                vc.onlineMode = YES;

                barButton.title =
                    @"Home";

                barButton.enabled = YES;

                return;
            }


            /*
             * Alcuni record sono ancora pending:
             * lasciamo disponibile il retry.
             */
            barButton.title =
                @"Vai online e sincronizza";

            barButton.enabled = YES;


            NSString *message =
                [NSString stringWithFormat:
                    @"Sincronizzati: %ld\n"
                     @"Ancora da sincronizzare: %ld",
                    (long)synced,
                    (long)pending];

            UIAlertController *alert =
                [UIAlertController
                    alertControllerWithTitle:
                        @"Sincronizzazione incompleta"
                    message:message
                    preferredStyle:
                        UIAlertControllerStyleAlert];

            [alert addAction:
                [UIAlertAction
                    actionWithTitle:@"OK"
                    style:UIAlertActionStyleDefault
                    handler:nil]];

            [vc presentViewController:alert
                animated:YES
                completion:nil];
        });
    });
}


- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:
           (id<UIViewControllerTransitionCoordinator>)coordinator {

    [super viewWillTransitionToSize:size
        withTransitionCoordinator:coordinator];

    __weak NFDownloadsController *weakSelf =
        self;

    [coordinator
        animateAlongsideTransition:nil
        completion:
            ^(id<UIViewControllerTransitionCoordinatorContext> context) {

                (void)context;

                NFDownloadsController *vc =
                    weakSelf;

                if (!vc)
                    return;

                [vc.tableView reloadData];

                [vc renderActiveDownloadsHeader];
            }];
}


- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    [self reloadDownloads];

    /*
     * Il refresh al secondo serve soltanto mentre
     * esistono download attivi.
     *
     * Senza download non ha senso ridisegnare
     * continuamente una schermata statica.
     */
    if (self.activeDownloads.count &&
        !self.downloadRefreshTimer) {

        self.downloadRefreshTimer =
            [NSTimer
                scheduledTimerWithTimeInterval:1.0
                target:self
                selector:@selector(refreshDownloadUI)
                userInfo:nil
                repeats:YES];
    }
}


- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];

    [self.downloadRefreshTimer invalidate];
    self.downloadRefreshTimer = nil;
}


- (void)refreshDownloadUI {

    NFDownloadManager *manager =
        [NFDownloadManager sharedManager];


    NSArray *updatedFiles =
        [manager downloadedFiles] ?: @[];

    NSArray *updatedActive =
        [manager activeDownloads] ?: @[];


    NSArray *currentFiles =
        self.files ?: @[];


    /*
     * reloadData chiude automaticamente lo swipe-to-delete.
     *
     * Lo eseguiamo quindi soltanto se il contenuto reale
     * della lista Scaricati è cambiato.
     */
    BOOL filesChanged =
        ![currentFiles
            isEqualToArray:updatedFiles];


    self.files =
        updatedFiles;

    self.activeDownloads =
        updatedActive;


    /*
     * La testata della coda può continuare invece
     * ad aggiornarsi ogni secondo per mostrare progress
     * e passaggio In coda -> Download in corso.
     */
    [self renderActiveDownloadsHeader];


    if (filesChanged) {
        [self.tableView reloadData];
    }


    /*
     * Finita tutta la FIFO non serve più alcun polling.
     */
    if (!updatedActive.count) {

        [self.downloadRefreshTimer invalidate];

        self.downloadRefreshTimer =
            nil;
    }
}


- (void)reloadDownloads {
    NFDownloadManager *manager =
        [NFDownloadManager sharedManager];

    self.files =
        [manager downloadedFiles];

    self.activeDownloads =
        [manager activeDownloads];

    [self renderActiveDownloadsHeader];
    [self.tableView reloadData];
}


- (void)renderActiveDownloadsHeader {

    NSArray *downloads =
        self.activeDownloads;

    if (!downloads.count) {

        self.tableView.tableHeaderView =
            nil;

        return;
    }


    CGFloat width =
        CGRectGetWidth(
            self.tableView.bounds);

    CGFloat titleHeight =
        34.0;

    CGFloat rowHeight =
        74.0;

    CGFloat height =
        titleHeight +
        rowHeight * downloads.count +
        8.0;


    UIView *header =
        [[UIView alloc]
            initWithFrame:CGRectMake(
                0,
                0,
                width,
                height)];

    header.backgroundColor =
        [UIColor colorWithRed:0.055
                        green:0.075
                         blue:0.105
                        alpha:1];


    UILabel *heading =
        [[UILabel alloc]
            initWithFrame:CGRectMake(
                15,
                7,
                width - 30,
                22)];

    heading.text =
        @"CODA DOWNLOAD";

    heading.textColor =
        [UIColor colorWithRed:0.63
                        green:0.69
                         blue:0.76
                        alpha:1];

    heading.font =
        [UIFont boldSystemFontOfSize:12];

    [header addSubview:heading];


    for (NSUInteger i = 0;
         i < downloads.count;
         i++) {

        NSDictionary *download =
            downloads[i];


        NSString *filename =
            download[@"filename"] ?: @"";


        NSDictionary *meta =
            [[NSUserDefaults standardUserDefaults]
                dictionaryForKey:
                    NFOfflineMetaKey(filename)];


        NSString *title =
            meta[@"title"];

        if (![title isKindOfClass:
                [NSString class]] ||
            !title.length) {

            title =
                filename.length
                    ? filename
                    : @"Download";
        }


        BOOL queued =
            [download[@"queued"]
                boolValue];


        double fraction =
            [download[@"progress"]
                doubleValue];

        if (!isfinite(fraction) ||
            fraction < 0.0) {

            fraction = 0.0;
        }

        if (fraction > 1.0)
            fraction = 1.0;


        NSInteger percent =
            (NSInteger)(
                fraction * 100.0);


        CGFloat y =
            titleHeight +
            i * rowHeight;


        UIView *card =
            [[UIView alloc]
                initWithFrame:CGRectMake(
                    10,
                    y,
                    width - 20,
                    64)];

        card.backgroundColor =
            [UIColor colorWithRed:0.105
                            green:0.135
                             blue:0.185
                            alpha:1];

        card.layer.cornerRadius =
            7.0;


        UILabel *titleLabel =
            [[UILabel alloc]
                initWithFrame:CGRectMake(
                    12,
                    7,
                    card.bounds.size.width - 105,
                    21)];

        titleLabel.text =
            title;

        titleLabel.textColor =
            [UIColor whiteColor];

        titleLabel.font =
            [UIFont boldSystemFontOfSize:13];

        titleLabel.lineBreakMode =
            NSLineBreakByTruncatingTail;

        [card addSubview:titleLabel];


        UILabel *status =
            [[UILabel alloc]
                initWithFrame:CGRectMake(
                    12,
                    29,
                    card.bounds.size.width - 105,
                    17)];


        if (queued) {

            status.text =
                @"In attesa";

        } else {

            status.text =
                [NSString stringWithFormat:
                    @"Download in corso · %ld%%",
                    (long)percent];
        }


        status.textColor =
            [UIColor lightGrayColor];

        status.font =
            [UIFont systemFontOfSize:11];

        [card addSubview:status];


        UIButton *cancel =
            [UIButton
                buttonWithType:
                    UIButtonTypeSystem];

        cancel.frame =
            CGRectMake(
                card.bounds.size.width - 77,
                10,
                67,
                34);

        cancel.tag =
            i;

        [cancel setTitle:@"Annulla"
            forState:
                UIControlStateNormal];

        cancel.titleLabel.font =
            [UIFont systemFontOfSize:11];

        [cancel setTitleColor:
            [UIColor colorWithRed:0.19
                            green:0.78
                             blue:0.85
                            alpha:1]
            forState:
                UIControlStateNormal];

        [cancel addTarget:self
            action:
                @selector(
                    cancelActiveDownload:)
            forControlEvents:
                UIControlEventTouchUpInside];

        [card addSubview:cancel];


        /*
         * Barra:
         * - attivo  -> avanzamento reale
         * - queued  -> vuota
         */
        CGFloat barWidth =
            card.bounds.size.width - 24;


        UIView *track =
            [[UIView alloc]
                initWithFrame:CGRectMake(
                    12,
                    52,
                    barWidth,
                    3)];

        track.backgroundColor =
            [UIColor colorWithWhite:1
                              alpha:0.12];

        track.clipsToBounds =
            YES;


        CGFloat fillWidth =
            queued
                ? 0.0
                : barWidth * fraction;


        UIView *fill =
            [[UIView alloc]
                initWithFrame:CGRectMake(
                    0,
                    0,
                    fillWidth,
                    3)];

        fill.backgroundColor =
            [UIColor colorWithRed:0.19
                            green:0.78
                             blue:0.85
                            alpha:1];

        [track addSubview:fill];

        [card addSubview:track];

        [header addSubview:card];
    }


    self.tableView.tableHeaderView =
        header;
}


- (void)cancelActiveDownload:(UIButton *)sender {
    NSUInteger index =
        (NSUInteger)sender.tag;

    if (index >= self.activeDownloads.count)
        return;

    NSDictionary *download =
        self.activeDownloads[index];

    NSString *itemId =
        download[@"itemId"];

    if (![itemId isKindOfClass:
            [NSString class]] ||
        !itemId.length)
        return;

    NSString *filename =
        download[@"filename"] ?: @"Download";

    NSDictionary *meta =
        [[NSUserDefaults standardUserDefaults]
            dictionaryForKey:
                NFOfflineMetaKey(filename)];

    NSString *title =
        meta[@"title"];

    if (![title isKindOfClass:
            [NSString class]] ||
        !title.length) {
        title = @"questo download";
    }

    UIAlertController *confirm =
        [UIAlertController
            alertControllerWithTitle:
                @"Annulla download"
            message:
                [NSString stringWithFormat:
                    @"Vuoi interrompere %@?",
                    title]
            preferredStyle:
                UIAlertControllerStyleAlert];

    [confirm addAction:
        [UIAlertAction
            actionWithTitle:@"Continua"
            style:UIAlertActionStyleCancel
            handler:nil]];

    __weak NFDownloadsController *weakSelf =
        self;

    [confirm addAction:
        [UIAlertAction
            actionWithTitle:@"Annulla download"
            style:UIAlertActionStyleDestructive
            handler:^(UIAlertAction *action) {

                [[NFDownloadManager sharedManager]
                    cancelDownloadForItemId:itemId];

                [weakSelf reloadDownloads];
            }]];

    [self presentViewController:confirm
        animated:YES
        completion:nil];
}


- (NSDictionary *)metadataForURL:(NSURL *)url {
    return [[NSUserDefaults standardUserDefaults]
        dictionaryForKey:
            NFOfflineMetaKey(url.lastPathComponent)];
}


- (double)durationForURL:(NSURL *)url
                metadata:(NSDictionary *)meta {

    long long ticks =
        [meta[@"runtimeTicks"] longLongValue];

    if (ticks > 0)
        return (double)ticks / 10000000.0;

    AVURLAsset *asset =
        [AVURLAsset URLAssetWithURL:url
            options:nil];

    double seconds =
        CMTimeGetSeconds(asset.duration);

    return isfinite(seconds) && seconds > 0
        ? seconds : 0;
}


- (double)positionForURL:(NSURL *)url {
    return [[NSUserDefaults standardUserDefaults]
        doubleForKey:
            [@"NineFin.OfflineResume."
                stringByAppendingString:
                    url.lastPathComponent]];
}


- (BOOL)isWatchedURL:(NSURL *)url {
    NSDictionary *meta =
        [self metadataForURL:url];

    if ([meta[@"played"] boolValue])
        return YES;

    double duration =
        [self durationForURL:url
                    metadata:meta];

    double position =
        [self positionForURL:url];

    if (duration <= 0 || position <= 0)
        return NO;

    /*
     * Jellyfin default MaxResumePct = 90.
     */
    return (position / duration) >= 0.90;
}


- (void)removeLocalDownloadURL:(NSURL *)url {
    if (!url)
        return;

    NSString *filename =
        url.lastPathComponent;

    NSFileManager *fm =
        [NSFileManager defaultManager];

    NSError *error = nil;

    if ([fm fileExistsAtPath:url.path] &&
        ![fm removeItemAtURL:url error:&error]) {

        NSLog(@"NineFin delete failed: %@", error);
        return;
    }

    NSURL *art =
        NFOfflineArtworkURL(filename);

    [fm removeItemAtURL:art error:NULL];

    NSUserDefaults *defaults =
        [NSUserDefaults standardUserDefaults];

    [defaults removeObjectForKey:
        NFOfflineMetaKey(filename)];

    [defaults removeObjectForKey:
        [@"NineFin.OfflineResume."
            stringByAppendingString:filename]];

    [defaults synchronize];
}


- (void)deleteURLs:(NSArray *)urls {
    for (NSURL *url in urls)
        [self removeLocalDownloadURL:url];

    [self reloadDownloads];
}


- (void)deleteMenuPressed {
    if (!self.files.count)
        return;

    NSMutableArray *watched =
        [NSMutableArray array];

    for (NSURL *url in self.files) {
        if ([self isWatchedURL:url])
            [watched addObject:url];
    }

    UIAlertController *sheet =
        [UIAlertController
            alertControllerWithTitle:
                @"Elimina download"
            message:nil
            preferredStyle:
                UIAlertControllerStyleActionSheet];

    __weak NFDownloadsController *weakSelf =
        self;

    if (watched.count) {
        NSString *title =
            [NSString stringWithFormat:
                @"Elimina solo visti (%lu)",
                (unsigned long)watched.count];

        [sheet addAction:
            [UIAlertAction
                actionWithTitle:title
                style:UIAlertActionStyleDestructive
                handler:^(UIAlertAction *action) {
                    [weakSelf deleteURLs:watched];
                }]];
    }

    NSString *allTitle =
        [NSString stringWithFormat:
            @"Elimina tutto (%lu)",
            (unsigned long)self.files.count];

    [sheet addAction:
        [UIAlertAction
            actionWithTitle:allTitle
            style:UIAlertActionStyleDestructive
            handler:^(UIAlertAction *action) {
                [weakSelf deleteURLs:
                    [weakSelf.files copy]];
            }]];

    [sheet addAction:
        [UIAlertAction
            actionWithTitle:@"Annulla"
            style:UIAlertActionStyleCancel
            handler:nil]];

    /*
     * Necessario su iPad.
     */
    UIPopoverPresentationController *popover =
        sheet.popoverPresentationController;

    if (popover)
        popover.barButtonItem =
            self.navigationItem.rightBarButtonItem;

    [self presentViewController:sheet
        animated:YES
        completion:nil];
}


- (CGFloat)tableView:(UITableView *)tableView
 heightForRowAtIndexPath:(NSIndexPath *)indexPath {

    (void)indexPath;

    return NFDownloadsRowHeight(
        CGRectGetWidth(tableView.bounds));
}


- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    return self.files.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {

    UITableViewCell *cell =
        [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleDefault
            reuseIdentifier:nil];

    NSURL *url =
        self.files[indexPath.row];

    NSString *filename =
        url.lastPathComponent;

    NSDictionary *meta =
        [[NSUserDefaults standardUserDefaults]
            dictionaryForKey:
                NFOfflineMetaKey(filename)];

    CGFloat width =
        CGRectGetWidth(tableView.bounds);

    CGFloat scale =
        NFDownloadsUIScale(width);

    CGFloat rowHeight =
        NFDownloadsRowHeight(width);

    cell.backgroundColor =
        [UIColor colorWithRed:0.105
                        green:0.135
                         blue:0.185
                        alpha:1];

    cell.contentView.backgroundColor =
        cell.backgroundColor;

    cell.layoutMargins =
        UIEdgeInsetsZero;

    cell.separatorInset =
        UIEdgeInsetsZero;

    cell.clipsToBounds = YES;
    cell.contentView.clipsToBounds = YES;

    cell.accessoryType =
        UITableViewCellAccessoryDisclosureIndicator;


    /*
     * POSTER
     *
     * Cresce leggermente con la larghezza dello schermo.
     */
    CGFloat posterWidth =
        MIN(rowHeight * 1.42,
            width * 0.29);

    CGFloat posterHeight =
        rowHeight;

    UIImageView *posterView =
        [[UIImageView alloc]
            initWithFrame:CGRectMake(
                0,
                0,
                posterWidth,
                posterHeight)];

    posterView.backgroundColor =
        [UIColor colorWithWhite:0.08
                          alpha:1];

    posterView.contentMode =
        UIViewContentModeScaleAspectFill;

    posterView.clipsToBounds = YES;

    NSURL *artURL =
        NFOfflineArtworkURL(filename);

    UIImage *poster =
        [UIImage imageWithContentsOfFile:
            artURL.path];

    if (poster)
        posterView.image = poster;

    [cell.contentView
        addSubview:posterView];


    /*
     * AREA TESTO
     */
    CGFloat textX =
        posterWidth +
        (15.0 * scale);

    CGFloat rightPadding =
        44.0 * scale;

    CGFloat textWidth =
        width -
        textX -
        rightPadding;

    if (textWidth < 120.0)
        textWidth = 120.0;


    /*
     * TITOLO
     */
    NSString *title =
        meta[@"title"];

    if (![title isKindOfClass:
            [NSString class]] ||
        !title.length) {

        title = filename;
    }

    UILabel *titleLabel =
        [[UILabel alloc]
            initWithFrame:CGRectMake(
                textX,
                10.0 * scale,
                textWidth,
                22.0 * scale)];

    titleLabel.text = title;

    titleLabel.textColor =
        [UIColor whiteColor];

    titleLabel.font =
        [UIFont boldSystemFontOfSize:
            15.0 * scale];

    titleLabel.adjustsFontSizeToFitWidth = YES;
    titleLabel.minimumScaleFactor = 0.72;

    [cell.contentView
        addSubview:titleLabel];


    /*
     * SERIE / EPISODIO / DIMENSIONE
     */
    NSDictionary *info =
        [[NSFileManager defaultManager]
            attributesOfItemAtPath:url.path
            error:NULL];

    unsigned long long bytes =
        [info[NSFileSize]
            unsignedLongLongValue];

    double mb =
        (double)bytes /
        1024.0 /
        1024.0;

    NSString *kind =
        @"Video";

    NSString *type =
        meta[@"type"];

    if ([type isEqualToString:@"Movie"]) {

        kind = @"Film";

    } else if ([type isEqualToString:@"Episode"]) {

        NSNumber *season =
            meta[@"season"];

        NSNumber *episode =
            meta[@"episode"];

        NSString *series =
            meta[@"series"];

        if ([series isKindOfClass:
                [NSString class]] &&
            series.length) {

            if (season && episode) {

                kind =
                    [NSString stringWithFormat:
                        @"%@ · S%02ldE%02ld",
                        series,
                        (long)season.integerValue,
                        (long)episode.integerValue];

            } else {

                kind = series;
            }

        } else {

            kind = @"Episodio";
        }
    }

    UILabel *infoLabel =
        [[UILabel alloc]
            initWithFrame:CGRectMake(
                textX,
                37.0 * scale,
                textWidth,
                18.0 * scale)];

    infoLabel.text =
        [NSString stringWithFormat:
            @"%@ · %.1f MB",
            kind,
            mb];

    infoLabel.textColor =
        [UIColor colorWithWhite:0.66
                          alpha:1];

    infoLabel.font =
        [UIFont systemFontOfSize:
            11.5 * scale];

    infoLabel.adjustsFontSizeToFitWidth = YES;
    infoLabel.minimumScaleFactor = 0.70;

    [cell.contentView
        addSubview:infoLabel];


    /*
     * WATCHTIME
     */
    double position =
        [[NSUserDefaults standardUserDefaults]
            doubleForKey:
                [@"NineFin.OfflineResume."
                    stringByAppendingString:
                        filename]];

    long long runtimeTicks =
        [meta[@"runtimeTicks"]
            longLongValue];

    double duration =
        runtimeTicks > 0
            ? (double)runtimeTicks /
                10000000.0
            : 0.0;

    BOOL played =
        [meta[@"played"]
            boolValue];

    NSString *watchText = nil;

    if (played &&
        duration > 1.0) {

        watchText =
            [NSString stringWithFormat:
                @"✓ Visto · %@ / %@",
                NFOfflineTime(duration),
                NFOfflineTime(duration)];

    } else if (position > 1.0 &&
               duration > 1.0) {

        watchText =
            [NSString stringWithFormat:
                @"Visto %@ / %@",
                NFOfflineTime(position),
                NFOfflineTime(duration)];

    } else if (duration > 1.0) {

        watchText =
            [NSString stringWithFormat:
                @"Non iniziato · %@",
                NFOfflineTime(duration)];

    } else {

        watchText =
            @"Non iniziato";
    }

    UILabel *watchLabel =
        [[UILabel alloc]
            initWithFrame:CGRectMake(
                textX,
                60.0 * scale,
                textWidth,
                20.0 * scale)];

    watchLabel.text =
        watchText;

    watchLabel.textColor =
        [UIColor colorWithRed:0.19
                        green:0.78
                         blue:0.85
                        alpha:1];

    watchLabel.font =
        [UIFont boldSystemFontOfSize:
            14.0 * scale];

    watchLabel.adjustsFontSizeToFitWidth = YES;
    watchLabel.minimumScaleFactor = 0.75;

    [cell.contentView
        addSubview:watchLabel];


    /*
     * BARRA WATCHTIME
     *
     * Non usa più coordinate relative allo schermo.
     * Occupa esclusivamente la zona testo.
     */
    if (duration > 1.0) {

        double fraction = 0.0;

        if (played) {
            fraction = 1.0;

        } else if (position > 0.0) {
            fraction =
                position / duration;
        }

        fraction =
            MAX(0.0,
                MIN(1.0, fraction));

        CGFloat barY =
            rowHeight -
            (13.0 * scale);

        CGFloat barHeight =
            4.0 * scale;

        UIView *track =
            [[UIView alloc]
                initWithFrame:CGRectMake(
                    textX,
                    barY,
                    textWidth,
                    barHeight)];

        track.backgroundColor =
            [UIColor colorWithWhite:1
                              alpha:0.12];

        track.layer.cornerRadius =
            barHeight / 2.0;

        track.clipsToBounds = YES;

        UIView *fill =
            [[UIView alloc]
                initWithFrame:CGRectMake(
                    0,
                    0,
                    textWidth * fraction,
                    barHeight)];

        fill.backgroundColor =
            [UIColor colorWithRed:0.19
                            green:0.78
                             blue:0.85
                            alpha:1];

        fill.layer.cornerRadius =
            barHeight / 2.0;

        [track addSubview:fill];

        [cell.contentView
            addSubview:track];
    }

    return cell;
}


- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {

    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.row >= self.files.count)
        return;

    NSURL *url = self.files[indexPath.row];

    if (![[NSFileManager defaultManager]
            fileExistsAtPath:url.path])
        return;

    NSLog(@"NineFin local-only playback: %@", url.path);

    NFOfflinePlayerController *vc =
        [[NFOfflinePlayerController alloc] init];

    vc.player =
        [AVPlayer playerWithURL:url];

    vc.resumeKey =
        [@"NineFin.OfflineResume."
            stringByAppendingString:
                url.lastPathComponent];

    [self presentViewController:vc
        animated:YES
        completion:nil];
}

- (BOOL)tableView:(UITableView *)tableView
 canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (void)tableView:(UITableView *)tableView
 commitEditingStyle:(UITableViewCellEditingStyle)style
 forRowAtIndexPath:(NSIndexPath *)indexPath {

    if (style != UITableViewCellEditingStyleDelete)
        return;

    if (indexPath.row >= self.files.count)
        return;

    NSURL *url =
        self.files[indexPath.row];

    NSDictionary *meta =
        [self metadataForURL:url];

    NSString *title =
        meta[@"title"];

    if (![title isKindOfClass:[NSString class]] ||
        !title.length)
        title = url.lastPathComponent;

    UIAlertController *confirm =
        [UIAlertController
            alertControllerWithTitle:
                @"Elimina download"
            message:title
            preferredStyle:
                UIAlertControllerStyleAlert];

    [confirm addAction:
        [UIAlertAction
            actionWithTitle:@"Annulla"
            style:UIAlertActionStyleCancel
            handler:nil]];

    __weak NFDownloadsController *weakSelf =
        self;

    [confirm addAction:
        [UIAlertAction
            actionWithTitle:@"Elimina"
            style:UIAlertActionStyleDestructive
            handler:^(UIAlertAction *action) {
                [weakSelf removeLocalDownloadURL:url];
                [weakSelf reloadDownloads];
            }]];

    [self presentViewController:confirm
        animated:YES
        completion:nil];
}



@end
