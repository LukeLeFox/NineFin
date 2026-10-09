#import "NFDownloadManager.h"
#import <UIKit/UIKit.h>

static NSString * const NFDownloadErrorDomain =
    @"dev.luke.ninefin.download";

NSString * const NFDownloadManagerDidCompleteNotification =
    @"NFDownloadManagerDidCompleteNotification";

NSString * const NFDownloadManagerQueueDidChangeNotification =
    @"NFDownloadManagerQueueDidChangeNotification";

NSString * const NFDownloadManagerSeasonBatchDidFinishNotification =
    @"NFDownloadManagerSeasonBatchDidFinishNotification";

static NSString * const NFDownloadBackgroundSessionIdentifier =
    @"dev.luke.ninefin.background-downloads";

static NSString * const NFDownloadQueueSequenceDefaultsKey =
    @"NineFin.DownloadQueueSequence";

static NSString * const NFPendingQueueManifestDefaultsKey =
    @"NineFin.DownloadPendingManifest.v1";

static NSString * const NFSeasonNotificationBatchesDefaultsKey =
    @"NineFin.SeasonNotificationBatches.v1";

static NSString * const NFSeasonNotificationOutboxDefaultsKey =
    @"NineFin.SeasonNotificationOutbox.v1";

@interface NFDownloadContext : NSObject

@property (copy, nonatomic) NSString *itemId;
@property (copy, nonatomic) NSString *displayTitle;
@property (strong, nonatomic) NSURL *destinationURL;
@property (copy, nonatomic, nullable) NFDownloadProgressBlock progressBlock;
@property (copy, nonatomic, nullable) NFDownloadCompletionBlock completionBlock;
@property (strong, nonatomic) NSURLSessionDownloadTask *task;
@property (assign, nonatomic) double progress;
@property (assign, nonatomic) BOOL movedToDestination;
@property (assign, nonatomic) BOOL destinationAlreadyPresent;
@property (strong, nonatomic, nullable) NSError *finalError;

/*
 * YES = task creato ma ancora in attesa del proprio turno.
 */
@property (assign, nonatomic) BOOL queued;

/*
 * Sequenza persistente della FIFO.
 * Sopravvive ai relaunch tramite taskDescription.
 */
@property (assign, nonatomic) NSInteger queueSequence;

@end

@implementation NFDownloadContext
@end


/*
 * Stato runtime di un job logico.
 *
 * Il manifest conserva soltanto dati non segreti.
 * Request e callback rimangono esclusivamente
 * nella memoria del processo.
 */
@interface NFQueuedDownloadRuntime : NSObject

@property (copy, nonatomic) NSURLRequest *request;
@property (copy, nonatomic) NFDownloadProgressBlock progressBlock;
@property (copy, nonatomic) NFDownloadCompletionBlock completionBlock;

@end

@implementation NFQueuedDownloadRuntime
@end


@interface NFDownloadManager ()

- (void)publishFinishedSeasonNotificationBatches;

- (BOOL)recordSeasonNotificationResultForItemId:
    (NSString *)itemId
    success:(BOOL)success;

@property (strong, nonatomic) NSURLSession *session;
@property (strong, nonatomic)
    NSMutableDictionary<NSNumber *, NFDownloadContext *> *contexts;

/*
 * Ordine esplicito dei download.
 * Contiene i taskIdentifier nell'ordine di inserimento.
 */
@property (strong, nonatomic)
    NSMutableArray<NSNumber *> *queueOrder;

/* Job FIFO non ancora affidati a NSURLSession. */
@property (strong, nonatomic)
    NSMutableArray<NSDictionary *> *pendingJobs;

@property (strong, nonatomic)
    NSMutableDictionary<NSString *, NFQueuedDownloadRuntime *>
        *pendingRuntime;

/*
 * Impedisce a callback concorrenti di creare
 * due task iOS per lo stesso slot FIFO.
 */
@property (assign, nonatomic)
    BOOL materializingPendingJob;

/*
 * Un solo download alla volta.
 */
@property (strong, nonatomic, nullable)
    NSNumber *activeTaskIdentifier;

/*
 * Completion fornito da UIApplicationDelegate quando
 * NineFin viene risvegliata per eventi background.
 */
@property (copy, nonatomic, nullable)
    void (^backgroundEventsCompletionHandler)();

/*
 * Protegge dal raro caso in cui NSURLSession abbia già
 * terminato di consegnare gli eventi prima che
 * l'AppDelegate registri il completion handler.
 */
@property (assign, nonatomic)
    BOOL backgroundEventsFinishedAwaitingHandler;

/*
 * Il caso degli eventi consegnati prima
 * dell'AppDelegate è ammesso soltanto
 * durante il lancio iniziale in background.
 */
@property (assign, nonatomic)
    BOOL backgroundStartupMayRegisterLateHandler;

@property (assign, nonatomic)
    BOOL backgroundWakeInProgress;

@property (assign, nonatomic)
    BOOL advanceQueueAfterBackgroundEvents;

/*
 * Finché iOS non ci ha restituito l'elenco completo
 * dei task della background session non autorizziamo
 * la FIFO ad avviare nuovi transfer.
 */
@property (assign, nonatomic)
    BOOL backgroundRestoreComplete;

/*
 * Non persistiamo mai questo blocco.
 * Viene registrato nuovamente ad ogni avvio.
 */
@property (copy, nonatomic, nullable)
    NFPersistedDownloadRequestBuilder
        persistentRequestBuilder;

@end


@implementation NFDownloadManager

+ (instancetype)sharedManager {
    static NFDownloadManager *manager;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        manager = [[NFDownloadManager alloc] init];
    });

    return manager;
}

- (instancetype)init {
    self = [super init];

    if (self) {
        _contexts = [NSMutableDictionary dictionary];
        _queueOrder = [NSMutableArray array];
        _pendingJobs = [NSMutableArray array];
        _pendingRuntime = [NSMutableDictionary dictionary];

        _backgroundStartupMayRegisterLateHandler =
            [UIApplication sharedApplication].applicationState ==
                UIApplicationStateBackground;

        /*
         * Sessione persistente gestita da iOS.
         *
         * I transfer continuano anche quando NineFin
         * viene sospesa e possono sopravvivere a una
         * terminazione dell'app da parte del sistema.
         */
        NSURLSessionConfiguration *configuration =
            [NSURLSessionConfiguration
                backgroundSessionConfigurationWithIdentifier:
                    NFDownloadBackgroundSessionIdentifier];

        configuration.requestCachePolicy =
            NSURLRequestReloadIgnoringLocalCacheData;

        configuration.timeoutIntervalForRequest =
            60.0;

        configuration.timeoutIntervalForResource =
            0;

        /*
         * iOS può rilanciare NineFin per consegnare
         * gli eventi della background URL session.
         */
        configuration.sessionSendsLaunchEvents =
            YES;

        /*
         * Il download parte quando lo decidiamo noi:
         * niente scheduling "opportunistico".
         */
        configuration.discretionary =
            NO;

        /*
         * La FIFO NineFin decide già quale task
         * può essere attivo.
         */
        configuration.HTTPMaximumConnectionsPerHost =
            1;

        NSOperationQueue *queue =
            [[NSOperationQueue alloc] init];

        queue.name = @"dev.luke.ninefin.download.delegate";
        queue.maxConcurrentOperationCount = 1;

        _session = [NSURLSession
            sessionWithConfiguration:configuration
            delegate:self
            delegateQueue:queue];

        NSLog(
            @"NineFin background session ready: %@",
            NFDownloadBackgroundSessionIdentifier);

        [self ensureDownloadsDirectory];

        /*
         * Recupera eventuali transfer posseduti da iOS
         * dopo un precedente processo NineFin.
         */
        [self restoreBackgroundTasks];
    }

    return self;
}





#pragma mark - Persistent request bridge

- (void)configurePersistedDownloadRequestBuilder:
    (NFPersistedDownloadRequestBuilder)builder {

    @synchronized (self) {
        self.persistentRequestBuilder =
            [builder copy];
    }

    NSLog(
        @"NineFin persistent queue: "
         "authentication builder registered");

    [self startNextDownloadIfNeeded];
}


/*
 * Utilizzato dal futuro motore FIFO logico.
 *
 * Non crea alcun task e non modifica la coda.
 */
