#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const
    NFDownloadManagerDidCompleteNotification;

FOUNDATION_EXPORT NSString * const
    NFDownloadManagerQueueDidChangeNotification;

FOUNDATION_EXPORT NSString * const
    NFDownloadManagerSeasonBatchDidFinishNotification;

typedef void (^NFDownloadProgressBlock)(
    int64_t bytesWritten,
    int64_t totalBytesWritten,
    int64_t totalBytesExpectedToWrite
);

typedef void (^NFDownloadCompletionBlock)(
    NSURL * _Nullable localURL,
    NSError * _Nullable error
);

/*
 * Il chiamante ricostruisce l'autenticazione
 * senza fornire al manager accesso al Keychain.
 *
 * nil indica che la richiesta non è disponibile.
 */
typedef NSMutableURLRequest * _Nullable
    (^NFPersistedDownloadRequestBuilder)(
        NSDictionary *job);

@interface NFDownloadManager : NSObject
    <NSURLSessionDownloadDelegate, NSURLSessionTaskDelegate>

+ (instancetype)sharedManager;

- (NSURL *)downloadsDirectoryURL;

- (NSURL *)localURLForItemId:(NSString *)itemId
               fileExtension:(nullable NSString *)fileExtension;

- (BOOL)isDownloadedItemId:(NSString *)itemId
              fileExtension:(nullable NSString *)fileExtension;

- (BOOL)isDownloadingItemId:(NSString *)itemId;

- (double)progressForItemId:(NSString *)itemId;

/*
 * YES = richiesta accettata dalla FIFO.
 * Il task iOS può essere creato successivamente.
 */
- (BOOL)enqueueDownloadWithRequest:(NSURLRequest *)request
                            itemId:(NSString *)itemId
                     fileExtension:(nullable NSString *)fileExtension
                      displayTitle:(nullable NSString *)displayTitle
                          progress:(nullable NFDownloadProgressBlock)progress
                        completion:(nullable NFDownloadCompletionBlock)completion;

- (nullable NSURLSessionDownloadTask *)
    startDownloadWithRequest:(NSURLRequest *)request
                      itemId:(NSString *)itemId
               fileExtension:(nullable NSString *)fileExtension
                displayTitle:(nullable NSString *)displayTitle
                    progress:(nullable NFDownloadProgressBlock)progress
                  completion:(nullable NFDownloadCompletionBlock)completion;

- (void)cancelDownloadForItemId:(NSString *)itemId;

- (BOOL)removeDownloadedItemId:(NSString *)itemId
                 fileExtension:(nullable NSString *)fileExtension
                         error:(NSError * _Nullable * _Nullable)error;

/*
 * Da registrare dopo il ripristino delle sessioni.
 */
- (void)configurePersistedDownloadRequestBuilder:
    (NFPersistedDownloadRequestBuilder)builder;

/*
 * Riprova l'avvio della FIFO quando l'ambiente
 * torna disponibile.
 */
- (void)retryPendingDownloads;

/* Riepiloghi persistenti non ancora consegnati. */
- (NSArray<NSDictionary *> *)
    pendingSeasonNotificationSummaries;

- (void)acknowledgeSeasonNotificationSummary:
    (NSString *)batchID;

/* Gruppi notifiche per download di stagione. */
- (nullable NSString *)beginSeasonNotificationBatchWithTitle:(NSString *)title
                                                   itemIds:(NSArray<NSString *> *)itemIds;

- (void)finishSeasonNotificationBatch:(NSString *)batchID
                      acceptedItemIds:(NSArray<NSString *> *)acceptedItemIds;

- (NSArray<NSDictionary *> *)activeDownloads;

- (NSArray<NSURL *> *)downloadedFiles;

/*
 * iOS chiama l'AppDelegate quando deve consegnare
 * gli eventi della background NSURLSession.
 *
 * Il manager conserva il completion handler fino a
 * URLSessionDidFinishEventsForBackgroundURLSession:.
 */
- (void)handleBackgroundEventsForSessionIdentifier:
    (NSString *)identifier
    completionHandler:(void (^)())completionHandler;

@end

NS_ASSUME_NONNULL_END
