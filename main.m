#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>

static NSString *NFServer;
static NSString *NFToken;
static NSString *NFUser;
static NSCache *NFImageCache;

static NSInteger NFStreamingBitrate(void) {
    NSInteger b = [[NSUserDefaults standardUserDefaults]
        integerForKey:@"NineFin.StreamingBitrate"];

    return (b == 800000 || b == 1500000 ||
            b == 2500000 || b == 4000000)
        ? b : 1500000;
}


static BOOL NFHomeRailEnabled(NSInteger kind) {
    if (kind < 0 || kind > 3) return NO;

    NSString *key = [NSString stringWithFormat:
        @"NineFin.Home.%ld", (long)kind];

    id value = [[NSUserDefaults standardUserDefaults]
        objectForKey:key];

    // Home compatta alla prima installazione.
    return value ? [value boolValue] : (kind < 2);
}

static OSStatus NFSessionSaveStatus = errSecSuccess;
static OSStatus NFCredentialsSaveStatus = errSecSuccess;

static UIColor *NFBG(void) {
    return [UIColor colorWithRed:0.055 green:0.075 blue:0.105 alpha:1];
}
static UIColor *NFPanel(void) {
    return [UIColor colorWithRed:0.105 green:0.135 blue:0.185 alpha:1];
}
static UIColor *NFAccent(void) {
    return [UIColor colorWithRed:0.19 green:0.78 blue:0.85 alpha:1];
}
static UIColor *NFSecondary(void) {
    return [UIColor colorWithRed:0.63 green:0.69 blue:0.76 alpha:1];
}


typedef void (^NFResult)(id result, NSError *error);

static NSString *NFDevice(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *v = [d stringForKey:@"NineFinDeviceId"];
    if (!v.length) {
        v = [[NSUUID UUID] UUIDString];
        [d setObject:v forKey:@"NineFinDeviceId"];
        [d synchronize];
    }
    return v;
}


static NSString *NFCleanServer(NSString *value) {
    NSString *url = [value
        stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];

    while ([url hasSuffix:@"/"])
        url = [url substringToIndex:url.length - 1];

    return url;
}

static NSArray *NFServerList(void) {
    id stored = [[NSUserDefaults standardUserDefaults]
        objectForKey:@"NineFin.Servers"];

    if (![stored isKindOfClass:[NSArray class]])
        return @[];

    NSMutableArray *servers = [NSMutableArray array];

    for (id entry in stored) {
        if ([entry isKindOfClass:[NSString class]] &&
            [entry length] &&
            ![servers containsObject:entry])
            [servers addObject:entry];
    }
    return servers;
}

static void NFRememberServer(NSString *value) {
    NSString *server = NFCleanServer(value);
    NSURL *url = [NSURL URLWithString:server];

    if (!url.host.length ||
        !([url.scheme.lowercaseString isEqualToString:@"http"] ||
          [url.scheme.lowercaseString isEqualToString:@"https"]))
        return;

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSMutableArray *servers = [NFServerList() mutableCopy];

    if (![servers containsObject:server]) {
        [servers addObject:server];
        [d setObject:servers forKey:@"NineFin.Servers"];
    }

    if (![d stringForKey:@"NineFin.DefaultServer"])
        [d setObject:server forKey:@"NineFin.DefaultServer"];

    [d synchronize];
}

static NSDictionary *NFKeychainQueryForAccount(NSString *account) {
    return @{
        (__bridge id)kSecClass:
            (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService:
            @"dev.luke.ninefin.session",
        (__bridge id)kSecAttrAccount: account ?: @""
    };
}

static NSDictionary *NFReadSession(NSString *account) {
    if (!account.length) return nil;

    NSMutableDictionary *query =
        [NFKeychainQueryForAccount(account) mutableCopy];

    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] =
        (__bridge id)kSecMatchLimitOne;

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching(
        (__bridge CFDictionaryRef)query, &result);

    if (status != errSecSuccess || !result)
        return nil;

    NSData *data = CFBridgingRelease(result);

    id session = [NSJSONSerialization
        JSONObjectWithData:data options:0 error:NULL];

    return [session isKindOfClass:[NSDictionary class]]
        ? session : nil;
}


static NSString *NFCredentialsAccount(NSString *server) {
    return [NFCleanServer(server)
        stringByAppendingString:@"|credentials"];
}

static void NFStoreLoginCredentials(NSString *server,
                                    NSString *username,
                                    NSString *password) {
    if (!server.length || !username.length) return;

    NSDictionary *entry = @{
        @"username": username,
        @"password": password ?: @""
    };

    NSData *data = [NSJSONSerialization
        dataWithJSONObject:entry options:0 error:NULL];
    if (!data) return;

    NSMutableDictionary *q =
        [NFKeychainQueryForAccount(
            NFCredentialsAccount(server)) mutableCopy];

    SecItemDelete((__bridge CFDictionaryRef)q);

    q[(__bridge id)kSecValueData] = data;
    q[(__bridge id)kSecAttrAccessible] =
        (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;

    OSStatus status =
        SecItemAdd((__bridge CFDictionaryRef)q, NULL);

    NFCredentialsSaveStatus = status;
    NSLog(@"NineFin credentials Keychain status: %d",
          (int)status);
}

static NSDictionary *NFLoginCredentials(NSString *server) {
    if (!server.length) return nil;
    return NFReadSession(NFCredentialsAccount(server));
}

static void NFSave(void) {
    if (!NFServer.length || !NFToken.length || !NFUser.length)
        return;

    NFServer = NFCleanServer(NFServer);
    NFRememberServer(NFServer);

    NSMutableDictionary *query =
        [NFKeychainQueryForAccount(NFServer) mutableCopy];

    SecItemDelete((__bridge CFDictionaryRef)query);

    NSDictionary *session = @{
        @"server": NFServer,
        @"token": NFToken,
        @"user": NFUser
    };

    NSData *data = [NSJSONSerialization
        dataWithJSONObject:session options:0 error:NULL];

    if (!data) return;

    query[(__bridge id)kSecValueData] = data;
    query[(__bridge id)kSecAttrAccessible] =
        (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;

    OSStatus status =
        SecItemAdd((__bridge CFDictionaryRef)query, NULL);

    NFSessionSaveStatus = status;
    NSLog(@"NineFin session Keychain status: %d", (int)status);
}

static void NFActivateServer(NSString *value) {
    NFServer = [NFCleanServer(value) copy];
    NFToken = nil;
    NFUser = nil;

    NSDictionary *session = NFReadSession(NFServer);

    if ([session[@"token"] isKindOfClass:[NSString class]] &&
        [session[@"user"] isKindOfClass:[NSString class]]) {
        NFToken = session[@"token"];
        NFUser = session[@"user"];
    }

    if (NFServer.length) {
        [[NSUserDefaults standardUserDefaults]
            setObject:NFServer forKey:@"NineFin.Server"];
    }
}

static void NFRestore(void) {
    NSUserDefaults *defaults =
        [NSUserDefaults standardUserDefaults];

    // Migrazione dalla sessione unica di NineFin 0.3.
    if (!NFServerList().count) {
        NSDictionary *old = NFReadSession(@"jellyfin");

        if ([old[@"server"] isKindOfClass:[NSString class]] &&
            [old[@"token"] isKindOfClass:[NSString class]] &&
            [old[@"user"] isKindOfClass:[NSString class]]) {
            NFServer = old[@"server"];
            NFToken = old[@"token"];
            NFUser = old[@"user"];
            NFSave();
        }
    }

    NSArray *servers = NFServerList();

    NSString *selected =
        [defaults stringForKey:@"NineFin.DefaultServer"];

    if (![servers containsObject:selected])
        selected = servers.firstObject;

    if (selected.length)
        NFActivateServer(selected);
}

static void NFLogout(void) {
    if (NFServer.length) {
        NSDictionary *query =
            NFKeychainQueryForAccount(NFServer);
        SecItemDelete((__bridge CFDictionaryRef)query);
    }

    NFToken = nil;
    NFUser = nil;
}

static NSURL *NFURL(NSString *path) {
    if ([path hasPrefix:@"media:"])
        path = [path substringFromIndex:6];

    if ([path hasPrefix:@"http://"] ||
        [path hasPrefix:@"https://"])
        return [NSURL URLWithString:path];

    NSString *base = NFServer ?: @"";
    while ([base hasSuffix:@"/"])
        base = [base substringToIndex:base.length - 1];

    if (![path hasPrefix:@"/"])
        path = [@"/" stringByAppendingString:path];

    return [NSURL URLWithString:
        [base stringByAppendingString:path]];
}

static void NFHeaders(NSMutableURLRequest *r) {
    NSMutableString *auth = [NSMutableString
        stringWithFormat:
        @"MediaBrowser Client=\"NineFin\", "
         "Device=\"iPhone iOS9\", "
         "DeviceId=\"%@\", Version=\"0.7.1\"",
        NFDevice()];

    if (NFToken.length) {
        [auth appendFormat:@", Token=\"%@\"", NFToken];
    }

    [r setValue:auth forHTTPHeaderField:@"Authorization"];
    [r setValue:@"application/json"
        forHTTPHeaderField:@"Accept"];
}

static void NFRequest(NSString *path, NSString *method,
                      NSDictionary *body, NFResult completion) {
    NSMutableURLRequest *r =
        [NSMutableURLRequest requestWithURL:NFURL(path)];

    r.HTTPMethod = method;
    r.timeoutInterval = 25;
    NFHeaders(r);

    if (body) {
        r.HTTPBody = [NSJSONSerialization
            dataWithJSONObject:body options:0 error:NULL];
        [r setValue:@"application/json"
            forHTTPHeaderField:@"Content-Type"];
    }

    [[[NSURLSession sharedSession]
        dataTaskWithRequest:r
        completionHandler:^(NSData *data, NSURLResponse *response,
                            NSError *networkError) {

        NSHTTPURLResponse *http =
            (NSHTTPURLResponse *)response;

        NSInteger status = http.statusCode;
        NSError *error = networkError;
        id result = nil;

        if (!error && status >= 400) {
            NSString *details = data.length
                ? [[NSString alloc] initWithData:data
                    encoding:NSUTF8StringEncoding]
                : @"";

            if (!details) details = @"";

            if (NFToken.length) {
                details = [details
                    stringByReplacingOccurrencesOfString:NFToken
                    withString:@"[REDACTED]"];
            }

            if (details.length > 350)
                details = [details substringToIndex:350];

            NSString *endpoint =
                [[path componentsSeparatedByString:@"?"]
                    firstObject];

            NSString *message = [NSString stringWithFormat:
                @"%@ %@\nHTTP %ld\n%@",
                method, endpoint, (long)status, details];

            error = [NSError errorWithDomain:@"NineFin.HTTP"
                code:status
                userInfo:@{
                    NSLocalizedDescriptionKey: message
                }];
        }

        if (!error && data.length) {
            result = [NSJSONSerialization
                JSONObjectWithData:data options:0 error:&error];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(result, error);
        });
    }] resume];
}

static void NFAlert(UIViewController *vc,
                    NSString *title, NSString *message) {
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:title
        message:message
        preferredStyle:UIAlertControllerStyleAlert];

    [a addAction:[UIAlertAction actionWithTitle:@"OK"
        style:UIAlertActionStyleDefault handler:nil]];

    [vc presentViewController:a animated:YES completion:nil];
}

@interface NFAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
- (void)showLogin;
- (void)showLibrary;
@end

@interface NFServersController : UITableViewController
@end

@interface NFDrawerController : UIViewController
    <UITableViewDelegate, UITableViewDataSource>
@property (weak, nonatomic) UIViewController *host;
@end