- (NSMutableURLRequest *)requestForPersistedJob:
    (NSDictionary *)job {

    NFPersistedDownloadRequestBuilder builder =
        nil;

    @synchronized (self) {
        builder =
            [self.persistentRequestBuilder copy];
    }

    if (!builder) {
        NSLog(
            @"NineFin persistent queue: "
             "authentication builder unavailable");

        return nil;
    }

    return builder(job);
}


#pragma mark - Background session lifecycle

- (void)handleBackgroundEventsForSessionIdentifier:
    (NSString *)identifier
    completionHandler:(void (^)())completionHandler {

    if (!completionHandler)
        return;


    /*
     * Gestiamo soltanto la sessione NineFin.
     */
    if (![identifier isEqualToString:
            NFDownloadBackgroundSessionIdentifier]) {

        NSLog(
            @"NineFin background: identifier inatteso %@",
            identifier ?: @"<nil>");

        dispatch_async(
            dispatch_get_main_queue(),
            completionHandler);

        return;
    }


    void (^handlerToCall)() =
        nil;


    @synchronized (self) {

        self.backgroundStartupMayRegisterLateHandler = NO;

        /*
         * Se NSURLSession aveva già comunicato
         * URLSessionDidFinishEvents..., possiamo
         * chiudere subito il ciclo background.
         */
        if (self.backgroundEventsFinishedAwaitingHandler) {

            self.backgroundEventsFinishedAwaitingHandler =
                NO;

            handlerToCall =
                [completionHandler copy];

        } else {

            self.backgroundWakeInProgress = YES;

            self.backgroundEventsCompletionHandler =
                [completionHandler copy];
        }
    }


    NSLog(
        @"NineFin background: AppDelegate handler registered");


    if (handlerToCall) {

        dispatch_async(
            dispatch_get_main_queue(),
            handlerToCall);
    }
}



#pragma mark - Logical queue restore

- (void)restoreLogicalQueueManifest {

    id stored =
        [[NSUserDefaults standardUserDefaults]
            objectForKey:NFPendingQueueManifestDefaultsKey];

    NSArray *records =
        [stored isKindOfClass:[NSArray class]]
            ? stored : @[];

    NSUInteger legacyRecovered = 0;
    NSUInteger legacyMissingURL = 0;

    @synchronized (self.contexts) {

        /*
         * Durante il restore possono essere entrati
         * nuovi job tramite l'interfaccia.
         *
         * Hanno precedenza rispetto a eventuali
         * vecchie copie presenti nel manifest.
         */
        NSArray *runtimeJobs =
            [self.pendingJobs copy];

        NSArray *mergedRecords =
            [runtimeJobs
                arrayByAddingObjectsFromArray:records];

        [self.pendingJobs removeAllObjects];

        NSMutableSet *seen = [NSMutableSet set];

        for (NFDownloadContext *context
             in self.contexts.allValues) {

            if (context.itemId.length)
                [seen addObject:context.itemId];
        }

        for (id object in mergedRecords) {

            if (![object isKindOfClass:[NSDictionary class]])
                continue;

            NSDictionary *record = object;

            /*
             * v2: job logico NineFin.
             * v1: task legacy rimasto nel manifest.
             *
             * Se iOS possiede ancora il task,
             * il relativo itemId e' gia' in seen.
             */
            id logicalValue = record[@"logical"];
            id versionValue = record[@"v"];

            BOOL isLogical =
                [logicalValue isKindOfClass:[NSNumber class]] &&
                [logicalValue boolValue];

            BOOL isLegacy =
                !isLogical &&
                [versionValue isKindOfClass:[NSNumber class]] &&
                [versionValue integerValue] == 1;

            if (!isLogical && !isLegacy)
                continue;

            if (isLegacy &&
                (![record[@"requestURL"]
                    isKindOfClass:[NSString class]] ||
                 ![record[@"requestURL"] length])) {

                legacyMissingURL++;
                continue;
            }

            NSString *itemId = record[@"itemId"];
            NSString *filename = record[@"filename"];
            NSString *urlString = record[@"requestURL"];
            NSNumber *sequence = record[@"sequence"];
            NSString *title = record[@"title"];

            if (![itemId isKindOfClass:[NSString class]] ||
                !itemId.length ||
                ![filename isKindOfClass:[NSString class]] ||
                !filename.length ||
                ![urlString isKindOfClass:[NSString class]] ||
                !urlString.length ||
                ![sequence isKindOfClass:[NSNumber class]] ||
                sequence.integerValue <= 0)
                continue;

            if ([seen containsObject:itemId])
                continue;

            NSString *prefix =
                [itemId stringByAppendingString:@"."];

            if (![filename hasPrefix:prefix] ||
                [filename containsString:@"/"] ||
                [filename containsString:@"\\"])
                continue;

            NSURLComponents *components =
                [NSURLComponents
                    componentsWithString:urlString];

            NSString *scheme =
                components.scheme.lowercaseString;

            if (!([scheme isEqualToString:@"http"] ||
                  [scheme isEqualToString:@"https"]) ||
                !components.host.length ||
                components.user.length ||
                components.password.length ||
                components.percentEncodedQuery.length ||
                components.percentEncodedFragment.length)
                continue;

            if (![title isKindOfClass:[NSString class]] ||
                !title.length)
                title = @"Contenuto";

            NSURL *destination =
                [[self downloadsDirectoryURL]
                    URLByAppendingPathComponent:filename];

            if ([[NSFileManager defaultManager]
                    fileExistsAtPath:destination.path])
                continue;

            NSDictionary *job = @{
                @"v": @2,
                @"logical": @YES,
                @"itemId": itemId,
                @"filename": filename,
                @"requestURL": urlString,
                @"sequence": sequence,
                @"title": title
            };

            [self.pendingJobs addObject:job];
            [seen addObject:itemId];

            if (isLegacy)
                legacyRecovered++;
        }

        [self.pendingJobs sortUsingComparator:
            ^NSComparisonResult(
                NSDictionary *a, NSDictionary *b) {

            NSComparisonResult result =
                [a[@"sequence"] compare:b[@"sequence"]];

            if (result != NSOrderedSame)
                return result;

            return [a[@"itemId"] compare:b[@"itemId"]];
        }];
    }

    NSLog(
        @"NineFin logical queue restored: %lu job; "
         "legacy recovered=%lu, missing URL=%lu",
        (unsigned long)self.pendingJobs.count,
        (unsigned long)legacyRecovered,
        (unsigned long)legacyMissingURL);
}


#pragma mark - Background identity / restore

/*
 * Snapshot persistente della FIFO NineFin.
 *
 * Salva soltanto dati non segreti.
 * Le credenziali verranno ricostruite tramite
 * il sistema di autenticazione esistente.
 *
 * Per ora non modifica il scheduling dei task.
 */
- (void)persistPendingQueueManifest {

    NSMutableArray *records =
        [NSMutableArray array];

    @synchronized (self.contexts) {

        /*
         * Prima del restore completo non conosciamo
         * ancora tutti i task posseduti da iOS.
         *
         * Salvare adesso potrebbe cancellare dal
         * manifest i job logici non ancora ripristinati.
         */
        if (!self.backgroundRestoreComplete) {

            NSLog(
                @"NineFin manifest: waiting for initial restore");

            return;
        }

        for (NSNumber *identifier in self.queueOrder) {

            NFDownloadContext *context =
                self.contexts[identifier];

            if (!context ||
                !context.itemId.length ||
                !context.destinationURL.lastPathComponent.length)
                continue;

            NSURLRequest *request =
                context.task.originalRequest ?:
                context.task.currentRequest;

            NSURL *url = request.URL;

            NSString *safeURL = @"";

            /*
             * Non persistere URL con credenziali
             * incorporate o parametri di query.
             */
            if (url &&
                !url.user.length &&
                !url.password.length &&
                !url.query.length &&
                !url.fragment.length) {

                safeURL = url.absoluteString ?: @"";
            }

            [records addObject:@{
                @"v": @1,
                @"itemId": context.itemId,
                @"filename":
                    context.destinationURL.lastPathComponent,
                @"title":
                    context.displayTitle ?: @"Contenuto",
                @"sequence":
                    @(context.queueSequence),
                @"requestURL":
                    safeURL
            }];
        }

        for (NSDictionary *job in self.pendingJobs) {
            [records addObject:job];
        }

        NSUserDefaults *defaults =
            [NSUserDefaults standardUserDefaults];

        if (records.count) {
            [defaults
                setObject:records
                forKey:NFPendingQueueManifestDefaultsKey];
        } else {
            [defaults
                removeObjectForKey:
                    NFPendingQueueManifestDefaultsKey];
        }

        [defaults synchronize];
    }

    NSLog(
        @"NineFin queue manifest: %lu job",
        (unsigned long)records.count);
}



