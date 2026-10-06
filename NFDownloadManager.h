#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^NFDownloadProgressBlock)(
    int64_t bytesWritten,
    int64_t totalBytesWritten,
    int64_t totalBytesExpectedToWrite
);

typedef void (^NFDownloadCompletionBlock)(
    NSURL * _Nullable localURL,
    NSError * _Nullable error
);

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

- (nullable NSURLSessionDownloadTask *)
    startDownloadWithRequest:(NSURLRequest *)request
                      itemId:(NSString *)itemId
               fileExtension:(nullable NSString *)fileExtension
                    progress:(nullable NFDownloadProgressBlock)progress
                  completion:(nullable NFDownloadCompletionBlock)completion;

- (void)cancelDownloadForItemId:(NSString *)itemId;

- (BOOL)removeDownloadedItemId:(NSString *)itemId
                 fileExtension:(nullable NSString *)fileExtension
                         error:(NSError * _Nullable * _Nullable)error;

- (NSArray<NSDictionary *> *)activeDownloads;

- (NSArray<NSURL *> *)downloadedFiles;

@end

NS_ASSUME_NONNULL_END