@interface NFLoginController : UIViewController <UITextFieldDelegate>
@property (strong, nonatomic) UITextField *serverField;
@property (strong, nonatomic) UITextField *userField;
@property (strong, nonatomic) UITextField *passwordField;
@property (strong, nonatomic) UIButton *loginButton;
@end


@interface NFTrackedPlayerController : AVPlayerViewController
@property (copy, nonatomic) NSString *itemId;
@property (copy, nonatomic) NSString *mediaSourceId;
@property (copy, nonatomic) NSString *playSessionId;
@property (assign, nonatomic) long long resumeTicks;
@property (strong, nonatomic) AVPlayerItem *resumeItem;
@property (assign, nonatomic) BOOL observingResume;
@property (assign, nonatomic) BOOL resumeAttempted;
@property (assign, nonatomic) BOOL resumeCompleted;
@property (strong, nonatomic) id progressObserver;
@property (assign, nonatomic) BOOL didStart;
@property (assign, nonatomic) BOOL didStop;
@end

@interface NFLibraryController : UITableViewController
@property (copy, nonatomic) NSString *parentId;
@property (strong, nonatomic) NSArray *items;
- (instancetype)initWithParent:(NSString *)parent title:(NSString *)title;
- (void)reloadItems;
- (void)playItem:(NSDictionary *)item;
- (void)playItem:(NSDictionary *)item
            audio:(NSNumber *)audio
         subtitle:(NSNumber *)subtitle
         sourceId:(NSString *)sourceId;
@end



@interface NFChoiceController : UITableViewController
@property (strong, nonatomic) NSArray *entries;
@property (strong, nonatomic) NSNumber *current;
@property (copy, nonatomic) void (^picked)(NSNumber *);
@end

@implementation NFChoiceController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = NFBG();
    self.tableView.separatorColor = NFPanel();
    self.tableView.rowHeight = 53;
}

- (NSInteger)tableView:(UITableView *)table
 numberOfRowsInSection:(NSInteger)section {
    return self.entries.count;
}

- (UITableViewCell *)tableView:(UITableView *)table
        cellForRowAtIndexPath:(NSIndexPath *)path {

    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault
        reuseIdentifier:nil];

    NSDictionary *entry = self.entries[path.row];

    cell.backgroundColor = NFPanel();
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.textLabel.numberOfLines = 2;
    cell.textLabel.font = [UIFont systemFontOfSize:14];
    cell.textLabel.text = entry[@"title"];
    cell.tintColor = NFAccent();

    if ([entry[@"value"] isEqual:self.current])
        cell.accessoryType =
            UITableViewCellAccessoryCheckmark;

    return cell;
}

- (void)tableView:(UITableView *)table
 didSelectRowAtIndexPath:(NSIndexPath *)path {

    NSNumber *value =
        self.entries[path.row][@"value"];

    if (self.picked)
        self.picked(value);

    [self.navigationController
        popViewControllerAnimated:YES];
}

@end

@interface NFDetailsController : UITableViewController
@property (strong, nonatomic) NSDictionary *item;
@property (strong, nonatomic) NSArray *seasons;
@property (strong, nonatomic) NSArray *episodes;
@property (copy, nonatomic) NSString *seasonId;
@property (weak, nonatomic) NFLibraryController *playerOwner;
@property (assign, nonatomic) NSUInteger episodeGeneration;
@property (assign, nonatomic) BOOL appeared;
@property (assign, nonatomic) CGFloat headerWidth;
@property (assign, nonatomic) BOOL nfFavoriteBusy;
@property (copy, nonatomic) NSString *nfSourceId;
@property (strong, nonatomic) NSArray *nfStreams;
@property (strong, nonatomic) NSNumber *nfAudio;
@property (strong, nonatomic) NSNumber *nfSubtitle;

- (instancetype)initWithItem:(NSDictionary *)item
                       owner:(NFLibraryController *)owner;
@end

@implementation NFLoginController

- (UITextField *)field:(NSString *)placeholder
                    y:(CGFloat)y {
    CGFloat w = self.view.bounds.size.width - 32;

    UITextField *f = [[UITextField alloc]
        initWithFrame:CGRectMake(16, y, w, 42)];

    f.backgroundColor = NFPanel();
    f.textColor = [UIColor whiteColor];
    f.tintColor = NFAccent();
    f.attributedPlaceholder = [[NSAttributedString alloc]
        initWithString:placeholder
        attributes:@{
            NSForegroundColorAttributeName: NFSecondary()
        }];
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.placeholder = placeholder;
    f.autocapitalizationType =
        UITextAutocapitalizationTypeNone;
    f.autocorrectionType =
        UITextAutocorrectionTypeNo;
    f.delegate = self;

    [self.view addSubview:f];
    return f;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"NineFin";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc]
            initWithTitle:@"Server"
            style:UIBarButtonItemStylePlain
            target:self action:@selector(openServers)];
    self.view.backgroundColor = NFBG();

    UILabel *heading = [[UILabel alloc]
        initWithFrame:CGRectMake(16, 45,
            self.view.bounds.size.width - 32, 42)];

    heading.text = @"Connetti Jellyfin";
    heading.font = [UIFont boldSystemFontOfSize:24];
    heading.textColor = [UIColor whiteColor];
    heading.textAlignment = NSTextAlignmentCenter;
    heading.autoresizingMask =
        UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:heading];

    self.serverField = [self field:@"URL del server" y:108];
    self.userField = [self field:@"Utente" y:159];
    self.passwordField = [self field:@"Password" y:210];

    self.serverField.keyboardType = UIKeyboardTypeURL;
    self.serverField.returnKeyType = UIReturnKeyNext;
    self.userField.returnKeyType = UIReturnKeyNext;
    self.passwordField.returnKeyType = UIReturnKeyGo;
    self.passwordField.secureTextEntry = YES;

    self.serverField.text = NFServer ?: @"";

    NSDictionary *saved = NFLoginCredentials(NFServer);
    if (saved) {
        self.userField.text = saved[@"username"];
        self.passwordField.text = saved[@"password"];
    }

    [self.serverField addTarget:self
        action:@selector(serverAddressChanged)
        forControlEvents:UIControlEventEditingChanged];

    self.loginButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.loginButton.frame =
        CGRectMake(16, 268,
            self.view.bounds.size.width - 32, 46);

    self.loginButton.autoresizingMask =
        UIViewAutoresizingFlexibleWidth;

    self.loginButton.backgroundColor =
        [UIColor colorWithRed:0.16 green:0.62 blue:0.75 alpha:1];
    self.loginButton.layer.cornerRadius = 8;
    [self.loginButton setTitleColor:[UIColor whiteColor]
                          forState:UIControlStateNormal];
    [self.loginButton setTitle:@"Accedi"
                     forState:UIControlStateNormal];
    [self.loginButton addTarget:self
        action:@selector(login)
        forControlEvents:UIControlEventTouchUpInside];

    [self.view addSubview:self.loginButton];
}

- (void)serverAddressChanged {
    self.userField.text = @"";
    self.passwordField.text = @"";
}

- (BOOL)textFieldShouldReturn:(UITextField *)field {
    if (field == self.serverField)
        [self.userField becomeFirstResponder];
    else if (field == self.userField)
        [self.passwordField becomeFirstResponder];
    else
        [self login];
    return YES;
}

- (void)openServers {
    NFServersController *vc = [[NFServersController alloc]
        initWithStyle:UITableViewStyleGrouped];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)login {
    [self.view endEditing:YES];

    NSString *server = [self.serverField.text
        stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];

    NSURL *url = [NSURL URLWithString:server];

    if (!([url.scheme.lowercaseString isEqualToString:@"http"] ||
          [url.scheme.lowercaseString isEqualToString:@"https"]) ||
        !url.host.length) {
        NFAlert(self, @"Indirizzo non valido",
            @"Inserisci http:// oppure https:// seguito "
             "dall'indirizzo del server Jellyfin.");
        return;
    }

    if (!self.userField.text.length) {
        NFAlert(self, @"Utente mancante",
            @"Inserisci il nome utente Jellyfin.");
        return;
    }

    NFServer = server;
    NFToken = nil;
    NFUser = nil;

    self.loginButton.enabled = NO;
    [self.loginButton setTitle:@"Connessione..."
                     forState:UIControlStateNormal];

    NSDictionary *credentials = @{
        @"Username": self.userField.text ?: @"",
        @"Pw": self.passwordField.text ?: @""
    };

    NFRequest(@"/Users/AuthenticateByName", @"POST",
              credentials, ^(id result, NSError *error) {

        self.loginButton.enabled = YES;
        [self.loginButton setTitle:@"Accedi"
                         forState:UIControlStateNormal];

        NSDictionary *user = [result isKindOfClass:
            [NSDictionary class]] ? result[@"User"] : nil;

        NSString *token = result[@"AccessToken"];
        NSString *userId = user[@"Id"];

        if (error || !token.length || !userId.length) {
            NFAlert(self, @"Accesso fallito",
                error.localizedDescription ?:
                    @"Risposta di autenticazione non valida.");
            return;
        }

        NFToken = token;
        NFUser = userId;
        NFSave();
        NFStoreLoginCredentials(
            NFServer, self.userField.text,
            self.passwordField.text);

        NSDictionary *verification = NFReadSession(NFServer);
        BOOL sessionOK =
            [verification[@"token"] isEqual:NFToken];

        NSDictionary *savedLogin =
            NFLoginCredentials(NFServer);
        BOOL credentialsOK =
            [savedLogin[@"username"]
                isEqual:self.userField.text];

        self.passwordField.text = @"";

        NFAppDelegate *app =
            (NFAppDelegate *)[UIApplication sharedApplication].delegate;

        [app showLibrary];

        if (!sessionOK || !credentialsOK) {
            NSString *message = [NSString stringWithFormat:
                @"Salvataggio Keychain non verificato.\n"
                 @"Sessione: %d\nCredenziali: %d\n"
                 @"Lettura sessione: %@\n"
                 @"Lettura credenziali: %@",
                (int)NFSessionSaveStatus,
                (int)NFCredentialsSaveStatus,
                sessionOK ? @"OK" : @"ERRORE",
                credentialsOK ? @"OK" : @"ERRORE"];

            dispatch_async(dispatch_get_main_queue(), ^{
                NFAlert(app.window.rootViewController,
                    @"Diagnostica Keychain", message);
            });
        }
    });
}

@end

@implementation NFLibraryController

- (instancetype)initWithParent:(NSString *)parent
                          title:(NSString *)title {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _parentId = [parent copy];
        self.title = title;
        self.items = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = 68;
    self.tableView.backgroundColor = NFBG();
    self.tableView.separatorColor = NFPanel();
    self.tableView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    self.tableView.tableFooterView = [[UIView alloc] init];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
            target:self action:@selector(reloadItems)];

    if (!self.parentId) {
        self.navigationItem.leftBarButtonItem =
            [[UIBarButtonItem alloc]
                initWithTitle:@"Esci"
                style:UIBarButtonItemStylePlain
                target:self action:@selector(logout)];
    }

    [self reloadItems];
}

- (void)logout {
    NFRequest(@"/Sessions/Logout", @"POST",
              nil, ^(id result, NSError *error) {});
    NFLogout();
    [(NFAppDelegate *)[UIApplication sharedApplication].delegate
        showLogin];
}