- (NSInteger)nextQueueSequence {

    NSUserDefaults *defaults =
        [NSUserDefaults standardUserDefaults];

    NSInteger value =
        [defaults integerForKey:
            NFDownloadQueueSequenceDefaultsKey];

    value++;

    if (value <= 0)
        value = 1;

    [defaults setInteger:value
        forKey:
            NFDownloadQueueSequenceDefaultsKey];

    [defaults synchronize];

    return value;
}


- (NSString *)taskDescriptionForItemId:(NSString *)itemId
                        destinationURL:(NSURL *)destinationURL
                              sequence:(NSInteger)sequence
                          displayTitle:(NSString *)displayTitle {

    if (!itemId.length ||
        !destinationURL.lastPathComponent.length) {

        return nil;
    }

    NSString *safeTitle =
        ([displayTitle isKindOfClass:[NSString class]] &&
         displayTitle.length)
            ? displayTitle
            : @"Contenuto";

    NSDictionary *payload = @{
        @"v": @1,
        @"itemId": itemId,
        @"filename":
            destinationURL.lastPathComponent,
        @"sequence":
            @(sequence),
        @"title":
            safeTitle
    };

    NSError *error = nil;

    NSData *data =
        [NSJSONSerialization
            dataWithJSONObject:payload
            options:0
            error:&error];

    if (!data.length) {

        NSLog(
            @"NineFin background identity encode error: %@",
            error);

        return nil;
    }

    return [[NSString alloc]
        initWithData:data
        encoding:NSUTF8StringEncoding];
}


- (NSDictionary *)identityForTask:(NSURLSessionTask *)task {

    NSString *description =
        task.taskDescription;

    if (!description.length)
        return nil;

    NSData *data =
        [description
            dataUsingEncoding:
                NSUTF8StringEncoding];

    if (!data.length)
        return nil;

    NSError *error = nil;

    id object =
        [NSJSONSerialization
            JSONObjectWithData:data
            options:0
            error:&error];

    if (![object isKindOfClass:
            [NSDictionary class]]) {

        if (error) {
            NSLog(
                @"NineFin background identity decode error: %@",
                error);
        }

        return nil;
    }

    NSDictionary *identity =
        (NSDictionary *)object;

    NSString *itemId =
        identity[@"itemId"];

    NSString *filename =
        identity[@"filename"];

    NSNumber *sequence =
        identity[@"sequence"];

    if (![itemId isKindOfClass:
            [NSString class]] ||
        !itemId.length ||
        ![filename isKindOfClass:
            [NSString class]] ||
        !filename.length ||
        ![sequence isKindOfClass:
            [NSNumber class]]) {

        return nil;
    }

    return identity;
}


/*
 * Deve essere chiamato con contexts già protetto
 * da @synchronized(self.contexts).
 */
- (void)rebuildQueueOrderLocked {

    NSArray *identifiers =
        [self.contexts.allKeys
            sortedArrayUsingComparator:
                ^NSComparisonResult(
                    NSNumber *a,
                    NSNumber *b) {

        NFDownloadContext *ca =
            self.contexts[a];

        NFDownloadContext *cb =
            self.contexts[b];

        if (ca.queueSequence <
            cb.queueSequence) {

            return NSOrderedAscending;
        }

        if (ca.queueSequence >
            cb.queueSequence) {

            return NSOrderedDescending;
        }

        return [a compare:b];
    }];


    [self.queueOrder
        removeAllObjects];

    self.activeTaskIdentifier =
        nil;


    for (NSNumber *identifier
         in identifiers) {

        NFDownloadContext *context =
            self.contexts[identifier];

        if (!context)
            continue;

        NSURLSessionTaskState state =
            context.task.state;

        if (state !=
                NSURLSessionTaskStateRunning &&
            state !=
                NSURLSessionTaskStateSuspended) {

            continue;
        }

        [self.queueOrder
            addObject:identifier];


        /*
         * Solo il task realmente Running
         * viene considerato slot attivo.
         */
        if (state ==
                NSURLSessionTaskStateRunning &&
            !self.activeTaskIdentifier) {

            self.activeTaskIdentifier =
                identifier;

            context.queued =
                NO;

        } else {

            context.queued =
                YES;
        }
    }
}


/*
 * Ricrea un NFDownloadContext anche se NineFin
 * è stata rilanciata e i blocchi originali
 * non esistono più.
 */
- (NFDownloadContext *)contextForTask:
    (NSURLSessionTask *)task {

    if (!task)
        return nil;

    NSNumber *identifier =
        @(task.taskIdentifier);


    @synchronized (self.contexts) {

        NFDownloadContext *existing =
            self.contexts[identifier];

        if (existing)
            return existing;
    }


    if (![task isKindOfClass:
            [NSURLSessionDownloadTask class]]) {

        return nil;
    }


    NSDictionary *identity =
        [self identityForTask:task];

    if (!identity)
        return nil;


    NSString *itemId =
        identity[@"itemId"];

    NSString *filename =
        identity[@"filename"];

    NSInteger sequence =
        [identity[@"sequence"]
            integerValue];

    NSString *displayTitle =
        identity[@"title"];

    if (![displayTitle isKindOfClass:
            [NSString class]] ||
        !displayTitle.length) {

        displayTitle =
            @"Contenuto";
    }


    NSURL *destination =
        [[self downloadsDirectoryURL]
            URLByAppendingPathComponent:
                filename
            isDirectory:NO];


    NFDownloadContext *context =
        [[NFDownloadContext alloc] init];

    context.itemId =
        itemId;

    context.displayTitle =
        displayTitle;

    context.destinationURL =
        destination;

    context.task =
        (NSURLSessionDownloadTask *)task;

    context.queueSequence =
        sequence;

    context.queued =
        task.state !=
            NSURLSessionTaskStateRunning;


    int64_t expected =
        task.countOfBytesExpectedToReceive;

    int64_t received =
        task.countOfBytesReceived;

    if (expected > 0 &&
        received >= 0) {

        context.progress =
            MIN(
                1.0,
                MAX(
                    0.0,
                    (double)received /
                    (double)expected));
    }


    @synchronized (self.contexts) {

        NFDownloadContext *existing =
            self.contexts[identifier];

        if (existing)
            return existing;

        self.contexts[identifier] =
            context;

        [self rebuildQueueOrderLocked];
    }


    NSLog(
        @"NineFin background restored task %lu: %@",
        (unsigned long)task.taskIdentifier,
        itemId);

    return context;
}


- (void)restoreBackgroundTasks {

    __weak NFDownloadManager *weakSelf =
        self;

    [self.session
        getTasksWithCompletionHandler:^(
            NSArray *dataTasks,
            NSArray *uploadTasks,
            NSArray *downloadTasks) {

        (void)dataTasks;
        (void)uploadTasks;

        NFDownloadManager *manager =
            weakSelf;

        if (!manager)
            return;


        for (NSURLSessionDownloadTask *task
             in downloadTasks) {

            [manager
                contextForTask:task];
        }


        [manager restoreLogicalQueueManifest];

        @synchronized (manager.contexts) {

            /*
             * Ricostruiamo prima contexts/FIFO completa.
             * Solo dopo autorizziamo startNextDownloadIfNeeded.
             */
            [manager
                rebuildQueueOrderLocked];

            manager.backgroundRestoreComplete =
                YES;
        }


        NSLog(
            @"NineFin background restore complete: %lu task",
            (unsigned long)
                downloadTasks.count);


        /*
         * Se il precedente task è già terminato
         * mentre NineFin era fuori dalla RAM,
         * facciamo avanzare la FIFO.
         */
        [manager persistPendingQueueManifest];

        [manager
            startNextDownloadIfNeeded];
    }];
}


#pragma mark - Queue

/*
 * Operazione idempotente.
 *
 * Il materializzatore esistente impedisce di
 * occupare due volte lo slot attivo.
 */

#pragma mark - Season notification batches

