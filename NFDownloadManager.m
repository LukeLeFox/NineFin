#import "NFDownloadManager.h"

static NSString * const NFDownloadErrorDomain =
    @"dev.luke.ninefin.download";

@interface NFDownloadContext : NSObject

@property (copy, nonatomic) NSString *itemId;
@property (strong, nonatomic) NSURL *destinationURL;
@property (copy, nonatomic, nullable) NFDownloadProgressBlock progressBlock;
@property (copy, nonatomic, nullable) NFDownloadCompletionBlock completionBlock;
@property (strong, nonatomic) NSURLSessionDownloadTask *task;
@property (assign, nonatomic) double progress;
@property (assign, nonatomic) BOOL movedToDestination;
@property (strong, nonatomic, nullable) NSError *finalError;

@end

@implementation NFDownloadContext
@end


@interface NFDownloadManager ()

@property (strong, nonatomic) NSURLSession *session;
@property (strong, nonatomic)
    NSMutableDictionary<NSNumber *, NFDownloadContext *> *contexts;

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

        NSURLSessionConfiguration *configuration =
            [NSURLSessionConfiguration defaultSessionConfiguration];

        configuration.requestCachePolicy =
            NSURLRequestReloadIgnoringLocalCacheData;

        configuration.timeoutIntervalForRequest = 60.0;
        configuration.timeoutIntervalForResource = 0;

        NSOperationQueue *queue =
            [[NSOperationQueue alloc] init];

        queue.name = @"dev.luke.ninefin.download.delegate";
        queue.maxConcurrentOperationCount = 1;

        _session = [NSURLSession
            sessionWithConfiguration:configuration
            delegate:self
            delegateQueue:queue];

        [self ensureDownloadsDirectory];
    }

    return self;
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

    if (!context)
        return NO;

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
        for (NFDownloadContext *context
             in self.contexts.allValues) {

            NSURLSessionTaskState state =
                context.task.state;

            if (state != NSURLSessionTaskStateRunning &&
                state != NSURLSessionTaskStateSuspended)
                continue;

            NSString *filename =
                context.destinationURL.lastPathComponent
                    ?: @"";

            [result addObject:@{
                @"itemId": context.itemId ?: @"",
                @"filename": filename,
                @"progress": @(context.progress)
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

- (NSURLSessionDownloadTask *)
    startDownloadWithRequest:(NSURLRequest *)request
                      itemId:(NSString *)itemId
               fileExtension:(NSString *)fileExtension
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
    context.destinationURL =
        [self localURLForItemId:itemId
                  fileExtension:fileExtension];

    context.progressBlock = progress;
    context.completionBlock = completion;
    context.task = task;
    context.progress = 0.0;

    @synchronized (self.contexts) {
        self.contexts[@(task.taskIdentifier)] =
            context;
    }

    NSLog(@"NineFin download start: %@ -> %@",
          itemId,
          context.destinationURL.lastPathComponent);

    [task resume];

    return task;
}

- (void)cancelDownloadForItemId:(NSString *)itemId {
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

    NFDownloadContext *context = nil;

    @synchronized (self.contexts) {
        context =
            self.contexts[@(downloadTask.taskIdentifier)];
    }

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

    NFDownloadContext *context = nil;

    @synchronized (self.contexts) {
        context =
            self.contexts[@(downloadTask.taskIdentifier)];
    }

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

        if (![fm removeItemAtURL:
                context.destinationURL
                error:&error]) {

            context.finalError = error;
            return;
        }
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


#pragma mark - NSURLSessionTaskDelegate

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
 didCompleteWithError:(NSError *)error {

    NFDownloadContext *context = nil;

    @synchronized (self.contexts) {
        context =
            self.contexts[@(task.taskIdentifier)];

        [self.contexts
            removeObjectForKey:
                @(task.taskIdentifier)];
    }

    if (!context)
        return;

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
}

@end