- (void)reloadItems {
    NSString *path;

    if (!self.parentId) {
        path = [NSString stringWithFormat:
            @"/Users/%@/Views", NFUser];
    } else {
        path = [NSString stringWithFormat:
            @"/Users/%@/Items?ParentId=%@"
             "&SortBy=SortName&Limit=200"
             "&Fields=Overview,UserData",
            NFUser, self.parentId];
    }

    NFRequest(path, @"GET", nil,
              ^(id result, NSError *error) {

        if (error) {
            if (error.code == 401) {
                NFLogout();
                [(NFAppDelegate *)
                    [UIApplication sharedApplication].delegate
                    showLogin];
                return;
            }
            NFAlert(self, @"Errore catalogo",
                error.localizedDescription);
            return;
        }

        NSArray *received = result[@"Items"];
        self.items = [received isKindOfClass:[NSArray class]]
            ? received : @[];

        [self.tableView reloadData];
    });
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    return self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
        cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuse = @"NFItem";
    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:reuse];

    if (!cell) {
        cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleSubtitle
            reuseIdentifier:reuse];
    }

    NSDictionary *item = self.items[indexPath.row];
    NSString *itemId = item[@"Id"];
    NSString *type = item[@"Type"] ?: @"Contenuto";

    cell.backgroundColor = NFBG();
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.detailTextLabel.textColor = NFSecondary();
    cell.tintColor = NFAccent();

    cell.textLabel.text = item[@"Name"] ?: @"Senza titolo";

    NSNumber *year = item[@"ProductionYear"];
    cell.detailTextLabel.text = year
        ? [NSString stringWithFormat:@"%@ · %@", type, year]
        : type;

    cell.accessoryType =
        UITableViewCellAccessoryDisclosureIndicator;

    cell.imageView.image = nil;
    cell.accessibilityIdentifier = itemId;

    if (!NFImageCache)
        NFImageCache = [[NSCache alloc] init];

    UIImage *cached = [NFImageCache objectForKey:itemId];
    if (cached) {
        cell.imageView.image = cached;
        return cell;
    }

    if (!itemId.length) return cell;

    NSString *path = [NSString stringWithFormat:
        @"/Items/%@/Images/Primary?maxHeight=120&quality=70",
        itemId];

    NSMutableURLRequest *r =
        [NSMutableURLRequest requestWithURL:NFURL(path)];
    NFHeaders(r);

    __weak UITableViewCell *weakCell = cell;

    [[[NSURLSession sharedSession]
        dataTaskWithRequest:r
        completionHandler:^(NSData *data, NSURLResponse *response,
                            NSError *error) {
        if (error || !data.length) return;

        NSHTTPURLResponse *http =
            (NSHTTPURLResponse *)response;
        if (http.statusCode != 200) return;

        UIImage *image = [UIImage imageWithData:data];
        if (!image) return;

        [NFImageCache setObject:image forKey:itemId];

        dispatch_async(dispatch_get_main_queue(), ^{
            UITableViewCell *target = weakCell;
            if ([target.accessibilityIdentifier
                    isEqualToString:itemId]) {
                target.imageView.image = image;
                [target setNeedsLayout];
            }
        });
    }] resume];

    return cell;
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSDictionary *item = self.items[indexPath.row];
    NSString *type = item[@"Type"] ?: @"";
    NSString *itemId = item[@"Id"];

    if (!itemId.length) return;

    BOOL playable =
        [@[@"Movie", @"Episode", @"Video", @"Trailer", @"Audio"]
            containsObject:type];

    if ([@[@"Movie", @"Series", @"Episode",
           @"Video", @"Trailer"] containsObject:type]) {

        NFDetailsController *details =
            [[NFDetailsController alloc]
                initWithItem:item owner:self];

        [self.navigationController
            pushViewController:details animated:YES];
        return;
    }

    if (!playable) {
        NFLibraryController *next =
            [[NFLibraryController alloc]
                initWithParent:itemId
                title:item[@"Name"] ?: @"Contenuti"];

        [self.navigationController
            pushViewController:next animated:YES];
        return;
    }

    [self playItem:item];
}

- (void)playItem:(NSDictionary *)item {
    [self playItem:item audio:nil subtitle:nil sourceId:nil];
}

- (void)playItem:(NSDictionary *)item
            audio:(NSNumber *)audio
         subtitle:(NSNumber *)subtitle
         sourceId:(NSString *)sourceId {
    NSString *itemId = item[@"Id"];

    NSDictionary *profile = @{
        @"Name": @"NineFin iOS 9",
        @"DirectPlayProfiles": @[],
        @"TranscodingProfiles": @[
            @{
                @"Container": @"ts",
                @"Type": @"Video",
                @"VideoCodec": @"h264",
                @"AudioCodec": @"aac",
                @"Protocol": @"hls",
                @"Context": @"Streaming"
            },
            @{
                @"Container": @"mp3",
                @"Type": @"Audio",
                @"AudioCodec": @"mp3",
                @"Protocol": @"http",
                @"Context": @"Streaming"
            }
        ],
        @"CodecProfiles": @[]
    };

    NSMutableDictionary *effectiveProfile =
        [profile mutableCopy];

    if (subtitle && subtitle.integerValue >= 0) {
        NSMutableArray *profiles = [NSMutableArray array];

        for (NSString *format in
             @[@"srt", @"subrip", @"ass", @"ssa",
               @"pgs", @"pgssub", @"dvdsub", @"vtt"]) {
            [profiles addObject:@{
                @"Format": format,
                @"Method": @"Encode"
            }];
        }

        effectiveProfile[@"SubtitleProfiles"] = profiles;
    }

    NSMutableDictionary *body = [@{
        @"DeviceProfile": effectiveProfile,
        @"UserId": NFUser,
        @"EnableDirectPlay": @NO,
        @"EnableDirectStream": @NO,
        @"EnableTranscoding": @YES,
        @"AllowVideoStreamCopy": @NO,
        @"AllowAudioStreamCopy": @NO,
        @"MaxStreamingBitrate": @(NFStreamingBitrate())
    } mutableCopy];

    if (sourceId.length) {
        body[@"MediaSourceId"] = sourceId;

        if (audio)
            body[@"AudioStreamIndex"] = audio;

        if (subtitle) {
            body[@"SubtitleStreamIndex"] = subtitle;

            if (subtitle.integerValue >= 0)
                body[@"AlwaysBurnInSubtitleWhenTranscoding"] =
                    @YES;
        }
    }

    NSString *path = [NSString stringWithFormat:
        @"/Items/%@/PlaybackInfo?UserId=%@",
        itemId, NFUser];

    NFRequest(path, @"POST", body,
              ^(id result, NSError *error) {

        if (error) {
            NFAlert(self, @"Errore riproduzione",
                error.localizedDescription);
            return;
        }

        NSArray *sources = result[@"MediaSources"];
        if (![sources isKindOfClass:[NSArray class]] ||
            !sources.count) {
            NFAlert(self, @"Nessuna sorgente",
                @"Jellyfin non ha restituito sorgenti multimediali.");
            return;
        }

        NSDictionary *source = sources[0];
        NSString *stream = source[@"TranscodingUrl"];

        if (![stream isKindOfClass:[NSString class]] ||
            !stream.length) {
            NFAlert(self, @"Transcodifica non disponibile",
                @"Jellyfin non ha restituito uno stream "
                 "compatibile. Verifica i permessi di transcodifica "
                 "e il profilo del server.");
            return;
        }

        NSURL *url = NFURL(stream);
        NSURL *serverURL = NFURL(@"/");

        if (!url || ![url.host.lowercaseString
                isEqualToString:serverURL.host.lowercaseString]) {
            NFAlert(self, @"URL non valido",
                @"Il server ha restituito uno stream "
                 "su un host differente.");
            return;
        }

        NSURLComponents *components =
            [NSURLComponents componentsWithURL:url
                resolvingAgainstBaseURL:NO];

        BOOL hasKey = NO;
        for (NSURLQueryItem *q in components.queryItems) {
            if ([q.name.lowercaseString isEqualToString:@"apikey"] ||
                [q.name.lowercaseString isEqualToString:@"api_key"]) {
                hasKey = YES;
                break;
            }
        }

        if (!hasKey) {
            NSMutableArray *queries =
                [components.queryItems mutableCopy] ?:
                    [NSMutableArray array];

            [queries addObject:
                [NSURLQueryItem queryItemWithName:@"ApiKey"
                    value:NFToken]];

            components.queryItems = queries;
        }

        NFTrackedPlayerController *playerVC =
            [[NFTrackedPlayerController alloc] init];

        // Il seek avverrà su AVPlayer, non sull'URL HLS.
        NSDictionary *userData =
            [item[@"UserData"] isKindOfClass:[NSDictionary class]]
                ? item[@"UserData"] : nil;

        long long resumeTicks =
            [userData[@"PlaybackPositionTicks"] longLongValue];

        if (resumeTicks < 0) resumeTicks = 0;

        playerVC.itemId = itemId;
        playerVC.mediaSourceId =
            [source[@"Id"] isKindOfClass:[NSString class]]
                ? source[@"Id"] : nil;
        playerVC.playSessionId =
            [result[@"PlaySessionId"] isKindOfClass:[NSString class]]
                ? result[@"PlaySessionId"] : nil;
        playerVC.resumeTicks = resumeTicks;

        playerVC.player =
            [AVPlayer playerWithURL:components.URL];

        UIViewController *presenter =
            self.navigationController.topViewController ?: self;

        [presenter presentViewController:playerVC
            animated:YES completion:^{
                [playerVC.player play];
            }];
    });
}

@end


static void *NFResumeContext = &NFResumeContext;

@implementation NFTrackedPlayerController

- (NSNumber *)positionTicks {
    Float64 seconds = CMTimeGetSeconds(self.player.currentTime);

    if (!isfinite(seconds) || seconds < 0)
        seconds = 0;

    if (self.resumeTicks > 0 && !self.resumeCompleted)
        return @(self.resumeTicks);

    long long ticks = (long long)(seconds * 10000000.0);

    return @(ticks);
}

- (void)report:(NSString *)endpoint {
    if (!self.itemId.length) return;

    NSMutableDictionary *body = [@{
        @"ItemId": self.itemId,
        @"PositionTicks": [self positionTicks]
    } mutableCopy];

    if (self.mediaSourceId.length)
        body[@"MediaSourceId"] = self.mediaSourceId;

    if (self.playSessionId.length)
        body[@"PlaySessionId"] = self.playSessionId;

    if ([endpoint hasSuffix:@"/Stopped"]) {
        body[@"Failed"] = @NO;
    } else {
        body[@"PlayMethod"] = @"Transcode";
        body[@"CanSeek"] = @YES;
        body[@"IsPaused"] = @(self.player.rate == 0);
        body[@"IsMuted"] = @NO;
    }

    NFRequest(endpoint, @"POST", body,
        ^(id result, NSError *error) {
            if (error) {
                NSLog(@"NineFin playback report failed: %@ (%ld)",
                    endpoint, (long)error.code);
            }
        });
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];

    if (self.resumeTicks > 0 &&
        !self.observingResume &&
        !self.resumeAttempted &&
        self.player.currentItem) {
        self.resumeItem = self.player.currentItem;
        self.observingResume = YES;
        [self.resumeItem addObserver:self
            forKeyPath:@"status"
            options:(NSKeyValueObservingOptionInitial |
                     NSKeyValueObservingOptionNew)
            context:NFResumeContext];
    }

    if (self.didStart) return;
    self.didStart = YES;

    [self report:@"/Sessions/Playing"];

    __weak NFTrackedPlayerController *weakSelf = self;

    self.progressObserver =
        [self.player addPeriodicTimeObserverForInterval:
            CMTimeMake(10, 1)
            queue:dispatch_get_main_queue()
            usingBlock:^(CMTime time) {
                NFTrackedPlayerController *strongSelf = weakSelf;
                if (!strongSelf || strongSelf.didStop) return;

                if (strongSelf.player.rate > 0) {
                    [strongSelf
                        report:@"/Sessions/Playing/Progress"];
                }
            }];
}