/*
 * Il gruppo viene registrato prima degli enqueue.
 * A fine ciclo viene confermato con gli ID accettati.
 *
 * Nessuna credenziale viene salvata.
 */
- (NSString *)beginSeasonNotificationBatchWithTitle:(NSString *)title
                                            itemIds:(NSArray<NSString *> *)itemIds {

    if (![itemIds isKindOfClass:[NSArray class]])
        return nil;

    NSMutableArray *unique = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];

    for (id value in itemIds) {
        if (![value isKindOfClass:[NSString class]] ||
            ![value length] ||
            [seen containsObject:value])
            continue;

        [seen addObject:value];
        [unique addObject:value];
    }

    if (!unique.count)
        return nil;

    NSString *safeTitle =
        ([title isKindOfClass:[NSString class]] && title.length)
            ? title : @"Stagione";

    NSString *batchID = [[NSUUID UUID] UUIDString];

    @synchronized (self) {

        NSUserDefaults *defaults =
            [NSUserDefaults standardUserDefaults];

        id saved = [defaults objectForKey:
            NFSeasonNotificationBatchesDefaultsKey];

        NSMutableDictionary *batches =
            [saved isKindOfClass:[NSDictionary class]]
                ? [saved mutableCopy]
                : [NSMutableDictionary dictionary];

        batches[batchID] = @{
            @"title": safeTitle,
            @"itemIds": unique,
            @"completed": @[],
            @"failed": @[],
            @"sealed": @NO
        };

        [defaults setObject:batches
                    forKey:NFSeasonNotificationBatchesDefaultsKey];

        [defaults synchronize];
    }

    NSLog(@"NineFin season batch registered: %lu episodes",
          (unsigned long)unique.count);

    return batchID;
}


- (void)finishSeasonNotificationBatch:(NSString *)batchID
                      acceptedItemIds:(NSArray<NSString *> *)acceptedItemIds {

    if (!batchID.length)
        return;

    @synchronized (self) {

        NSUserDefaults *defaults =
            [NSUserDefaults standardUserDefaults];

        id saved = [defaults objectForKey:
            NFSeasonNotificationBatchesDefaultsKey];

        if (![saved isKindOfClass:[NSDictionary class]])
            return;

        NSMutableDictionary *batches = [saved mutableCopy];
        id current = batches[batchID];

        if (![current isKindOfClass:[NSDictionary class]])
            return;

        NSMutableDictionary *batch = [current mutableCopy];

        NSSet *planned =
            [NSSet setWithArray:batch[@"itemIds"] ?: @[]];

        NSMutableArray *accepted = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];

        for (id value in acceptedItemIds) {

            if (![value isKindOfClass:[NSString class]] ||
                ![planned containsObject:value] ||
                [seen containsObject:value])
                continue;

            [accepted addObject:value];
            [seen addObject:value];
        }

        if (!accepted.count) {

            [batches removeObjectForKey:batchID];

        } else {

            batch[@"itemIds"] = accepted;
            batch[@"sealed"] = @YES;
            batches[batchID] = batch;
        }

        if (batches.count) {

            [defaults setObject:batches
                        forKey:NFSeasonNotificationBatchesDefaultsKey];

        } else {

            [defaults removeObjectForKey:
                NFSeasonNotificationBatchesDefaultsKey];
        }

        [defaults synchronize];

        NSLog(@"NineFin season batch sealed: %lu episodes",
              (unsigned long)accepted.count);
    }

    /*
     * Il gruppo potrebbe essere già terminato
     * mentre stavamo ancora accodando episodi.
     */
    [self publishFinishedSeasonNotificationBatches];
}



#pragma mark - Season batch results


/*
 * I riepiloghi restano persistenti finché
 * l'AppDelegate non ne conferma la consegna.
 */
- (NSArray<NSDictionary *> *)
    pendingSeasonNotificationSummaries {

    @synchronized (self) {

        NSDictionary *stored =
            [[NSUserDefaults standardUserDefaults]
                dictionaryForKey:
                    NFSeasonNotificationOutboxDefaultsKey];

        NSMutableArray *result =
            [NSMutableArray array];

        for (NSString *batchID in stored) {

            NSString *message = stored[batchID];

            if (![batchID isKindOfClass:[NSString class]] ||
                ![message isKindOfClass:[NSString class]] ||
                !batchID.length ||
                !message.length)
                continue;

            [result addObject:@{
                @"batchID": batchID,
                @"message": message
            }];
        }

        return result;
    }
}


- (void)acknowledgeSeasonNotificationSummary:
    (NSString *)batchID {

    if (!batchID.length)
        return;

    @synchronized (self) {

        NSUserDefaults *defaults =
            [NSUserDefaults standardUserDefaults];

        NSDictionary *stored =
            [defaults dictionaryForKey:
                NFSeasonNotificationOutboxDefaultsKey];

        if (!stored[batchID])
            return;

        NSMutableDictionary *outbox =
            [stored mutableCopy];

        [outbox removeObjectForKey:batchID];

        if (outbox.count) {
            [defaults setObject:outbox
                        forKey:
                            NFSeasonNotificationOutboxDefaultsKey];
        } else {
            [defaults removeObjectForKey:
                NFSeasonNotificationOutboxDefaultsKey];
        }

        [defaults synchronize];

        NSLog(
            @"NineFin season summary outbox: acknowledged");
    }
}


- (void)publishFinishedSeasonNotificationBatches {

    NSMutableArray *ready = [NSMutableArray array];

    @synchronized (self) {

        NSUserDefaults *defaults =
            [NSUserDefaults standardUserDefaults];

        NSDictionary *stored =
            [defaults dictionaryForKey:
                NFSeasonNotificationBatchesDefaultsKey];

        if (!stored.count)
            return;

        NSMutableDictionary *batches =
            [stored mutableCopy];

        for (NSString *batchID in stored) {

            NSDictionary *batch = stored[batchID];

            if (![batch isKindOfClass:
                    [NSDictionary class]] ||
                ![batch[@"sealed"] boolValue])
                continue;

            NSArray *items = batch[@"itemIds"];
            NSArray *completed = batch[@"completed"];
            NSArray *failed = batch[@"failed"];

            if (![items isKindOfClass:[NSArray class]] ||
                ![completed isKindOfClass:[NSArray class]] ||
                ![failed isKindOfClass:[NSArray class]])
                continue;

            if (!items.count ||
                completed.count + failed.count < items.count)
                continue;

            NSString *title = batch[@"title"];

            if (![title isKindOfClass:[NSString class]] ||
                !title.length)
                title = @"Stagione";

            NSString *message = nil;

            if (failed.count) {

                message = [NSString stringWithFormat:
                    @"%@: %lu/%lu episodi scaricati, "
                     "%lu non completati.",
                    title,
                    (unsigned long)completed.count,
                    (unsigned long)items.count,
                    (unsigned long)failed.count];

            } else {

                message = [NSString stringWithFormat:
                    @"%@: %lu episodi disponibili offline.",
                    title,
                    (unsigned long)completed.count];
            }

            [ready addObject:@{
                @"message": message,
                @"batchID": batchID
            }];

            [batches removeObjectForKey:batchID];
        }

        if (ready.count) {

            /*
             * Prima rendiamo persistente il riepilogo,
             * poi rimuoviamo il batch completato.
             */
            NSDictionary *savedOutbox =
                [defaults dictionaryForKey:
                    NFSeasonNotificationOutboxDefaultsKey];

            NSMutableDictionary *outbox =
                savedOutbox
                    ? [savedOutbox mutableCopy]
                    : [NSMutableDictionary dictionary];

            for (NSDictionary *info in ready) {
                outbox[info[@"batchID"]] =
                    info[@"message"];
            }

            [defaults setObject:outbox
                        forKey:
                            NFSeasonNotificationOutboxDefaultsKey];

            if (batches.count) {

                [defaults setObject:batches
                    forKey:
                        NFSeasonNotificationBatchesDefaultsKey];

            } else {

                [defaults removeObjectForKey:
                    NFSeasonNotificationBatchesDefaultsKey];
            }

            [defaults synchronize];
        }
    }

    /*
     * Pubblicazione fuori dal lock.
     * L'AppDelegate riceverà l'evento e
     * programmerà una sola notifica locale.
     */
    for (NSDictionary *info in ready) {

        NSLog(
            @"NineFin season batch summary ready: %@",
            info[@"batchID"]);

        [[NSNotificationCenter defaultCenter]
            postNotificationName:
                NFDownloadManagerSeasonBatchDidFinishNotification
            object:self
            userInfo:info];
    }
}