- (void)stopResumeObservation {
    if (self.observingResume && self.resumeItem) {
        [self.resumeItem removeObserver:self
            forKeyPath:@"status" context:NFResumeContext];
        self.observingResume = NO;
    }
    self.resumeItem = nil;
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                       ofObject:(id)object
                         change:(NSDictionary *)change
                        context:(void *)context {
    if (context != NFResumeContext) {
        [super observeValueForKeyPath:keyPath
            ofObject:object change:change context:context];
        return;
    }

    if (self.resumeAttempted ||
        self.resumeItem.status != AVPlayerItemStatusReadyToPlay)
        return;

    self.resumeAttempted = YES;

    NSTimeInterval seconds =
        (NSTimeInterval)self.resumeTicks / 10000000.0;

    if (seconds <= 0 || !isfinite(seconds)) {
        self.resumeCompleted = YES;
        return;
    }

    Float64 duration =
        CMTimeGetSeconds(self.resumeItem.duration);

    if (isfinite(duration) && duration > 10)
        seconds = MIN(seconds, duration - 5);

    CMTime target = CMTimeMakeWithSeconds(seconds, 600);
    NSLog(@"NineFin resume: %.2f s", seconds);

    __weak NFTrackedPlayerController *weakSelf = self;

    [self.player seekToTime:target
           toleranceBefore:kCMTimeZero
            toleranceAfter:kCMTimeZero
         completionHandler:^(BOOL finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NFTrackedPlayerController *vc = weakSelf;
            if (!vc) return;
            vc.resumeCompleted = YES;
            NSLog(@"NineFin resume: %@",
                finished ? @"OK" : @"seek interrotto");
        });
    }];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopResumeObservation];

    if (!self.didStart || self.didStop) return;
    self.didStop = YES;

    if (self.progressObserver) {
        [self.player
            removeTimeObserver:self.progressObserver];
        self.progressObserver = nil;
    }

    [self report:@"/Sessions/Playing/Stopped"];
    [self.player pause];
}

- (void)dealloc {
    [self stopResumeObservation];
    if (self.progressObserver && self.player) {
        [self.player removeTimeObserver:self.progressObserver];
        self.progressObserver = nil;
    }
}

@end


static void NFPoster(NSString *itemId, UIImageView *view) {
    if (!itemId.length) return;

    view.accessibilityIdentifier = itemId;

    if (!NFImageCache)
        NFImageCache = [[NSCache alloc] init];

    UIImage *cached = [NFImageCache objectForKey:itemId];
    if (cached) {
        view.image = cached;
        return;
    }

    NSString *path = [NSString stringWithFormat:
        @"/Items/%@/Images/Primary?maxHeight=260&quality=75",
        itemId];

    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:NFURL(path)];
    request.timeoutInterval = 15;
    NFHeaders(request);

    __weak UIImageView *weakView = view;

    [[[NSURLSession sharedSession]
        dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response,
                            NSError *error) {
            if (error || !data.length) return;

            if ([(NSHTTPURLResponse *)response statusCode] != 200)
                return;

            UIImage *image = [UIImage imageWithData:data];
            if (!image) return;

            [NFImageCache setObject:image forKey:itemId];

            dispatch_async(dispatch_get_main_queue(), ^{
                UIImageView *target = weakView;
                if ([target.accessibilityIdentifier
                        isEqualToString:itemId]) {
                    target.image = image;
                }
            });
        }] resume];
}


@interface NFHomeController : NFLibraryController
@property (strong, nonatomic) NSArray *resumeItems;
@property (strong, nonatomic) NSArray *nextItems;
@property (strong, nonatomic) NSArray *recentMovies;
@property (strong, nonatomic) NSArray *recentSeries;
@property (strong, nonatomic) NSTimer *refreshTimer;
@property (assign, nonatomic) NSUInteger refreshGeneration;
@property (assign, nonatomic) BOOL hasAppeared;
- (void)renderResume;
- (void)fetchResume:(NSString *)path
          fallback:(BOOL)fallback
        generation:(NSUInteger)generation
            server:(NSString *)server
              user:(NSString *)user;
@end



@implementation NFHomeController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"NineFin";

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc]
            initWithTitle:@"☰"
            style:UIBarButtonItemStylePlain
            target:self action:@selector(openDrawer)];

    UIBarButtonItem *servers = [[UIBarButtonItem alloc]
        initWithTitle:@"Server"
        style:UIBarButtonItemStylePlain
        target:self action:@selector(openServers)];

    UIBarButtonItem *refresh =
        self.navigationItem.rightBarButtonItem;

    self.navigationItem.rightBarButtonItems =
        refresh ? @[refresh, servers] : @[servers];

    [[NSNotificationCenter defaultCenter]
        addObserver:self
        selector:@selector(NFHomeAutoRefresh:)
        name:UIApplicationDidBecomeActiveNotification
        object:nil];

    [self renderResume];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];

    if (!self.refreshTimer) {
        self.refreshTimer =
            [NSTimer scheduledTimerWithTimeInterval:60.0
            target:self
            selector:@selector(NFHomeAutoRefresh:)
            userInfo:nil repeats:YES];
    }

    if (self.hasAppeared)
        [self reloadItems];

    self.hasAppeared = YES;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