- (BOOL)recordSeasonNotificationResultForItemId:
    (NSString *)itemId
    success:(BOOL)success {

    if (!itemId.length)
        return NO;

    BOOL belongsToBatch = NO;
    BOOL changed = NO;

    @synchronized (self) {

        NSUserDefaults *defaults =
            [NSUserDefaults standardUserDefaults];

        NSDictionary *stored =
            [defaults dictionaryForKey:
                NFSeasonNotificationBatchesDefaultsKey];

        if (!stored.count)
            return NO;

        NSMutableDictionary *batches =
            [stored mutableCopy];

        for (NSString *batchID in stored) {

            NSDictionary *batch = stored[batchID];

            if (![batch isKindOfClass:
                    [NSDictionary class]])
                continue;

            NSArray *items = batch[@"itemIds"];

            if (![items isKindOfClass:[NSArray class]] ||
                ![items containsObject:itemId])
                continue;

            belongsToBatch = YES;

            NSArray *done = batch[@"completed"] ?: @[];
            NSArray *failed = batch[@"failed"] ?: @[];

            /*
             * Un episodio già contabilizzato
             * non può essere contato nuovamente.
             */
            if ([done containsObject:itemId] ||
                [failed containsObject:itemId])
                continue;

            NSMutableDictionary *updated =
                [batch mutableCopy];

            NSString *field =
                success ? @"completed" : @"failed";

            NSMutableArray *outcomes =
                [updated[field] mutableCopy];

            if (!outcomes)
                outcomes = [NSMutableArray array];

            [outcomes addObject:itemId];

            updated[field] = outcomes;
            batches[batchID] = updated;

            changed = YES;
        }

        if (changed) {

            [defaults setObject:batches
                forKey:
                    NFSeasonNotificationBatchesDefaultsKey];

            [defaults synchronize];
        }
    }

    if (belongsToBatch) {

        NSLog(
            @"NineFin season batch result: %@ (%@)",
            itemId,
            success ? @"ok" : @"failed/cancelled");

        [self publishFinishedSeasonNotificationBatches];
    }

    return belongsToBatch;
}


- (void)retryPendingDownloads {

    if ([UIApplication sharedApplication].applicationState ==
            UIApplicationStateActive) {

        @synchronized (self) {

            self.backgroundStartupMayRegisterLateHandler = NO;
            self.backgroundEventsFinishedAwaitingHandler = NO;
        }
    }

    NSUInteger pendingCount = 0;

    @synchronized (self.contexts) {
        pendingCount = self.pendingJobs.count;
    }

    if (pendingCount) {

        NSLog(
            @"NineFin logical queue: retry %lu job",
            (unsigned long)pendingCount);
    }

    [self startNextDownloadIfNeeded];
}


- (void)startNextDownloadIfNeeded {

    /*
     * FIFO classica: quando un task termina,
     * il successivo viene ripreso immediatamente,
     * anche durante la consegna degli eventi
     * della background NSURLSession.
     */
    NSURLSessionDownloadTask *taskToStart = nil;
    BOOL persistMaterializedTaskAfterResume = NO;

    NSString *startedItemId = nil;

    NSDictionary *logicalJob = nil;

    NFQueuedDownloadRuntime *logicalRuntime = nil;
    BOOL completedLogicalJobAlreadyPresent = NO;
    NSString *skippedCompletedItemId = nil;

    /*
     * PRIMA FASE
     *
     * Decidiamo chi occupa il prossimo slot:
     * - task iOS legacy
     * - job logico NineFin
     */
    @synchronized (self.contexts) {

        if (!self.backgroundRestoreComplete)
            return;

        if (self.materializingPendingJob)
            return;

        /*
         * Non liberiamo lo slot finché
         * didCompleteWithError non ha rimosso
         * il relativo context.
         */
        if (self.activeTaskIdentifier) {

            NFDownloadContext *active =
                self.contexts[
                    self.activeTaskIdentifier];

            if (active)
                return;

            self.activeTaskIdentifier = nil;
        }

        /*
         * Rimuoviamo identificativi obsoleti
         * dalla FIFO dei task legacy.
         */
        while (self.queueOrder.count) {

            NSNumber *identifier =
                self.queueOrder.firstObject;

            NFDownloadContext *context =
                self.contexts[identifier];

            if (context &&
                context.task.state !=
                    NSURLSessionTaskStateCompleted) {

                break;
            }

            [self.queueOrder
                removeObjectAtIndex:0];
        }

        NSNumber *legacyIdentifier =
            self.queueOrder.firstObject;

        NFDownloadContext *legacy =
            legacyIdentifier
                ? self.contexts[legacyIdentifier]
                : nil;

        NSDictionary *pending =
            self.pendingJobs.firstObject;

        NSInteger legacySequence =
            legacy ? legacy.queueSequence : NSIntegerMax;

        NSInteger pendingSequence =
            pending
                ? [pending[@"sequence"] integerValue]
                : NSIntegerMax;

        /*
         * Rispettiamo la sequenza originale
         * anche durante la migrazione dalla
         * vecchia FIFO.
         */
        if (legacy &&
            (!pending ||
             legacySequence <= pendingSequence)) {

            legacy.queued = NO;

            self.activeTaskIdentifier =
                legacyIdentifier;

            taskToStart = legacy.task;

            startedItemId =
                [legacy.itemId copy];

        } else if (pending) {

            NSString *filename = pending[@"filename"];
            NSURL *destination =
                [[self downloadsDirectoryURL]
                    URLByAppendingPathComponent:filename
                    isDirectory:NO];

            if (filename.length &&
                [[NSFileManager defaultManager]
                    fileExistsAtPath:destination.path]) {

                [self.pendingJobs removeObjectAtIndex:0];
                [self.pendingRuntime
                    removeObjectForKey:pending[@"itemId"]];

                completedLogicalJobAlreadyPresent = YES;
                skippedCompletedItemId =
                    [pending[@"itemId"] copy];

            } else {

                self.materializingPendingJob = YES;

                logicalJob = [pending copy];

                logicalRuntime =
                    self.pendingRuntime[
                        logicalJob[@"itemId"]];
            }
        }
    }


    if (completedLogicalJobAlreadyPresent) {

        [self recordSeasonNotificationResultForItemId:
            skippedCompletedItemId
            success:YES];

        [self persistPendingQueueManifest];

        NSLog(
            @"NineFin FIFO reconciliation: completed file already exists");

        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:
                    NFDownloadManagerQueueDidChangeNotification
                object:self
                userInfo:skippedCompletedItemId.length
                    ? @{@"itemId": skippedCompletedItemId}
                    : nil];
        });

        [self startNextDownloadIfNeeded];
        return;
    }

    /*
     * SECONDA FASE
     *
     * Per un job logico recuperiamo
     * la richiesta autenticata.
     *
     * Non teniamo bloccato contexts durante
     * l'accesso al Keychain.
     */
    if (logicalJob) {

        NSMutableURLRequest *request = nil;

        if (logicalRuntime.request) {

            request =
                [logicalRuntime.request mutableCopy];

        } else {

            request =
                [self requestForPersistedJob:
                    logicalJob];
        }

        NSString *expectedURL =
            logicalJob[@"requestURL"];

        NSString *method =
            request.HTTPMethod ?: @"GET";

        NSString *authorization =
            [request valueForHTTPHeaderField:
                @"Authorization"];

        BOOL valid =
            request.URL &&
            [request.URL.absoluteString
                isEqualToString:expectedURL] &&
            [method isEqualToString:@"GET"] &&
            authorization.length > 0;

        if (!valid) {

            @synchronized (self.contexts) {
                self.materializingPendingJob = NO;
            }

            /*
             * Non eliminiamo il job:
             * il Keychain potrebbe essere
             * temporaneamente indisponibile.
             */
            NSLog(
                @"NineFin logical queue: "
                 "authenticated request unavailable");

            return;
        }

        /*
         * TERZA FASE
         *
         * Materializziamo il task solamente
         * se il job è ancora nella FIFO.
         *
         * Una cancellazione potrebbe averlo
         * rimosso mentre leggevamo il Keychain.
         */
        BOOL materialized = NO;
        BOOL removedWhilePreparing = NO;

        @synchronized (self.contexts) {

            NSUInteger index =
                [self.pendingJobs
                    indexOfObject:logicalJob];

            if (index == NSNotFound ||
                self.activeTaskIdentifier) {

                removedWhilePreparing = YES;

            } else {

                NSString *itemId =
                    logicalJob[@"itemId"];

                NSString *filename =
                    logicalJob[@"filename"];

                NSString *title =
                    logicalJob[@"title"];

                NSInteger sequence =
                    [logicalJob[@"sequence"]
                        integerValue];

                NSURL *destination =
                    [[self downloadsDirectoryURL]
                        URLByAppendingPathComponent:
                            filename
                        isDirectory:NO];

                NSString *description =
                    [self
                        taskDescriptionForItemId:
                            itemId
                        destinationURL:destination
                        sequence:sequence
                        displayTitle:title];

                if (description.length) {

                    NSURLSessionDownloadTask *task =
                        [self.session
                            downloadTaskWithRequest:
                                request];

                    if (task) {

                        task.taskDescription =
                            description;

                        NFDownloadContext *context =
                            [[NFDownloadContext alloc] init];

                        context.itemId = itemId;
                        context.displayTitle = title;
                        context.destinationURL = destination;
                        context.task = task;
                        context.queueSequence = sequence;
                        context.progress = 0.0;
                        context.queued = NO;

                        context.progressBlock =
                            logicalRuntime.progressBlock;

                        context.completionBlock =
                            logicalRuntime.completionBlock;

                        NSNumber *identifier =
                            @(task.taskIdentifier);

                        self.contexts[identifier] =
                            context;

                        /*
                         * Il job logico era il primo
                         * elemento per sequenza.
                         */
                        [self.queueOrder
                            insertObject:identifier
                            atIndex:0];

                        self.activeTaskIdentifier =
                            identifier;

                        [self.pendingJobs
                            removeObjectAtIndex:index];

                        [self.pendingRuntime
                            removeObjectForKey:itemId];

                        taskToStart = task;

                        startedItemId =
                            [itemId copy];

                        materialized = YES;
                    }
                }
            }

            self.materializingPendingJob = NO;
        }

        if (materialized) {

            /*
             * Il manifest va aggiornato dopo resume.
             * Il restore gestira' anche eventuali
             * record legacy rimasti sul disco.
             */
            persistMaterializedTaskAfterResume = YES;

            NSLog(
                @"NineFin logical task materialized: %@",
                startedItemId);

        } else {

            if (removedWhilePreparing) {

                /*
                 * Il job è stato annullato:
                 * possiamo cercare il successivo.
                 */
                [self startNextDownloadIfNeeded];

            } else {

                NSLog(
                    @"NineFin logical queue: "
                     "materialization failed");
            }

            return;
        }
    }


    /*
     * QUARTA FASE
     *
     * Da qui in avanti usiamo il normale
     * NSURLSessionDownloadTask, conservando
     * delegate, progresso e notifiche esistenti.
     */
    if (taskToStart) {

        NSLog(
            @"NineFin download queue: starting %@",
            startedItemId ?: @"<unknown>");

        [taskToStart resume];

        if (persistMaterializedTaskAfterResume) {

            [self persistPendingQueueManifest];

            NSLog(
                @"NineFin logical task resumed and manifest updated");
        }

        NSString *changedItemId =
            [startedItemId copy];

        dispatch_async(
            dispatch_get_main_queue(), ^{

            [[NSNotificationCenter defaultCenter]
                postNotificationName:
                    NFDownloadManagerQueueDidChangeNotification
                object:self
                userInfo:
                    changedItemId.length
                        ? @{@"itemId": changedItemId}
                        : nil];
        });
    }
}