- (void)dealloc {
    [self.refreshTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)NFHomeAutoRefresh:(id)sender {
    if (!self.isViewLoaded || !self.view.window)
        return;

    if (self.navigationController.topViewController != self)
        return;

    if (self.presentedViewController)
        return;

    [self reloadItems];
}

- (BOOL)validGeneration:(NSUInteger)generation
                server:(NSString *)server
                  user:(NSString *)user {
    return generation == self.refreshGeneration &&
           [NFServer isEqualToString:server] &&
           [NFUser isEqualToString:user];
}

- (NSArray *)extractItems:(id)result {
    if ([result isKindOfClass:[NSArray class]])
        return result;

    if ([result isKindOfClass:[NSDictionary class]]) {
        id items = result[@"Items"];
        if ([items isKindOfClass:[NSArray class]])
            return items;
    }
    return @[];
}

- (void)reloadItems {
    if (!NFServer.length || !NFUser.length) return;

    NSUInteger generation = ++self.refreshGeneration;
    NSString *server = [NFServer copy];
    NSString *user = [NFUser copy];

    // Librerie principali.
    NSString *views = [NSString stringWithFormat:
        @"/Users/%@/Views", user];

    NFRequest(views, @"GET", nil, ^(id result, NSError *error) {
        if (![self validGeneration:generation
                            server:server user:user]) return;

        if (error) {
            if (error.code == 401) {
                NFLogout();
                [(NFAppDelegate *)
                    [UIApplication sharedApplication].delegate
                    showLogin];
            } else {
                NSLog(@"NineFin Views: %@", error);
            }
            return;
        }

        self.items = [self extractItems:result];
        [self.tableView reloadData];
    });

    // Continua a guardare.
    NSString *resume = [NSString stringWithFormat:
        @"/Users/%@/Items/Resume?"
         "Limit=12&MediaTypes=Video&EnableUserData=true",
        user];

    if (NFHomeRailEnabled(0)) {
        [self fetchResume:resume fallback:YES
            generation:generation server:server user:user];
    } else {
        self.resumeItems = @[];
    }

    // Prossimo episodio.
    NSString *next = [NSString stringWithFormat:
        @"/Shows/NextUp?UserId=%@&Limit=12"
         "&EnableUserData=true&ImageTypeLimit=1",
        user];

    if (NFHomeRailEnabled(1)) {
        [self fetchRail:next kind:1 generation:generation
                 server:server user:user];
    } else {
        self.nextItems = @[];
    }

    // Film aggiunti recentemente.
    NSString *movies = [NSString stringWithFormat:
        @"/Users/%@/Items/Latest?"
         "Limit=12&IncludeItemTypes=Movie&EnableUserData=true",
        user];

    if (NFHomeRailEnabled(2)) {
        [self fetchRail:movies kind:2 generation:generation
                 server:server user:user];
    } else {
        self.recentMovies = @[];
    }

    // Serie aggiunte recentemente.
    NSString *series = [NSString stringWithFormat:
        @"/Users/%@/Items/Latest?"
         "Limit=12&IncludeItemTypes=Series&EnableUserData=true",
        user];

    if (NFHomeRailEnabled(3)) {
        [self fetchRail:series kind:3 generation:generation
                 server:server user:user];
    } else {
        self.recentSeries = @[];
    }
}

- (void)fetchResume:(NSString *)path
          fallback:(BOOL)fallback
        generation:(NSUInteger)generation
            server:(NSString *)server
              user:(NSString *)user {

    NFRequest(path, @"GET", nil,
        ^(id result, NSError *error) {

        if (![self validGeneration:generation
                            server:server user:user]) return;

        if (error && error.code == 404 && fallback) {
            NSString *alternate = [NSString stringWithFormat:
                @"/UserItems/Resume?UserId=%@"
                 "&Limit=12&MediaTypes=Video"
                 "&EnableUserData=true", user];

            [self fetchResume:alternate fallback:NO
                generation:generation server:server user:user];
            return;
        }

        if (error) {
            NSLog(@"NineFin Resume: %@", error);
            return;
        }

        self.resumeItems = [self extractItems:result];
        [self renderResume];
    });
}

- (void)fetchRail:(NSString *)path
             kind:(NSInteger)kind
       generation:(NSUInteger)generation
           server:(NSString *)server
             user:(NSString *)user {

    NFRequest(path, @"GET", nil,
        ^(id result, NSError *error) {

        if (![self validGeneration:generation
                            server:server user:user]) return;

        if (error) {
            NSLog(@"NineFin Home rail %ld: %@",
                (long)kind, error);
            return;
        }

        NSArray *items = [self extractItems:result];

        // Fallback per i server che non restituiscono
        // le serie tramite l'endpoint Latest.
        if (kind == 3 && !items.count &&
            [path containsString:@"/Items/Latest"]) {
            NSString *alternate = [NSString stringWithFormat:
                @"/Users/%@/Items?Recursive=true"
                 "&IncludeItemTypes=Series"
                 "&SortBy=DateCreated&SortOrder=Descending"
                 "&Limit=12", user];

            [self fetchRail:alternate kind:kind
                generation:generation server:server user:user];
            return;
        }

        switch (kind) {
            case 1: self.nextItems = items; break;
            case 2: self.recentMovies = items; break;
            case 3: self.recentSeries = items; break;
            default: return;
        }

        [self renderResume];
    });
}

- (CGFloat)addRail:(NSArray *)items
             title:(NSString *)title
              kind:(NSInteger)kind
            header:(UIView *)header
                 y:(CGFloat)y {

    // Mostriamo sempre Continua a guardare;
    // le altre sezioni vuote vengono nascoste.
    if (!NFHomeRailEnabled(kind)) return y;
    if (!items.count && kind != 0) return y;

    CGFloat width = header.bounds.size.width;

    UILabel *heading = [[UILabel alloc]
        initWithFrame:CGRectMake(16, y, width - 32, 28)];

    heading.text = title;
    heading.textColor = [UIColor whiteColor];
    heading.font = [UIFont boldSystemFontOfSize:19];
    heading.autoresizingMask =
        UIViewAutoresizingFlexibleWidth;

    [header addSubview:heading];

    UIScrollView *scroll = [[UIScrollView alloc]
        initWithFrame:CGRectMake(0, y + 34, width, 200)];

    scroll.showsHorizontalScrollIndicator = NO;
    scroll.backgroundColor = NFBG();
    scroll.autoresizingMask =
        UIViewAutoresizingFlexibleWidth;

    [header addSubview:scroll];

    if (!items.count) {
        UILabel *empty = [[UILabel alloc]
            initWithFrame:CGRectMake(16, 20, width - 32, 35)];
        empty.text = @"Nessun contenuto da riprendere";
        empty.font = [UIFont systemFontOfSize:14];
        empty.textColor = NFSecondary();
        [scroll addSubview:empty];
    }

    NSUInteger count = MIN((NSUInteger)12, items.count);

    for (NSUInteger i = 0; i < count; i++) {
        NSDictionary *item = items[i];
        CGFloat x = 16 + i * 136;

        UIButton *card =
            [UIButton buttonWithType:UIButtonTypeCustom];

        card.frame = CGRectMake(x, 0, 122, 196);
        card.backgroundColor = NFPanel();
        card.layer.cornerRadius = 7;
        card.clipsToBounds = YES;
        card.tag = kind * 1000 + i;

        [card addTarget:self action:@selector(openRailItem:)
            forControlEvents:UIControlEventTouchUpInside];

        UIImageView *poster = [[UIImageView alloc]
            initWithFrame:CGRectMake(0, 0, 122, 150)];

        poster.backgroundColor = NFPanel();
        poster.contentMode = UIViewContentModeScaleAspectFill;
        poster.clipsToBounds = YES;
        [card addSubview:poster];

        NSString *itemId = item[@"Id"];
        NFPoster(itemId, poster);

        // Barra di avanzamento solo per i contenuti
        // che possiedono una posizione di visione.
        double position =
            [item[@"UserData"][@"PlaybackPositionTicks"]
                doubleValue];
        double duration = [item[@"RunTimeTicks"] doubleValue];

        if (position > 0 && duration > 0) {
            CGFloat fraction = (CGFloat)MAX(
                0.0, MIN(1.0, position / duration));

            UIView *track = [[UIView alloc]
                initWithFrame:CGRectMake(0, 146, 122, 4)];
            track.backgroundColor =
                [UIColor colorWithWhite:0.30 alpha:1];

            UIView *fill = [[UIView alloc]
                initWithFrame:CGRectMake(0, 0,
                    122 * fraction, 4)];
            fill.backgroundColor = NFAccent();

            [track addSubview:fill];
            [card addSubview:track];
        }

        NSString *name = item[@"Name"] ?: @"Contenuto";

        if ([item[@"Type"] isEqualToString:@"Episode"] &&
            [item[@"SeriesName"] isKindOfClass:[NSString class]]) {
            name = [NSString stringWithFormat:@"%@ · %@",
                item[@"SeriesName"], name];
        }

        UILabel *label = [[UILabel alloc]
            initWithFrame:CGRectMake(6, 155, 110, 36)];

        label.text = name;
        label.textColor = [UIColor whiteColor];
        label.font = [UIFont systemFontOfSize:12];
        label.numberOfLines = 2;

        [card addSubview:label];
        [scroll addSubview:card];
    }

    scroll.contentSize = CGSizeMake(
        MAX(width, 16 + count * 136), 200);

    return y + 245;
}

- (void)renderResume {
    CGFloat width = self.tableView.bounds.size.width;
    CGFloat previousOffset = self.tableView.contentOffset.y;

    UIView *header = [[UIView alloc]
        initWithFrame:CGRectMake(0, 0, width, 1)];

    header.backgroundColor = NFBG();
    header.autoresizingMask =
        UIViewAutoresizingFlexibleWidth;

    CGFloat y = 12;

    y = [self addRail:self.resumeItems ?: @[]
               title:@"Continua a guardare"
                kind:0 header:header y:y];

    y = [self addRail:self.nextItems ?: @[]
               title:@"Prossimo"
                kind:1 header:header y:y];

    y = [self addRail:self.recentMovies ?: @[]
               title:@"Film recenti"
                kind:2 header:header y:y];

    y = [self addRail:self.recentSeries ?: @[]
               title:@"Serie recenti"
                kind:3 header:header y:y];

    header.frame = CGRectMake(0, 0, width, y + 8);

    self.tableView.tableHeaderView = header;

    // Evita di riportare in cima la dashboard
    // a ogni aggiornamento automatico.
    if (previousOffset > 0 && self.tableView.window) {
        CGFloat maximum = MAX(0,
            self.tableView.contentSize.height -
            self.tableView.bounds.size.height);

        self.tableView.contentOffset =
            CGPointMake(0, MIN(previousOffset, maximum));
    }
}

- (void)openRailItem:(UIButton *)button {
    NSInteger kind = button.tag / 1000;
    NSUInteger index = (NSUInteger)(button.tag % 1000);

    NSArray *items = nil;
    switch (kind) {
        case 0: items = self.resumeItems; break;
        case 1: items = self.nextItems; break;
        case 2: items = self.recentMovies; break;
        case 3: items = self.recentSeries; break;
        default: return;
    }

    if (index >= items.count) return;

    NSDictionary *item = items[index];
    NSString *type = item[@"Type"] ?: @"";

    // NineFin 0.5.1:
    // Gli episodi selezionati dalla Home
    // devono partire immediatamente.
    if ([type isEqualToString:@"Episode"] ||
        (kind == 0 &&
         [@[@"Movie", @"Video", @"Trailer"]
             containsObject:type])) {
        [self playItem:item];
        return;
    }

    if ([@[@"Movie", @"Series", @"Episode",
           @"Video", @"Trailer"] containsObject:type]) {

        NFDetailsController *details =
            [[NFDetailsController alloc]
                initWithItem:item owner:self];

        [self.navigationController
            pushViewController:details animated:YES];
        return;
    }

    if ([type isEqualToString:@"Audio"]) {
        [self playItem:item];
        return;
    }

    NSString *itemId = item[@"Id"];
    if (!itemId.length) return;

    NFLibraryController *next =
        [[NFLibraryController alloc]
            initWithParent:itemId
            title:item[@"Name"] ?: @"Contenuti"];

    [self.navigationController
        pushViewController:next animated:YES];
}

- (void)openServers {
    NFServersController *vc = [[NFServersController alloc]
        initWithStyle:UITableViewStyleGrouped];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openDrawer {
    NFDrawerController *drawer =
        [[NFDrawerController alloc] init];

    drawer.host = self;
    drawer.modalPresentationStyle =
        UIModalPresentationOverFullScreen;
    drawer.modalTransitionStyle =
        UIModalTransitionStyleCrossDissolve;

    [self presentViewController:drawer
        animated:YES completion:nil];
}

- (NSString *)tableView:(UITableView *)tableView
 titleForHeaderInSection:(NSInteger)section {
    return @"LE TUE LIBRERIE";
}

- (void)tableView:(UITableView *)tableView
 willDisplayHeaderView:(UIView *)view
 forSection:(NSInteger)section {
    UITableViewHeaderFooterView *header =
        (UITableViewHeaderFooterView *)view;
    header.contentView.backgroundColor = NFBG();
    header.textLabel.textColor = NFSecondary();
}

@end



#pragma mark - Server salvati

@implementation NFServersController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Server";
    self.tableView.backgroundColor = NFBG();
    self.tableView.separatorColor = NFPanel();
    self.tableView.tableFooterView = [[UIView alloc] init];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table {
    return 4;
}

- (NSInteger)tableView:(UITableView *)table
 numberOfRowsInSection:(NSInteger)section {
    if (section == 0 || section == 3) return 1;
    return NFServerList().count;
}

- (NSString *)tableView:(UITableView *)table
 titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"SERVER ATTIVO";
        case 1: return @"CAMBIA SERVER";
        case 2: return @"PREDEFINITO ALL'AVVIO";
        default: return @"GESTIONE";
    }
}

- (void)tableView:(UITableView *)table
 willDisplayHeaderView:(UIView *)view
 forSection:(NSInteger)section {
    if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
        UITableViewHeaderFooterView *header =
            (UITableViewHeaderFooterView *)view;
        header.contentView.backgroundColor = NFBG();
        header.textLabel.textColor = NFSecondary();
    }
}

- (UITableViewCell *)tableView:(UITableView *)table
 cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleSubtitle
        reuseIdentifier:nil];

    cell.backgroundColor = NFPanel();
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.detailTextLabel.textColor = NFSecondary();
    cell.tintColor = NFAccent();
    cell.textLabel.adjustsFontSizeToFitWidth = YES;
    cell.textLabel.minimumScaleFactor = 0.65;

    NSArray *servers = NFServerList();
    NSString *selected = [[NSUserDefaults standardUserDefaults]
        stringForKey:@"NineFin.DefaultServer"];

    if (path.section == 0) {
        cell.textLabel.text = NFServer ?: @"Nessuno";
        cell.detailTextLabel.text =
            NFToken.length ? @"Sessione salvata" : @"Accesso richiesto";
    } else if (path.section == 3) {
        cell.textLabel.text = @"＋ Aggiungi server";
        cell.textLabel.textColor = NFAccent();
    } else if (path.row < servers.count) {
        NSString *url = servers[path.row];
        cell.textLabel.text = url;

        BOOL checked = path.section == 1
            ? [url isEqualToString:NFServer]
            : [url isEqualToString:selected];

        cell.accessoryType = checked
            ? UITableViewCellAccessoryCheckmark
            : UITableViewCellAccessoryNone;
    }

    return cell;
}

- (void)tableView:(UITableView *)table
 didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];

    NSArray *servers = NFServerList();
    NFAppDelegate *app =
        (NFAppDelegate *)[UIApplication sharedApplication].delegate;

    if (path.section == 1 && path.row < servers.count) {
        NFActivateServer(servers[path.row]);

        if (NFToken.length && NFUser.length)
            [app showLibrary];
        else
            [app showLogin];

        return;
    }

    if (path.section == 2 && path.row < servers.count) {
        [[NSUserDefaults standardUserDefaults]
            setObject:servers[path.row]
            forKey:@"NineFin.DefaultServer"];

        [self.tableView reloadData];
        return;
    }

    if (path.section != 3) return;

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Aggiungi server"
        message:@"Inserisci l'URL completo di Jellyfin."
        preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:
        ^(UITextField *field) {
            field.placeholder = @"https://jellyfin.example.com";
            field.keyboardType = UIKeyboardTypeURL;
            field.autocapitalizationType =
                UITextAutocapitalizationTypeNone;
            field.autocorrectionType =
                UITextAutocorrectionTypeNo;
        }];

    [alert addAction:[UIAlertAction
        actionWithTitle:@"Annulla"
        style:UIAlertActionStyleCancel handler:nil]];

    [alert addAction:[UIAlertAction
        actionWithTitle:@"Salva e accedi"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            NSString *url =
                NFCleanServer(alert.textFields.firstObject.text);

            NSURL *parsed = [NSURL URLWithString:url];

            if (!parsed.host.length ||
                !([parsed.scheme.lowercaseString
                    isEqualToString:@"http"] ||
                  [parsed.scheme.lowercaseString
                    isEqualToString:@"https"])) {
                NFAlert(self, @"URL non valido",
                    @"Utilizza http:// oppure https://.");
                return;
            }

            NFRememberServer(url);
            NFActivateServer(url);

            if (NFToken.length && NFUser.length)
                [app showLibrary];
            else
                [app showLogin];
        }]];

    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Menu laterale


@interface NFHomeSectionsController : UITableViewController
@end

@implementation NFHomeSectionsController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"Personalizza home";
    self.tableView.backgroundColor = NFBG();
    self.tableView.separatorColor = NFPanel();
    self.tableView.tableFooterView = [[UIView alloc] init];
    self.tableView.rowHeight = 58;
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    return 4;
}

- (NSString *)tableView:(UITableView *)tableView
 titleForHeaderInSection:(NSInteger)section {
    return @"SEZIONI DELLA DASHBOARD";
}

- (void)tableView:(UITableView *)tableView
 willDisplayHeaderView:(UIView *)view
 forSection:(NSInteger)section {
    if (![view isKindOfClass:
            [UITableViewHeaderFooterView class]]) return;

    UITableViewHeaderFooterView *header =
        (UITableViewHeaderFooterView *)view;

    header.contentView.backgroundColor = NFBG();
    header.textLabel.textColor = NFSecondary();
}