#pragma mark - Paths

- (NSURL *)downloadsDirectoryURL {
    NSURL *documents =
        [[[NSFileManager defaultManager]
            URLsForDirectory:NSDocumentDirectory
            inDomains:NSUserDomainMask] firstObject];

    return [documents URLByAppendingPathComponent:
        @"NineFinDownloads"
        isDirectory:YES];
}

- (BOOL)ensureDownloadsDirectory {
    NSURL *directory = [self downloadsDirectoryURL];

    BOOL isDirectory = NO;
    BOOL exists = [[NSFileManager defaultManager]
        fileExistsAtPath:directory.path
        isDirectory:&isDirectory];

    if (exists && isDirectory)
        return YES;

    if (exists) {
        [[NSFileManager defaultManager]
            removeItemAtURL:directory
            error:NULL];
    }

    NSError *error = nil;

    BOOL result = [[NSFileManager defaultManager]
        createDirectoryAtURL:directory
        withIntermediateDirectories:YES
        attributes:nil
        error:&error];

    if (!result) {
        NSLog(@"NineFin download directory error: %@",
              error);
    }

    return result;
}

- (NSString *)safeExtension:(NSString *)fileExtension {
    NSString *value =
        [fileExtension stringByTrimmingCharactersInSet:
            [NSCharacterSet
                characterSetWithCharactersInString:@". \t\r\n"]];

    if (!value.length)
        return @"media";

    NSCharacterSet *invalid =
        [[NSCharacterSet alphanumericCharacterSet]
            invertedSet];

    value = [[value
        componentsSeparatedByCharactersInSet:invalid]
        componentsJoinedByString:@""];

    if (!value.length)
        return @"media";

    return value.lowercaseString;
}

- (NSURL *)localURLForItemId:(NSString *)itemId
               fileExtension:(NSString *)fileExtension {

    NSString *extension =
        [self safeExtension:fileExtension];

    NSString *filename = [NSString stringWithFormat:
        @"%@.%@", itemId, extension];

    return [[self downloadsDirectoryURL]
        URLByAppendingPathComponent:filename
        isDirectory:NO];
}


#pragma mark - Query

- (BOOL)isDownloadedItemId:(NSString *)itemId
              fileExtension:(NSString *)fileExtension {

    if (!itemId.length)
        return NO;

    NSURL *url =
        [self localURLForItemId:itemId
                  fileExtension:fileExtension];

    return [[NSFileManager defaultManager]
        fileExistsAtPath:url.path];
}

- (NFDownloadContext *)contextForItemId:(NSString *)itemId {
    if (!itemId.length)
        return nil;

    @synchronized (self.contexts) {
        for (NFDownloadContext *context
             in self.contexts.allValues) {

            if ([context.itemId isEqualToString:itemId])
                return context;
        }
    }

    return nil;
}

- (BOOL)isDownloadingItemId:(NSString *)itemId {
    NFDownloadContext *context =
        [self contextForItemId:itemId];

    if (!context) {

        @synchronized (self.contexts) {

            for (NSDictionary *job in self.pendingJobs) {

                if ([job[@"itemId"]
                        isEqualToString:itemId]) {

                    return YES;
                }
            }
        }

        return NO;
    }

    NSURLSessionTaskState state =
        context.task.state;

    return state == NSURLSessionTaskStateRunning ||
           state == NSURLSessionTaskStateSuspended;
}

- (double)progressForItemId:(NSString *)itemId {
    NFDownloadContext *context =
        [self contextForItemId:itemId];

    return context ? context.progress : 0.0;
}

- (NSArray<NSDictionary *> *)activeDownloads {

    NSMutableArray *result =
        [NSMutableArray array];

    @synchronized (self.contexts) {

        /*
         * queueOrder è la nostra FIFO ufficiale:
         * niente contexts.allValues, che non ha
         * un ordine deterministico.
         */
        for (NSNumber *identifier in self.queueOrder) {

            NFDownloadContext *context =
                self.contexts[identifier];

            if (!context)
                continue;


            NSURLSessionTaskState state =
                context.task.state;

            if (state !=
                    NSURLSessionTaskStateRunning &&
                state !=
                    NSURLSessionTaskStateSuspended) {

                continue;
            }


            NSString *filename =
                context.destinationURL.lastPathComponent
                    ?: @"";


            [result addObject:@{
                @"itemId":
                    context.itemId ?: @"",

                @"filename":
                    filename,

                @"progress":
                    @(context.progress),

                /*
                 * queued == YES:
                 * task creato ma non ancora
                 * autorizzato a partire.
                 */
                @"queued":
                    @(context.queued)
            }];
        }

        /*
         * Gli elementi non ancora materializzati
         * devono comparire nella stessa coda UI.
         */
        for (NSDictionary *job in self.pendingJobs) {

            NSString *itemId = job[@"itemId"];
            NSString *filename = job[@"filename"];

            if (!itemId.length || !filename.length)
                continue;

            [result addObject:@{
                @"itemId": itemId,
                @"filename": filename,
                @"progress": @0.0,
                @"queued": @YES
            }];
        }
    }

    return result;
}