- (UITableViewCell *)tableView:(UITableView *)tableView
        cellForRowAtIndexPath:(NSIndexPath *)path {

    NSArray *titles = @[
        @"Continua a guardare",
        @"Prossimo",
        @"Film recenti",
        @"Serie recenti"
    ];

    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault
        reuseIdentifier:nil];

    cell.backgroundColor = NFPanel();
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.textLabel.font = [UIFont systemFontOfSize:16];
    cell.textLabel.text = titles[path.row];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.tag = path.row;
    toggle.onTintColor = NFAccent();
    toggle.on = NFHomeRailEnabled(path.row);

    [toggle addTarget:self
        action:@selector(sectionChanged:)
        forControlEvents:UIControlEventValueChanged];

    cell.accessoryView = toggle;
    return cell;
}

- (void)sectionChanged:(UISwitch *)toggle {
    NSString *key = [NSString stringWithFormat:
        @"NineFin.Home.%ld", (long)toggle.tag];

    NSUserDefaults *defaults =
        [NSUserDefaults standardUserDefaults];

    [defaults setBool:toggle.on forKey:key];
    [defaults synchronize];
}

@end


@interface NFDiscoveryController : NFLibraryController <UISearchBarDelegate>
@property (assign, nonatomic) BOOL favoritesOnly;
@property (strong, nonatomic) UISearchBar *nfSearchBar;
@property (assign, nonatomic) NSUInteger requestVersion;
@property (assign, nonatomic) BOOL hasOpened;
- (instancetype)initWithFavorites:(BOOL)favorites;
@end

@implementation NFDiscoveryController

- (instancetype)initWithFavorites:(BOOL)favorites {
    self = [super initWithParent:@"__discovery__"
                           title:favorites ? @"Preferiti" : @"Ricerca"];
    if (self) self.favoritesOnly = favorites;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    if (!self.favoritesOnly) {
        self.nfSearchBar = [[UISearchBar alloc]
            initWithFrame:CGRectMake(
                0, 0, self.view.bounds.size.width, 52)];

        self.nfSearchBar.delegate = self;
        self.nfSearchBar.placeholder = @"Cerca film, serie, episodi";
        self.nfSearchBar.barStyle = UIBarStyleBlack;
        self.nfSearchBar.barTintColor = NFPanel();
        self.nfSearchBar.tintColor = NFAccent();

        self.tableView.tableHeaderView = self.nfSearchBar;
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    if (self.hasOpened && self.favoritesOnly)
        [self reloadItems];

    self.hasOpened = YES;
}

- (void)dealloc {
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
}

- (void)searchBar:(UISearchBar *)searchBar
    textDidChange:(NSString *)text {

    [NSObject cancelPreviousPerformRequestsWithTarget:self
        selector:@selector(reloadItems) object:nil];

    [self performSelector:@selector(reloadItems)
        withObject:nil afterDelay:0.40];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [NSObject cancelPreviousPerformRequestsWithTarget:self
        selector:@selector(reloadItems) object:nil];

    [searchBar resignFirstResponder];
    [self reloadItems];
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {

    [self.nfSearchBar resignFirstResponder];

    [super tableView:tableView
        didSelectRowAtIndexPath:indexPath];
}

- (void)showEmpty:(NSString *)message {
    if (self.items.count) {
        self.tableView.backgroundView = nil;
        return;
    }

    UILabel *hint = [[UILabel alloc]
        initWithFrame:CGRectMake(
            20, 0, self.view.bounds.size.width - 40, 90)];

    hint.text = message;
    hint.textAlignment = NSTextAlignmentCenter;
    hint.textColor = NFSecondary();
    hint.numberOfLines = 3;
    hint.font = [UIFont systemFontOfSize:14];

    self.tableView.backgroundView = hint;
}

- (void)reloadItems {
    NSUInteger version = ++self.requestVersion;

    NSString *server = [NFServer copy];
    NSString *user = [NFUser copy];

    NSString *term = [self.nfSearchBar.text
        stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (!self.favoritesOnly && term.length < 2) {
        self.items = @[];
        [self.tableView reloadData];
        [self showEmpty:
            @"Digita almeno due caratteri per cercare."];
        return;
    }

    NSURLComponents *query =
        [NSURLComponents componentsWithString:
            [NSString stringWithFormat:
                @"/Users/%@/Items", user ?: @""]];

    NSMutableArray *parameters =
        [NSMutableArray arrayWithArray:@[
            [NSURLQueryItem queryItemWithName:@"Recursive"
                value:@"true"],
            [NSURLQueryItem queryItemWithName:@"IncludeItemTypes"
                value:@"Movie,Series,Episode"],
            [NSURLQueryItem queryItemWithName:@"EnableUserData"
                value:@"true"],
            [NSURLQueryItem queryItemWithName:@"Limit"
                value:@"100"]
        ]];

    if (self.favoritesOnly) {
        [parameters addObject:[NSURLQueryItem
            queryItemWithName:@"Filters"
            value:@"IsFavorite"]];

        [parameters addObject:[NSURLQueryItem
            queryItemWithName:@"SortBy"
            value:@"SortName"]];
    } else {
        [parameters addObject:[NSURLQueryItem
            queryItemWithName:@"SearchTerm" value:term]];
    }

    query.queryItems = parameters;

    __weak NFDiscoveryController *weakSelf = self;

    NFRequest(query.string, @"GET", nil,
        ^(id result, NSError *error) {

            NFDiscoveryController *vc = weakSelf;

            if (!vc || vc.requestVersion != version ||
                ![NFServer isEqualToString:server] ||
                ![NFUser isEqualToString:user])
                return;

            if (error) {
                if (error.code == 401) {
                    NFLogout();

                    [(NFAppDelegate *)
                        [UIApplication sharedApplication].delegate
                        showLogin];
                } else {
                    NFAlert(vc, @"Errore Jellyfin",
                        error.localizedDescription ?:
                            @"Richiesta fallita");
                }
                return;
            }

            NSArray *items =
                [result isKindOfClass:[NSDictionary class]]
                    ? result[@"Items"] : nil;

            vc.items =
                [items isKindOfClass:[NSArray class]]
                    ? items : @[];

            [vc.tableView reloadData];

            [vc showEmpty:vc.favoritesOnly
                ? @"Nessun preferito da mostrare."
                : @"Nessun risultato trovato."];
        });
}

@end

@implementation NFDrawerController

- (void)viewDidLoad {
    [super viewDidLoad];

    CGFloat width = self.view.bounds.size.width;
    CGFloat height = self.view.bounds.size.height;
    CGFloat panelWidth = MIN(310, width * 0.82);

    UIControl *shade = [[UIControl alloc]
        initWithFrame:self.view.bounds];
    shade.autoresizingMask =
        UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    shade.backgroundColor =
        [UIColor colorWithWhite:0 alpha:0.65];
    [shade addTarget:self action:@selector(closeMenu)
        forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:shade];

    UIView *panel = [[UIView alloc]
        initWithFrame:CGRectMake(0, 0, panelWidth, height)];
    panel.backgroundColor = NFPanel();
    panel.autoresizingMask = UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:panel];

    UILabel *logo = [[UILabel alloc]
        initWithFrame:CGRectMake(20, 32, panelWidth - 30, 44)];
    logo.text = @"☰   NineFin";
    logo.font = [UIFont boldSystemFontOfSize:25];
    logo.textColor = NFAccent();
    [panel addSubview:logo];

    UITableView *menu = [[UITableView alloc]
        initWithFrame:CGRectMake(0, 100,
            panelWidth, height - 100)
        style:UITableViewStylePlain];

    menu.autoresizingMask = UIViewAutoresizingFlexibleHeight;
    menu.backgroundColor = NFPanel();
    menu.separatorColor = NFBG();
    menu.tableFooterView = [[UIView alloc] init];
    menu.rowHeight = 56;
    menu.dataSource = self;
    menu.delegate = self;

    [panel addSubview:menu];
}

- (void)closeMenu {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)table
 numberOfRowsInSection:(NSInteger)section {
    return 9;
}

- (UITableViewCell *)tableView:(UITableView *)table
 cellForRowAtIndexPath:(NSIndexPath *)index {
    NSArray *titles = @[
        @"Home",
        @"Ricerca",
        @"Preferiti",
        @"Personalizza home",
        @"Server e predefinito",
        @"Aggiungi server",
        @"Scansiona librerie",
        @"Qualità streaming",
        @"Disconnetti"
    ];

    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault
        reuseIdentifier:nil];

    cell.textLabel.text = titles[index.row];
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.backgroundColor = NFPanel();

    UIView *selected = [[UIView alloc] init];
    selected.backgroundColor = NFBG();
    cell.selectedBackgroundView = selected;

    return cell;
}


- (void)tableView:(UITableView *)table
 didSelectRowAtIndexPath:(NSIndexPath *)index {

    NSInteger newSelection = index.row;
    NSInteger selection = newSelection > 2
        ? newSelection - 2 : newSelection;

    UIViewController *host = self.host;

    [self dismissViewControllerAnimated:YES completion:^{

        if (selection == 0) return;

        if (newSelection == 1 || newSelection == 2) {
            NFDiscoveryController *discovery =
                [[NFDiscoveryController alloc]
                    initWithFavorites:(newSelection == 2)];

            [host.navigationController
                pushViewController:discovery animated:YES];

            return;
        }

        if (selection == 1) {
            NFHomeSectionsController *settings =
                [[NFHomeSectionsController alloc]
                    initWithStyle:UITableViewStyleGrouped];

            [host.navigationController
                pushViewController:settings animated:YES];
            return;
        }

        if (selection == 2 || selection == 3) {
            NFServersController *servers =
                [[NFServersController alloc]
                    initWithStyle:UITableViewStyleGrouped];

            [host.navigationController
                pushViewController:servers animated:YES];

            if (selection == 3) {
                [servers.tableView scrollToRowAtIndexPath:
                    [NSIndexPath indexPathForRow:0 inSection:3]
                    atScrollPosition:UITableViewScrollPositionBottom
                    animated:YES];
            }
            return;
        }

        if (selection == 4) {
            NSString *message = [NSString stringWithFormat:
                @"Vuoi avviare una nuova scansione delle "
                 @"librerie Jellyfin sul server attivo?\n\n%@",
                NFServer ?: @"Nessun server"];

            UIAlertController *confirm = [UIAlertController
                alertControllerWithTitle:@"Scansione librerie"
                message:message
                preferredStyle:UIAlertControllerStyleAlert];

            [confirm addAction:[UIAlertAction
                actionWithTitle:@"Annulla"
                style:UIAlertActionStyleCancel handler:nil]];

            [confirm addAction:[UIAlertAction
                actionWithTitle:@"Avvia scansione"
                style:UIAlertActionStyleDestructive
                handler:^(UIAlertAction *action) {

                    NFRequest(@"/Library/Refresh", @"POST",
                        nil, ^(id result, NSError *error) {

                        if (error) {
                            NSString *detail =
                                error.localizedDescription;

                            if (error.code == 401 ||
                                error.code == 403) {
                                detail =
                                    @"Jellyfin richiede "
                                     @"un account amministratore "
                                     @"per avviare la scansione.";
                            }

                            NFAlert(host,
                                @"Scansione non avviata",
                                detail ?: @"Errore sconosciuto");
                            return;
                        }

                        NFAlert(host,
                            @"Richiesta accettata",
                            @"Jellyfin ha ricevuto la richiesta "
                             @"di scansione. L'operazione "
                             @"continua sul server.");
                    });
                }]];

            [host presentViewController:confirm
                animated:YES completion:nil];
            return;
        }


        if (selection == 5) {
            NSArray *rates = @[
                @800000, @1500000, @2500000, @4000000
            ];

            NSArray *names = @[
                @"0,8 Mbps",
                @"1,5 Mbps",
                @"2,5 Mbps",
                @"4 Mbps"
            ];

            NSMutableArray *choices =
                [NSMutableArray array];

            for (NSUInteger i = 0; i < rates.count; i++) {
                [choices addObject:@{
                    @"title": names[i],
                    @"value": rates[i]
                }];
            }

            NFChoiceController *picker =
                [[NFChoiceController alloc]
                    initWithStyle:UITableViewStyleGrouped];

            picker.title = @"Qualità streaming";
            picker.entries = choices;
            picker.current = @(NFStreamingBitrate());

            picker.picked = ^(NSNumber *selected) {
                [[NSUserDefaults standardUserDefaults]
                    setInteger:selected.integerValue
                    forKey:@"NineFin.StreamingBitrate"];
            };

            [host.navigationController
                pushViewController:picker animated:YES];
            return;
        }

        if (selection == 6) {
            NFRequest(@"/Sessions/Logout", @"POST",
                nil, ^(id result, NSError *error) {});

            NFLogout();

            [(NFAppDelegate *)
                [UIApplication sharedApplication].delegate
                showLogin];
        }
    }];
}


@end



#pragma mark - Schede dettagliate NineFin

@implementation NFDetailsController


- (void)nfLoadTracks {
    NSArray *sources = self.item[@"MediaSources"];

    if ([sources isKindOfClass:[NSArray class]] &&
        sources.count) {
        [self nfApplySources:sources];
        return;
    }

    NSString *itemId = self.item[@"Id"];
    NSString *server = [NFServer copy];
    NSString *user = [NFUser copy];

    if (!itemId.length || !user.length)
        return;

    NSString *path = [NSString stringWithFormat:
        @"/Items/%@/PlaybackInfo?UserId=%@",
        itemId, user];

    __weak NFDetailsController *weakSelf = self;

    NFRequest(path, @"GET", nil,
        ^(id result, NSError *error) {

        NFDetailsController *vc = weakSelf;

        if (!vc ||
            ![NFServer isEqualToString:server] ||
            ![NFUser isEqualToString:user])
            return;

        if (error) {
            NSLog(@"NineFin tracks: %@", error);
            return;
        }

        [vc nfApplySources:result[@"MediaSources"]];
    });
}

- (void)nfApplySources:(NSArray *)sources {
    if (![sources isKindOfClass:[NSArray class]])
        return;

    for (id value in sources) {
        if (![value isKindOfClass:[NSDictionary class]])
            continue;

        NSDictionary *source = value;
        NSString *sid = source[@"Id"];
        NSArray *streams = source[@"MediaStreams"];

        if (![sid isKindOfClass:[NSString class]] ||
            ![streams isKindOfClass:[NSArray class]])
            continue;

        if (![sid isEqualToString:self.nfSourceId]) {
            self.nfAudio = nil;
            self.nfSubtitle = nil;
        }

        self.nfSourceId = sid;
        self.nfStreams = streams;
        [self renderHeader];
        break;
    }
}

- (NSString *)nfTrackName:(NSDictionary *)track {
    NSString *name = track[@"DisplayTitle"];

    if (![name isKindOfClass:[NSString class]] ||
        !name.length)
        name = track[@"Language"];

    if (![name isKindOfClass:[NSString class]] ||
        !name.length)
        name = @"Sconosciuta";

    return [NSString stringWithFormat:@"%@ (#%@)",
        name, track[@"Index"] ?: @"?"];
}

- (NSString *)nfSelectionLabel:(NSNumber *)index
                          type:(NSString *)type {
    if (!index)
        return @"Automatica";

    if (index.integerValue == -1)
        return @"Disattivati";

    for (NSDictionary *track in self.nfStreams) {
        if ([track[@"Type"] isEqualToString:type] &&
            [track[@"Index"] isEqual:index])
            return [self nfTrackName:track];
    }

    return @"Traccia scelta";
}

- (void)nfChoose:(NSString *)type {
    if (!self.nfSourceId.length) {
        NFAlert(self, @"Tracce non caricate",
            @"Attendi il caricamento dei dettagli.");
        return;
    }

    BOOL sub = [type isEqualToString:@"Subtitle"];

    NSMutableArray *entries =
        [NSMutableArray arrayWithObject:@{
            @"title": @"Automatica",
            @"value": @(-2)
        }];

    if (sub) {
        [entries addObject:@{
            @"title": @"Disattivati",
            @"value": @(-1)
        }];
    }

    for (NSDictionary *track in self.nfStreams) {
        if (![track isKindOfClass:[NSDictionary class]] ||
            ![track[@"Type"] isEqualToString:type] ||
            ![track[@"Index"] isKindOfClass:[NSNumber class]])
            continue;

        [entries addObject:@{
            @"title": [self nfTrackName:track],
            @"value": track[@"Index"]
        }];
    }

    NFChoiceController *picker =
        [[NFChoiceController alloc]
            initWithStyle:UITableViewStyleGrouped];

    picker.title = sub ? @"Sottotitoli" : @"Audio";
    picker.entries = entries;
    picker.current =
        (sub ? self.nfSubtitle : self.nfAudio) ?: @(-2);

    __weak NFDetailsController *weakSelf = self;

    picker.picked = ^(NSNumber *number) {
        NFDetailsController *vc = weakSelf;
        if (!vc) return;

        NSNumber *chosen =
            number.integerValue == -2 ? nil : number;

        if (sub)
            vc.nfSubtitle = chosen;
        else
            vc.nfAudio = chosen;

        [vc renderHeader];
    };

    [self.navigationController
        pushViewController:picker animated:YES];
}

- (void)nfChooseAudio {
    [self nfChoose:@"Audio"];
}

- (void)nfChooseSubtitles {
    [self nfChoose:@"Subtitle"];
}

- (instancetype)initWithItem:(NSDictionary *)item
                       owner:(NFLibraryController *)owner {
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (self) {
        _item = [item copy];
        _playerOwner = owner;
        _seasons = @[];
        _episodes = @[];
        _seasonId = nil;
    }
    return self;
}

- (BOOL)isSeries {
    return [self.item[@"Type"] isEqualToString:@"Series"];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = self.item[@"Name"] ?: @"Dettagli";

    self.tableView.backgroundColor = NFBG();
    self.tableView.separatorColor = NFPanel();
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 70;
    self.tableView.tableFooterView = [[UIView alloc] init];

    [self renderHeader];
    [self reloadDetails];

    if ([self isSeries])
        [self loadSeasons];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    if (self.appeared) {
        [self reloadDetails];

        if ([self isSeries] && self.seasonId.length)
            [self loadEpisodes:self.seasonId];
    }

    self.appeared = YES;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat width = self.tableView.bounds.size.width;

    if (fabs(width - self.headerWidth) > 2)
        [self renderHeader];
}

- (void)reloadDetails {
    NSString *itemId = self.item[@"Id"];
    if (!itemId.length || !NFUser.length) return;

    NSString *server = [NFServer copy];
    NSString *user = [NFUser copy];

    NSString *path = [NSString stringWithFormat:
        @"/Users/%@/Items/%@", user, itemId];

    __weak NFDetailsController *weakSelf = self;

    NFRequest(path, @"GET", nil,
        ^(id result, NSError *error) {

        NFDetailsController *vc = weakSelf;
        if (!vc) return;

        if (![NFServer isEqualToString:server] ||
            ![NFUser isEqualToString:user])
            return;

        if (error || ![result isKindOfClass:[NSDictionary class]]) {
            NSLog(@"NineFin metadata: %@", error);
            return;
        }

        vc.item = result;
        vc.title = result[@"Name"] ?: @"Dettagli";
        [vc renderHeader];
        [vc nfLoadTracks];
    });
}

- (void)renderHeader {
    CGFloat width = self.tableView.bounds.size.width;
    if (width < 200)
        width = [UIScreen mainScreen].bounds.size.width;

    self.headerWidth = width;

    NSString *name = self.item[@"Name"] ?: @"Contenuto";
    NSString *overview = self.item[@"Overview"];

    if (![overview isKindOfClass:[NSString class]] ||
        !overview.length)
        overview = @"Nessuna trama disponibile.";

    UIView *header = [[UIView alloc]
        initWithFrame:CGRectMake(0, 0, width, 250)];

    header.backgroundColor = NFBG();

    UIImageView *poster = [[UIImageView alloc]
        initWithFrame:CGRectMake(16, 18, 105, 157)];

    poster.backgroundColor = NFPanel();
    poster.layer.cornerRadius = 6;
    poster.clipsToBounds = YES;
    poster.contentMode = UIViewContentModeScaleAspectFill;

    [header addSubview:poster];

    NFPoster(self.item[@"Id"], poster);

    CGFloat textX = 134;
    CGFloat textWidth = MAX(80, width - textX - 16);

    UILabel *titleLabel = [[UILabel alloc]
        initWithFrame:CGRectMake(textX, 19, textWidth, 62)];

    titleLabel.text = name;
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.font = [UIFont boldSystemFontOfSize:19];
    titleLabel.numberOfLines = 3;

    [header addSubview:titleLabel];

    NSMutableArray *metadata = [NSMutableArray array];

    id year = self.item[@"ProductionYear"];
    if ([year respondsToSelector:@selector(stringValue)])
        [metadata addObject:[year stringValue]];

    double ticks = [self.item[@"RunTimeTicks"] doubleValue];

    if (ticks > 0) {
        NSInteger minutes = (NSInteger)(ticks / 600000000.0);

        [metadata addObject:[NSString
            stringWithFormat:@"%ld min", (long)minutes]];
    }

    NSArray *genres = self.item[@"Genres"];

    if ([genres isKindOfClass:[NSArray class]]) {
        NSUInteger count = MIN(2, genres.count);

        for (NSUInteger i = 0; i < count; i++) {
            if ([genres[i] isKindOfClass:[NSString class]])
                [metadata addObject:genres[i]];
        }
    }

    UILabel *metadataLabel = [[UILabel alloc]
        initWithFrame:CGRectMake(textX, 83, textWidth, 88)];

    metadataLabel.text =
        [metadata componentsJoinedByString:@"\n"];
    metadataLabel.textColor = NFSecondary();
    metadataLabel.font = [UIFont systemFontOfSize:13];
    metadataLabel.numberOfLines = 5;

    [header addSubview:metadataLabel];

    UILabel *overviewTitle = [[UILabel alloc]
        initWithFrame:CGRectMake(16, 190, width - 32, 25)];

    overviewTitle.text = @"Trama";
    overviewTitle.font = [UIFont boldSystemFontOfSize:18];
    overviewTitle.textColor = [UIColor whiteColor];

    [header addSubview:overviewTitle];

    UIFont *font = [UIFont systemFontOfSize:14];

    CGRect measured = [overview boundingRectWithSize:
        CGSizeMake(width - 32, CGFLOAT_MAX)
        options:NSStringDrawingUsesLineFragmentOrigin
        attributes:@{NSFontAttributeName: font}
        context:nil];

    CGFloat overviewHeight =
        MAX(48, MIN(380, ceil(measured.size.height) + 10));

    UILabel *description = [[UILabel alloc]
        initWithFrame:CGRectMake(
            16, 223, width - 32, overviewHeight)];

    description.text = overview;
    description.textColor = NFSecondary();
    description.font = font;
    description.numberOfLines = 0;
    description.lineBreakMode = NSLineBreakByTruncatingTail;

    [header addSubview:description];

    CGFloat bottom = CGRectGetMaxY(description.frame) + 18;

    if (![self isSeries]) {
        UIButton *play =
            [UIButton buttonWithType:UIButtonTypeSystem];

        play.frame = CGRectMake(
            16, bottom, width - 32, 46);

        play.backgroundColor = NFAccent();
        play.layer.cornerRadius = 8;

        double position =
            [self.item[@"UserData"][@"PlaybackPositionTicks"]
                doubleValue];

        NSString *label =
            position > 0 ? @"▶  Riprendi" : @"▶  Riproduci";

        [play setTitle:label forState:UIControlStateNormal];

        [play setTitleColor:[UIColor whiteColor]
                  forState:UIControlStateNormal];

        [play addTarget:self
            action:@selector(playPressed)
            forControlEvents:UIControlEventTouchUpInside];

        [header addSubview:play];
        bottom += 62;

        NSArray *titles = @[
            [@"Audio: " stringByAppendingString:
                [self nfSelectionLabel:self.nfAudio
                                  type:@"Audio"]],
            [@"Sottotitoli: " stringByAppendingString:
                [self nfSelectionLabel:self.nfSubtitle
                                  type:@"Subtitle"]]
        ];

        SEL selectors[] = {
            @selector(nfChooseAudio),
            @selector(nfChooseSubtitles)
        };

        for (NSInteger i = 0; i < 2; i++) {
            UIButton *b =
                [UIButton buttonWithType:UIButtonTypeSystem];

            b.frame =
                CGRectMake(16, bottom, width - 32, 40);
            b.backgroundColor = NFPanel();
            b.layer.cornerRadius = 7;
            b.titleLabel.font =
                [UIFont systemFontOfSize:13];

            [b setTitle:titles[i]
                forState:UIControlStateNormal];
            [b setTitleColor:[UIColor whiteColor]
                forState:UIControlStateNormal];

            [b addTarget:self action:selectors[i]
                forControlEvents:UIControlEventTouchUpInside];

            [header addSubview:b];
            bottom += 47;
        }
    }

    UIButton *favorite =
        [UIButton buttonWithType:UIButtonTypeSystem];

    favorite.frame =
        CGRectMake(16, bottom, width - 32, 42);

    favorite.backgroundColor = NFPanel();
    favorite.layer.cornerRadius = 7;
    favorite.titleLabel.font =
        [UIFont systemFontOfSize:15];

    BOOL active =
        [self.item[@"UserData"][@"IsFavorite"] boolValue];

    [favorite setTitle:(active
        ? @"★ Rimuovi dai preferiti"
        : @"☆ Aggiungi ai preferiti")
        forState:UIControlStateNormal];

    [favorite setTitleColor:NFAccent()
        forState:UIControlStateNormal];

    [favorite addTarget:self
        action:@selector(nfToggleFavorite)
        forControlEvents:UIControlEventTouchUpInside];

    favorite.enabled = !self.nfFavoriteBusy;

    [header addSubview:favorite];
    bottom += 55;

    header.frame = CGRectMake(0, 0, width, bottom);
    self.tableView.tableHeaderView = header;
}


- (void)nfToggleFavorite {
    NSString *itemId = self.item[@"Id"];
    NSString *server = [NFServer copy];
    NSString *user = [NFUser copy];

    if (!itemId.length || !user.length || self.nfFavoriteBusy)
        return;

    BOOL wasFavorite =
        [self.item[@"UserData"][@"IsFavorite"] boolValue];

    BOOL target = !wasFavorite;

    NSString *path = [NSString stringWithFormat:
        @"/Users/%@/FavoriteItems/%@", user, itemId];

    self.nfFavoriteBusy = YES;

    __weak NFDetailsController *weakSelf = self;

    NFRequest(path, target ? @"POST" : @"DELETE", nil,
        ^(id result, NSError *error) {

            NFDetailsController *vc = weakSelf;
            if (!vc) return;

            vc.nfFavoriteBusy = NO;

            if (![NFServer isEqualToString:server] ||
                ![NFUser isEqualToString:user] ||
                ![vc.item[@"Id"] isEqualToString:itemId])
                return;

            if (error) {
                NFAlert(vc, @"Preferiti",
                    error.localizedDescription);
                return;
            }

            NSMutableDictionary *updated =
                [vc.item mutableCopy];

            NSDictionary *old = vc.item[@"UserData"];

            NSMutableDictionary *data =
                [old isKindOfClass:[NSDictionary class]]
                    ? [old mutableCopy]
                    : [NSMutableDictionary dictionary];

            data[@"IsFavorite"] = @(target);
            updated[@"UserData"] = data;

            vc.item = updated;
            [vc renderHeader];
        });
}

- (void)playPressed {
    if (!self.playerOwner) {
        NFAlert(self, @"Player non disponibile",
            @"Torna alla libreria e riapri il contenuto.");
        return;
    }

    [self.playerOwner playItem:self.item
        audio:self.nfAudio
        subtitle:self.nfSubtitle
        sourceId:self.nfSourceId];
}

- (void)loadSeasons {
    NSString *seriesId = self.item[@"Id"];
    if (!seriesId.length) return;

    NSString *server = [NFServer copy];
    NSString *user = [NFUser copy];

    NSString *path = [NSString stringWithFormat:
        @"/Shows/%@/Seasons?UserId=%@"
         "&Fields=Overview,UserData",
        seriesId, user];

    __weak NFDetailsController *weakSelf = self;

    NFRequest(path, @"GET", nil,
        ^(id result, NSError *error) {

        NFDetailsController *vc = weakSelf;
        if (!vc) return;

        if (![NFServer isEqualToString:server] ||
            ![NFUser isEqualToString:user])
            return;

        if (error) {
            NFAlert(vc, @"Errore stagioni",
                error.localizedDescription);
            return;
        }

        NSArray *items = result[@"Items"];

        vc.seasons = [items isKindOfClass:[NSArray class]]
            ? items : @[];

        [vc.tableView reloadData];

        if (vc.seasons.count) {
            NSString *selected = vc.seasonId;

            BOOL found = NO;
            for (NSDictionary *season in vc.seasons) {
                if ([season[@"Id"] isEqualToString:selected])
                    found = YES;
            }

            if (!found)
                selected = vc.seasons[0][@"Id"];

            if (selected.length) {
                vc.seasonId = selected;
                [vc loadEpisodes:selected];
            }
        }
    });
}

- (void)loadEpisodes:(NSString *)seasonId {
    if (!seasonId.length) return;

    NSUInteger generation = ++self.episodeGeneration;
    NSString *server = [NFServer copy];
    NSString *user = [NFUser copy];

    NSString *path = [NSString stringWithFormat:
        @"/Shows/%@/Episodes?"
         "UserId=%@&SeasonId=%@"
         "&Fields=Overview,UserData",
        self.item[@"Id"], user, seasonId];

    __weak NFDetailsController *weakSelf = self;

    NFRequest(path, @"GET", nil,
        ^(id result, NSError *error) {

        NFDetailsController *vc = weakSelf;
        if (!vc) return;

        if (generation != vc.episodeGeneration ||
            ![vc.seasonId isEqualToString:seasonId] ||
            ![NFServer isEqualToString:server] ||
            ![NFUser isEqualToString:user])
            return;

        if (error) {
            NFAlert(vc, @"Errore episodi",
                error.localizedDescription);
            return;
        }

        NSArray *items = result[@"Items"];

        vc.episodes = [items isKindOfClass:[NSArray class]]
            ? items : @[];

        [vc.tableView reloadData];
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table {
    return [self isSeries] ? 2 : 0;
}

- (NSInteger)tableView:(UITableView *)table
 numberOfRowsInSection:(NSInteger)section {

    if (section == 0)
        return self.seasons.count;

    if (section == 1)
        return self.episodes.count;

    return 0;
}

- (NSString *)tableView:(UITableView *)table
 titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"STAGIONI" : @"EPISODI";
}

- (void)tableView:(UITableView *)table
 willDisplayHeaderView:(UIView *)view
 forSection:(NSInteger)section {

    if (![view isKindOfClass:
            [UITableViewHeaderFooterView class]])
        return;

    UITableViewHeaderFooterView *header =
        (UITableViewHeaderFooterView *)view;

    header.contentView.backgroundColor = NFBG();
    header.textLabel.textColor = NFSecondary();
}

- (UITableViewCell *)tableView:(UITableView *)table
 cellForRowAtIndexPath:(NSIndexPath *)path {

    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleSubtitle
        reuseIdentifier:nil];

    cell.backgroundColor = NFPanel();
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.detailTextLabel.textColor = NFSecondary();
    cell.textLabel.numberOfLines = 2;

    if (path.section == 0) {
        NSDictionary *season = self.seasons[path.row];

        cell.textLabel.text =
            season[@"Name"] ?: @"Stagione";

        BOOL selected =
            [season[@"Id"] isEqualToString:self.seasonId];

        cell.accessoryType = selected
            ? UITableViewCellAccessoryCheckmark
            : UITableViewCellAccessoryDisclosureIndicator;

        cell.tintColor = NFAccent();

    } else {
        NSDictionary *episode = self.episodes[path.row];

        NSString *name =
            episode[@"Name"] ?: @"Episodio";

        NSNumber *number = episode[@"IndexNumber"];

        cell.textLabel.text = number
            ? [NSString stringWithFormat:
                @"E%@ · %@", number, name]
            : name;

        NSDictionary *data = episode[@"UserData"];

        if ([data[@"Played"] boolValue]) {
            cell.detailTextLabel.text = @"✓ Visto";
        } else if ([data[@"PlaybackPositionTicks"]
                    longLongValue] > 0) {
            cell.detailTextLabel.text = @"Da riprendere";
        } else {
            cell.detailTextLabel.text =
                @"Tocca per i dettagli";
        }

        cell.accessoryType =
            UITableViewCellAccessoryDisclosureIndicator;
    }

    return cell;
}

- (void)tableView:(UITableView *)table
 didSelectRowAtIndexPath:(NSIndexPath *)path {

    [table deselectRowAtIndexPath:path animated:YES];

    if (path.section == 0) {
        NSDictionary *season = self.seasons[path.row];
        NSString *identifier = season[@"Id"];

        if (!identifier.length) return;

        self.seasonId = identifier;
        self.episodes = @[];
        [self.tableView reloadData];
        [self loadEpisodes:identifier];
        return;
    }

    if (path.section == 1) {
        NSDictionary *episode = self.episodes[path.row];

        NFDetailsController *next =
            [[NFDetailsController alloc]
                initWithItem:episode
                owner:self.playerOwner];

        [self.navigationController
            pushViewController:next animated:YES];
    }
}

@end

@implementation NFAppDelegate

- (BOOL)application:(UIApplication *)application
 didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc]
        initWithFrame:[UIScreen mainScreen].bounds];

    UINavigationBar *bar = [UINavigationBar appearance];
    bar.barTintColor = NFPanel();
    bar.tintColor = NFAccent();
    bar.barStyle = UIBarStyleBlack;
    bar.translucent = NO;
    bar.titleTextAttributes = @{
        NSForegroundColorAttributeName: [UIColor whiteColor]
    };

    [UIApplication sharedApplication].statusBarStyle =
        UIStatusBarStyleLightContent;

    NFRestore();

    if (NFServer.length && NFToken.length && NFUser.length)
        [self showLibrary];
    else
        [self showLogin];

    [self.window makeKeyAndVisible];
    return YES;
}

- (void)showLogin {
    NFLoginController *login =
        [[NFLoginController alloc] init];

    UINavigationController *navigation =
        [[UINavigationController alloc]
            initWithRootViewController:login];

    self.window.rootViewController = navigation;
}

- (void)showLibrary {
    NFHomeController *library =
        [[NFHomeController alloc]
            initWithParent:nil title:@"NineFin"];

    UINavigationController *navigation =
        [[UINavigationController alloc]
            initWithRootViewController:library];

    self.window.rootViewController = navigation;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv,
            nil, NSStringFromClass([NFAppDelegate class]));
    }
}