- (NSArray<NSURL *> *)downloadedFiles {
    [self ensureDownloadsDirectory];

    NSError *error = nil;

    NSArray *files =
        [[NSFileManager defaultManager]
            contentsOfDirectoryAtURL:
                [self downloadsDirectoryURL]
            includingPropertiesForKeys:nil
            options:NSDirectoryEnumerationSkipsHiddenFiles
            error:&error];

    if (!files) {
        if (error) {
            NSLog(@"NineFin download listing error: %@",
                  error);
        }

        return @[];
    }

    return [files sortedArrayUsingComparator:
        ^NSComparisonResult(NSURL *a, NSURL *b) {
            return [a.lastPathComponent
                localizedCaseInsensitiveCompare:
                    b.lastPathComponent];
        }];
}


#pragma mark - Start / cancel / remove

/*
 * Bridge temporaneo.
 * Il vecchio scheduling rimane invariato.
 */
/*
 * Accodamento logico NineFin.
 *
 * NON crea NSURLSessionDownloadTask.
 * I transfer saranno materializzati uno alla volta
 * dal nuovo motore FIFO.
 *
 * Il manifest conserva esclusivamente dati non segreti.
 */
/*
 * FIFO classica NineFin.
 *
 * Tutti i task vengono creati durante l'enqueue.
 * Soltanto il primo viene avviato; gli altri
 * restano sospesi nella sessione background iOS.
 *
 * Manteniamo il supporto ai pendingJobs precedenti
 * tramite il materializzatore ancora presente.
 */
- (BOOL)enqueueDownloadWithRequest:(NSURLRequest *)request
                            itemId:(NSString *)itemId
                     fileExtension:(NSString *)fileExtension
                      displayTitle:(NSString *)displayTitle
                          progress:(NFDownloadProgressBlock)progress
                        completion:(NFDownloadCompletionBlock)completion {

    NSURLSessionDownloadTask *task =
        [self startDownloadWithRequest:request
                                itemId:itemId
                         fileExtension:fileExtension
                          displayTitle:displayTitle
                              progress:progress
                            completion:completion];

    if (task) {
        NSLog(
            @"NineFin FIFO legacy enqueue: task created");
    }

    return task != nil;
}


- (NSURLSessionDownloadTask *)
    startDownloadWithRequest:(NSURLRequest *)request
                      itemId:(NSString *)itemId
               fileExtension:(NSString *)fileExtension
                displayTitle:(NSString *)displayTitle
                    progress:(NFDownloadProgressBlock)progress
                  completion:(NFDownloadCompletionBlock)completion {

    if (!request.URL || !itemId.length) {
        if (completion) {
            NSError *error = [NSError
                errorWithDomain:NFDownloadErrorDomain
                code:1
                userInfo:@{
                    NSLocalizedDescriptionKey:
                        @"Richiesta download non valida."
                }];

            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, error);
            });
        }

        return nil;
    }

    NFDownloadContext *existing =
        [self contextForItemId:itemId];

    if (existing &&
        (existing.task.state ==
            NSURLSessionTaskStateRunning ||
         existing.task.state ==
            NSURLSessionTaskStateSuspended)) {

        return existing.task;
    }

    if (![self ensureDownloadsDirectory]) {
        if (completion) {
            NSError *error = [NSError
                errorWithDomain:NFDownloadErrorDomain
                code:2
                userInfo:@{
                    NSLocalizedDescriptionKey:
                        @"Impossibile creare la cartella Download."
                }];

            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, error);
            });
        }

        return nil;
    }

    NSURLSessionDownloadTask *task =
        [self.session downloadTaskWithRequest:request];

    NFDownloadContext *context =
        [[NFDownloadContext alloc] init];

    context.itemId = itemId;

    context.displayTitle =
        ([displayTitle isKindOfClass:[NSString class]] &&
         displayTitle.length)
            ? displayTitle
            : @"Contenuto";

    context.destinationURL =
        [self localURLForItemId:itemId
                  fileExtension:fileExtension];

    context.progressBlock = progress;
    context.completionBlock = completion;
    context.task = task;
    context.progress = 0.0;
    context.queued = YES;

    context.queueSequence =
        [self nextQueueSequence];

    task.taskDescription =
        [self
            taskDescriptionForItemId:itemId
            destinationURL:
                context.destinationURL
            sequence:
                context.queueSequence
            displayTitle:
                context.displayTitle];

    if (!task.taskDescription.length) {

        NSLog(
            @"NineFin background identity missing: %@",
            itemId);
    }

    NSNumber *identifier =
        @(task.taskIdentifier);

    @synchronized (self.contexts) {

        self.contexts[identifier] =
            context;

        [self.queueOrder
            addObject:identifier];
    }

    [self persistPendingQueueManifest];

    NSLog(
        @"NineFin download queued: %@ -> %@",
        itemId,
        context.destinationURL.lastPathComponent);

    /*
     * Se nessun altro download è attivo
     * questo partirà immediatamente.
     *
     * Altrimenti resta sospeso in FIFO.
     */
    [self startNextDownloadIfNeeded];

    return task;
}

- (void)cancelDownloadForItemId:(NSString *)itemId {

    if (!itemId.length)
        return;

    NFQueuedDownloadRuntime *runtime = nil;
    BOOL removedLogical = NO;

    @synchronized (self.contexts) {

        NSUInteger index = NSNotFound;

        for (NSUInteger i = 0;
             i < self.pendingJobs.count;
             i++) {

            NSDictionary *job =
                self.pendingJobs[i];

            if ([job[@"itemId"]
                    isEqualToString:itemId]) {

                index = i;
                break;
            }
        }

        if (index != NSNotFound) {

            runtime =
                self.pendingRuntime[itemId];

            [self.pendingJobs
                removeObjectAtIndex:index];

            [self.pendingRuntime
                removeObjectForKey:itemId];

            removedLogical = YES;
        }
    }

    if (removedLogical) {

        [self recordSeasonNotificationResultForItemId:
            itemId
            success:NO];

        [self persistPendingQueueManifest];

        /*
         * Se era il primo job in attesa,
         * possiamo tentare subito il successivo.
         */
        [self retryPendingDownloads];

        NSLog(
            @"NineFin logical queue cancelled: %@",
            itemId);

        NFDownloadCompletionBlock completion =
            runtime.completionBlock;

        dispatch_async(dispatch_get_main_queue(), ^{

            if (completion) {

                NSError *error =
                    [NSError
                        errorWithDomain:NSURLErrorDomain
                        code:NSURLErrorCancelled
                        userInfo:nil];

                completion(nil, error);
            }

            [[NSNotificationCenter defaultCenter]
                postNotificationName:
                    NFDownloadManagerQueueDidChangeNotification
                object:self
                userInfo:@{@"itemId": itemId}];
        });

        return;
    }

    NFDownloadContext *context =
        [self contextForItemId:itemId];

    if (!context)
        return;

    NSLog(@"NineFin download cancel: %@",
          itemId);

    [context.task cancel];
}

- (BOOL)removeDownloadedItemId:(NSString *)itemId
                 fileExtension:(NSString *)fileExtension
                         error:(NSError **)error {

    if (!itemId.length)
        return NO;

    NSURL *url =
        [self localURLForItemId:itemId
                  fileExtension:fileExtension];

    if (![[NSFileManager defaultManager]
            fileExistsAtPath:url.path]) {
        return YES;
    }

    return [[NSFileManager defaultManager]
        removeItemAtURL:url
        error:error];
}


#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
 totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {

    NFDownloadContext *context =
        [self contextForTask:
            downloadTask];

    if (!context)
        return;

    double fraction = 0.0;

    if (totalBytesExpectedToWrite > 0) {
        fraction =
            (double)totalBytesWritten /
            (double)totalBytesExpectedToWrite;

        if (fraction < 0.0)
            fraction = 0.0;

        if (fraction > 1.0)
            fraction = 1.0;
    }

    context.progress = fraction;

    NFDownloadProgressBlock progress =
        context.progressBlock;

    if (progress) {
        dispatch_async(dispatch_get_main_queue(), ^{
            progress(bytesWritten,
                     totalBytesWritten,
                     totalBytesExpectedToWrite);
        });
    }
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didFinishDownloadingToURL:(NSURL *)location {

    NFDownloadContext *context =
        [self contextForTask:
            downloadTask];

    if (!context)
        return;

    NSHTTPURLResponse *response =
        (NSHTTPURLResponse *)downloadTask.response;

    if ([response isKindOfClass:
            [NSHTTPURLResponse class]] &&
        (response.statusCode < 200 ||
         response.statusCode >= 300)) {

        context.finalError = [NSError
            errorWithDomain:NFDownloadErrorDomain
            code:response.statusCode
            userInfo:@{
                NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:
                        @"Download Jellyfin fallito: HTTP %ld.",
                        (long)response.statusCode]
            }];

        return;
    }

    NSFileManager *fm =
        [NSFileManager defaultManager];

    NSError *error = nil;

    if ([fm fileExistsAtPath:
            context.destinationURL.path]) {

        NSDictionary *attributes =
            [fm attributesOfItemAtPath:
                context.destinationURL.path
                error:&error];

        BOOL validExistingFile =
            [attributes[NSFileType]
                isEqualToString:NSFileTypeRegular] &&
            [attributes[NSFileSize]
                unsignedLongLongValue] > 0;

        if (validExistingFile) {

            context.destinationAlreadyPresent = YES;
            context.movedToDestination = YES;
            context.progress = 1.0;

            NSLog(
                @"NineFin duplicate download: preserved existing file");

            return;
        }

        context.finalError = error ?: [NSError
            errorWithDomain:NFDownloadErrorDomain
            code:6
            userInfo:@{
                NSLocalizedDescriptionKey:
                    @"File locale esistente non valido: non sovrascritto."
            }];

        return;
    }

    if (![fm moveItemAtURL:location
                     toURL:context.destinationURL
                     error:&error]) {

        context.finalError = error;
        return;
    }

    context.progress = 1.0;
    context.movedToDestination = YES;

    NSLog(@"NineFin download complete: %@",
          context.destinationURL.lastPathComponent);
}



#pragma mark - NSURLSessionDelegate

- (void)URLSessionDidFinishEventsForBackgroundURLSession:
    (NSURLSession *)session {

    (void)session;

    void (^completion)() = nil;
    BOOL advanceQueue = NO;

    @synchronized (self) {

        completion =
            self.backgroundEventsCompletionHandler;

        self.backgroundEventsCompletionHandler =
            nil;

        if (!completion) {

            /*
             * Un callback ordinario non deve lasciare
             * uno stato pendente per il risveglio futuro.
             */
            self.backgroundEventsFinishedAwaitingHandler =
                self.backgroundStartupMayRegisterLateHandler &&
                [UIApplication sharedApplication].applicationState ==
                    UIApplicationStateBackground;
        }

        self.backgroundWakeInProgress = NO;

        advanceQueue =
            self.advanceQueueAfterBackgroundEvents;

        self.advanceQueueAfterBackgroundEvents =
            NO;
    }

    NSLog(
        @"NineFin background: NSURLSession events finished");

    if (completion || advanceQueue) {

        dispatch_async(
            dispatch_get_main_queue(), ^{

            if (advanceQueue) {

                NSLog(
                    @"NineFin background FIFO: "
                     "resuming after events");

                [self retryPendingDownloads];
            }

            if (completion) {
                completion();
            }
        });
    }
}


#pragma mark - NSURLSessionTaskDelegate

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
 didCompleteWithError:(NSError *)error {

    NFDownloadContext *context =
        [self contextForTask:task];

    NSNumber *identifier =
        @(task.taskIdentifier);

    @synchronized (self.contexts) {

        [self.contexts
            removeObjectForKey:
                identifier];

        [self.queueOrder
            removeObject:
                identifier];

        if ([self.activeTaskIdentifier
                isEqualToNumber:identifier]) {

            self.activeTaskIdentifier =
                nil;
        }
    }


    [self persistPendingQueueManifest];

    /*
     * Anche nel caso eccezionale in cui il
     * context non esista più, non lasciamo
     * la FIFO bloccata.
     */
    if (!context) {

        [self startNextDownloadIfNeeded];

        return;
    }

    NSError *finalError =
        error ?: context.finalError;

    NSURL *localURL =
        (!finalError && context.movedToDestination)
            ? context.destinationURL
            : nil;

    if (!finalError &&
        !context.movedToDestination) {

        finalError = [NSError
            errorWithDomain:NFDownloadErrorDomain
            code:3
            userInfo:@{
                NSLocalizedDescriptionKey:
                    @"Il download è terminato senza un file locale valido."
            }];
    }

    /*
     * Un vecchio task può concludersi dopo che
     * il suo manifest v1 è stato recuperato.
     *
     * Riconciliamo soltanto la stessa identità:
     * itemId + sequence + filename.
     */
    if (!finalError && localURL) {

        BOOL removedPendingDuplicate = NO;

        NSMutableArray<NSURLSessionTask *> *duplicateTasks =
            [NSMutableArray array];

        @synchronized (self.contexts) {

            for (NSInteger i =
                     (NSInteger)self.pendingJobs.count - 1;
                 i >= 0; i--) {

                NSDictionary *job =
                    self.pendingJobs[(NSUInteger)i];

                if ([job[@"itemId"]
                        isEqualToString:context.itemId] &&
                    [job[@"filename"]
                        isEqualToString:
                            context.destinationURL.lastPathComponent] &&
                    [job[@"sequence"] integerValue] ==
                        context.queueSequence) {

                    [self.pendingJobs
                        removeObjectAtIndex:(NSUInteger)i];

                    [self.pendingRuntime
                        removeObjectForKey:context.itemId];

                    removedPendingDuplicate = YES;
                }
            }

            for (NFDownloadContext *candidate
                 in self.contexts.allValues) {

                if ([candidate.itemId
                        isEqualToString:context.itemId] &&
                    candidate.queueSequence ==
                        context.queueSequence &&
                    [candidate.destinationURL.lastPathComponent
                        isEqualToString:
                            context.destinationURL.lastPathComponent] &&
                    candidate.task.state !=
                        NSURLSessionTaskStateCompleted) {

                    [duplicateTasks addObject:candidate.task];
                }
            }
        }

        if (removedPendingDuplicate)
            [self persistPendingQueueManifest];

        for (NSURLSessionTask *duplicate in duplicateTasks)
            [duplicate cancel];

        if (removedPendingDuplicate || duplicateTasks.count)
            NSLog(
                @"NineFin FIFO reconciliation: duplicate job reconciled");
    }

    /*
     * Registra successo, errore o annullamento.
     * Se appartiene a una stagione, evita
     * la notifica individuale.
     */
    BOOL seasonEpisode =
        [self recordSeasonNotificationResultForItemId:
            context.itemId
            success:(!finalError && localURL != nil)];

    /*
     * Evento globale indipendente dai blocchi UI.
     *
     * Dopo un relaunch background completionBlock può
     * essere nil, ma questo evento viene comunque emesso.
     */
    if (!finalError && localURL &&
        !context.destinationAlreadyPresent &&
        !seasonEpisode) {

        NSString *title =
            context.displayTitle.length
                ? context.displayTitle
                : @"Contenuto";

        [[NSNotificationCenter defaultCenter]
            postNotificationName:
                NFDownloadManagerDidCompleteNotification
            object:self
            userInfo:@{
                @"title":
                    title,
                @"itemId":
                    context.itemId ?: @"",
                @"filename":
                    context.destinationURL.lastPathComponent
                        ?: @""
            }];

        NSLog(
            @"NineFin download completion event: %@",
            title);
    }


    NFDownloadCompletionBlock completion =
        context.completionBlock;

    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(localURL, finalError);
        });
    }

    if (finalError) {
        NSLog(@"NineFin download error %@: %@",
              context.itemId,
              finalError);
    }


    /*
     * Slot libero: facciamo avanzare la FIFO.
     *
     * Vale sia per:
     * - completamento corretto
     * - errore
     * - cancellazione
     */
    [self startNextDownloadIfNeeded];
}

@end
