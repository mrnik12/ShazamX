#import "RelayConfig.h"
#import <CoreData/CoreData.h>
#import <AudioToolbox/AudioToolbox.h>
#import <QuartzCore/QuartzCore.h>
#import <CommonCrypto/CommonDigest.h>
#import <ImageIO/ImageIO.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface SHCoreDataHelper : NSObject
- (NSManagedObjectContext *)managedObjectContext;
- (BOOL)save:(NSError **)error;
@end

@interface SHTaggingDataManager : NSObject
- (SHCoreDataHelper *)coreDataHelper;
- (NSArray *)unsubmittedTags;
- (void)deleteTag:(NSManagedObject *)tag;
- (void)cacheTagCountData;
- (NSManagedObject *)saveTagWithTrackId:(id)trackId eventId:(id)eventId tagId:(NSString *)tagId;
@end

static SHTaggingDataManager *LSTagManager(void) {
    id delegate = [UIApplication sharedApplication].delegate;
    return [delegate respondsToSelector:@selector(taggingDataManager)]
        ? [delegate performSelector:@selector(taggingDataManager)] : nil;
}

static NSManagedObjectContext *LSHistoryContext(void) {
    SHTaggingDataManager *manager = LSTagManager();
    return [manager respondsToSelector:@selector(coreDataHelper)]
        ? [[manager coreDataHelper] managedObjectContext] : nil;
}

static void LSRefreshTagCount(void) {
    SHTaggingDataManager *manager = LSTagManager();
    if ([manager respondsToSelector:@selector(cacheTagCountData)]) {
        [manager cacheTagCountData];
    }
}

static void LSCopyMatchFields(NSManagedObject *preview, NSManagedObject *saved) {
    NSArray *fields = @[@"name", @"subtitle", @"cachedArtistString", @"type", @"date", @"completeResult",
                        @"albumArtData", @"albumArtThumbnailData"];
    NSDictionary *previewAttributes = preview.entity.attributesByName;
    NSDictionary *savedAttributes = saved.entity.attributesByName;
    for (NSString *key in fields) {
        if (previewAttributes[key] && savedAttributes[key]) {
            id value = [preview valueForKey:key];
            if (value) {
                [saved setValue:value forKey:key];
            }
        }
    }
}

static NSManagedObject *LSSaveMatch(NSManagedObject *preview) {
    NSManagedObjectContext *context = LSHistoryContext();
    if (!context) { return nil; }
    NSEntityDescription *tagEntity = [NSEntityDescription entityForName:@"SHAudioTagMO" inManagedObjectContext:context];
    NSEntityDescription *resultEntity = [NSEntityDescription entityForName:@"SHTagResultMO" inManagedObjectContext:context];
    if (!tagEntity || !resultEntity || ![[tagEntity relationshipsByName] objectForKey:@"tagResult"] ||
        ![[resultEntity attributesByName] objectForKey:@"isInUserTagList"]) {
        return nil;
    }

    NSManagedObject *tag = [[[NSClassFromString(tagEntity.managedObjectClassName) alloc] initWithEntity:tagEntity insertIntoManagedObjectContext:nil] autorelease];
    NSManagedObject *saved = [[[NSClassFromString(resultEntity.managedObjectClassName) alloc] initWithEntity:resultEntity insertIntoManagedObjectContext:nil] autorelease];
    LSCopyMatchFields(preview, saved);
    [saved setValue:@YES forKey:@"isInUserTagList"];
    [saved setValue:@YES forKey:@"viewed"];
    [tag setValue:[preview valueForKey:@"date"] forKey:@"date"];
    [tag setValue:@YES forKey:@"submitted"];
    [tag setValue:[[NSUUID UUID] UUIDString] forKey:@"tagId"];
    [context insertObject:saved];
    [context insertObject:tag];
    [tag setValue:saved forKey:@"tagResult"];
    NSError *error = nil;
    if (![context save:&error]) {
        [context deleteObject:tag];
        if (saved.managedObjectContext && ![saved isDeleted]) {
            [context deleteObject:saved];
        }
        NSLog(@"[ShazamX] My Tags save failed: %@", error);
        return nil;
    }
    LSRefreshTagCount();
    return saved;
}

static BOOL LSShazam720;

static NSString *LSRelayDiagnostic(NSURL *url, NSString *stage, NSError *error) {
    NSMutableArray *codes = [NSMutableArray array];
    for (NSError *cause = error; [cause isKindOfClass:[NSError class]] && codes.count < 4;
         cause = [cause.userInfo objectForKey:NSUnderlyingErrorKey]) {
        NSMutableString *entry = [NSMutableString stringWithFormat:@"%@ %ld", cause.domain, (long)cause.code];
        id domain = [cause.userInfo objectForKey:@"_kCFStreamErrorDomainKey"];
        id code = [cause.userInfo objectForKey:@"_kCFStreamErrorCodeKey"];
        if ([domain isKindOfClass:[NSNumber class]] && [code isKindOfClass:[NSNumber class]]) {
            [entry appendFormat:@" (stream %@/%@)", domain, code];
        }
        [codes addObject:entry];
    }
    return [NSString stringWithFormat:@"%@ %@ failed.\n%@\n%@", url.host, stage,
        [codes componentsJoinedByString:@" ? "], error.localizedDescription];
}

@interface NSData (LSFlatBase64)
- (NSString *)base64EncodedStringWithOptions:(NSUInteger)options;
@end

typedef void (^LSRelayCompletion)(NSURLResponse *, NSData *, NSError *);

@interface LSRelayWebRequest : NSObject <UIWebViewDelegate> {
    UIWebView *_web;
    NSURLRequest *_request;
    NSURL *_healthURL;
    LSRelayCompletion _completion;
    NSDate *_deadline;
    BOOL _submitted;
}
- (id)initWithRequest:(NSURLRequest *)request completion:(LSRelayCompletion)completion;
- (void)start;
- (void)cancel;
@end

@implementation LSRelayWebRequest
- (id)initWithRequest:(NSURLRequest *)request completion:(LSRelayCompletion)completion {
    self = [super init];
    if (self) {
        _request = [request copy];
        _completion = [completion copy];
        _deadline = [[NSDate dateWithTimeIntervalSinceNow:request.timeoutInterval] retain];
        _web = [[UIWebView alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
        _web.delegate = self;
        _healthURL = [[[NSURL URLWithString:@"/health" relativeToURL:request.URL] absoluteURL] retain];
    }
    return self;
}

- (void)start {
    [_web loadRequest:[NSURLRequest requestWithURL:_healthURL
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:_request.timeoutInterval]];
    [self poll];
}

- (void)dealloc {
    _web.delegate = nil;
    [_web release];
    [_request release];
    [_healthURL release];
    [_completion release];
    [_deadline release];
    [super dealloc];
}

- (void)cancel {
    LSRelayCompletion completion = _completion;
    _completion = nil;
    _web.delegate = nil;
    if (_submitted && [_request.HTTPMethod isEqualToString:@"POST"]) {
        [_web stringByEvaluatingJavaScriptFromString:
            @"var x=window.__shazamxUpload;if(x&&x.readyState<4)x.abort();window.__shazamxUpload=null;"];
    }
    [_web stopLoading];
    [completion release];
}

- (void)finishStatus:(NSInteger)status data:(NSData *)data error:(NSError *)error {
    if (!_completion) {
        return;
    }
    LSRelayCompletion completion = _completion;
    _completion = nil;
    [self cancel];
    NSHTTPURLResponse *response = status ? [[[NSHTTPURLResponse alloc] initWithURL:_request.URL
        statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:nil] autorelease] : nil;
    [self retain];
    completion(response, data, error);
    [completion release];
    [self release];
}

- (void)failWithCode:(NSInteger)code description:(NSString *)description {
    NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey: description}];
    [self finishStatus:0 data:nil error:error];
}

- (BOOL)webView:(UIWebView *)view shouldStartLoadWithRequest:(NSURLRequest *)request
 navigationType:(UIWebViewNavigationType)type {
    return [request.URL.absoluteString isEqualToString:_healthURL.absoluteString];
}

- (void)webView:(UIWebView *)view didFailLoadWithError:(NSError *)error {
    if (error.code != NSURLErrorCancelled) {
        [self finishStatus:0 data:nil error:error];
    }
}

- (void)webViewDidFinishLoad:(UIWebView *)view {
    if (!_completion || _submitted ||
        ![[view stringByEvaluatingJavaScriptFromString:@"location.href"]
          isEqualToString:_healthURL.absoluteString]) {
        return;
    }
    _submitted = YES;
    if ([_request.HTTPMethod isEqualToString:@"GET"]) {
        NSString *body = [view stringByEvaluatingJavaScriptFromString:@"document.body.textContent"];
        NSData *data = [body dataUsingEncoding:NSUTF8StringEncoding];
        id payload = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        NSInteger status = [payload isKindOfClass:[NSDictionary class]] && [[payload objectForKey:@"ok"] isEqual:@YES] ? 200 : 503;
        [self finishStatus:status data:data error:nil];
        return;
    }
    NSString *base64 = [_request.HTTPBody base64EncodedStringWithOptions:0];
    NSString *script = [NSString stringWithFormat:
        @"(function(){window.__shazamxResult=null;try{"
         "var x=window.__shazamxUpload=new XMLHttpRequest(),b=atob('%@'),a=new Uint8Array(b.length);"
         "for(var i=0;i<b.length;i++)a[i]=b.charCodeAt(i);"
         "x.open('POST','/recognize',true);x.timeout=45000;"
         "x.setRequestHeader('Content-Type','audio/wav');"
         "x.onload=function(){window.__shazamxResult=JSON.stringify([x.status,x.responseText]);};"
         "var sent=0;x.upload.onprogress=function(e){sent=e.loaded;};"
         "x.onerror=function(){window.__shazamxResult=JSON.stringify([0,'No HTTP response. Upload progress: '+sent+'/'+a.length+' bytes.']);};"
         "x.ontimeout=function(){window.__shazamxResult=JSON.stringify([-1,'The relay did not reply to the recording within 45 seconds.']);};"
         "x.send(new Blob([a.buffer],{type:'audio/wav'}));}catch(e){window.__shazamxResult=JSON.stringify([0,'WebKit upload: '+e.name]);}})()",
        base64];
    [view stringByEvaluatingJavaScriptFromString:script];
}

- (void)poll {
    if (!_completion) {
        return;
    }
    if ([_deadline timeIntervalSinceNow] <= 0) {
        [self failWithCode:NSURLErrorTimedOut description:@"WebKit did not receive a relay response in time."];
        return;
    }
    if (_submitted) {
        NSString *value = [_web stringByEvaluatingJavaScriptFromString:@"window.__shazamxResult || ''"];
        NSData *json = [value dataUsingEncoding:NSUTF8StringEncoding];
        id result = json.length ? [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL] : nil;
        if ([result isKindOfClass:[NSArray class]] && [result count] == 2 &&
            [[result objectAtIndex:0] isKindOfClass:[NSNumber class]] &&
            [[result objectAtIndex:1] isKindOfClass:[NSString class]]) {
            NSInteger status = [[result objectAtIndex:0] integerValue];
            if (status > 0) {
                [self finishStatus:status data:[[result objectAtIndex:1] dataUsingEncoding:NSUTF8StringEncoding] error:nil];
            } else {
                [self failWithCode:(status == -1 ? NSURLErrorTimedOut : NSURLErrorCannotConnectToHost)
                                   description:[result objectAtIndex:1]];
            }
            return;
        }
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 8), dispatch_get_main_queue(), ^{
        [self poll];
    });
}
@end

static BOOL LSRelayUsesWebKit(NSURLRequest *request) {
    NSURL *url = request.URL;
    return LSShazam720 && [url.scheme isEqualToString:@"https"] &&
        ([url.host isEqualToString:@"legacy-shazam-relay.onrender.com"] ||
         [url.host isEqualToString:[[NSURL URLWithString:LS_RELAY_URL] host]]) &&
        ([url.path isEqualToString:@"/health"] || [url.path isEqualToString:@"/recognize"]) &&
        ![request valueForHTTPHeaderField:@"X-Relay-Token"];
}

static char FixtureMarker;
static NSDictionary *LSPreferences(void);

@interface SHTagResultDefaultTrackView_iPhone : UIView
- (NSManagedObject *)tagResult;
- (UIImageView *)albumArtImageView;
@end

static UIImageView *LSResultArtworkView(UIView *view) {
    if ([view isKindOfClass:%c(SHTagResultDefaultTrackView_iPhone)] &&
        [view respondsToSelector:@selector(albumArtImageView)]) {
        return [(SHTagResultDefaultTrackView_iPhone *)view albumArtImageView];
    }
    for (UIView *child in view.subviews) {
        UIImageView *artworkView = LSResultArtworkView(child);
        if (artworkView) {
            return artworkView;
        }
    }
    return nil;
}

// Keep relay artwork separate from the stock tag database and its image URLs.
static NSString *LS720CoverPath(NSString *title, NSString *artist, BOOL createDirectory) {
    if (![title isKindOfClass:[NSString class]] || !title.length ||
        ![artist isKindOfClass:[NSString class]] || !artist.length) {
        return nil;
    }
    NSData *identity = [NSJSONSerialization dataWithJSONObject:@[title, artist] options:0 error:NULL];
    if (!identity.length) {
        return nil;
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(identity.bytes, (CC_LONG)identity.length, digest);
    NSMutableString *filename = [NSMutableString stringWithCapacity:sizeof(digest) * 2];
    for (NSUInteger i = 0; i < sizeof(digest); i++) {
        [filename appendFormat:@"%02x", digest[i]];
    }
    NSString *library = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) lastObject];
    NSString *directory = [library stringByAppendingPathComponent:@"ShazamX Covers"];
    if (createDirectory && ![[NSFileManager defaultManager] createDirectoryAtPath:directory
        withIntermediateDirectories:YES attributes:nil error:NULL]) {
        return nil;
    }
    return [directory stringByAppendingPathComponent:filename];
}

static NSCache *LS720CoverCache(void) {
    static NSCache *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 24;
        cache.totalCostLimit = 4 * 1024 * 1024;
    });
    return cache;
}

static unsigned char LSHexDigit(unsigned char digit) {
    if (digit >= '0' && digit <= '9') {
        return digit - '0';
    }
    if (digit >= 'a' && digit <= 'f') {
        return digit - 'a' + 10;
    }
    return 0xff;
}

static NSData *LSDecodeArtwork(id value) {
    if (![value isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSData *hex = [value dataUsingEncoding:NSASCIIStringEncoding];
    if (!hex.length || hex.length > 512000 || hex.length % 2) {
        return nil;
    }
    const unsigned char *source = (const unsigned char *)hex.bytes;
    NSMutableData *image = [NSMutableData dataWithLength:hex.length / 2];
    unsigned char *destination = (unsigned char *)image.mutableBytes;
    for (NSUInteger i = 0; i < image.length; ++i) {
        unsigned char high = LSHexDigit(source[i * 2]);
        unsigned char low = LSHexDigit(source[i * 2 + 1]);
        if (high > 15 || low > 15) {
            return nil;
        }
        destination[i] = (high << 4) | low;
    }
    return [UIImage imageWithData:image] ? image : nil;
}


@interface SHTagResultViewController_iPhone : UIViewController
- (UITableView *)tableView;
- (NSManagedObject *)tagResult;
- (NSArray *)filteredAddOns;
@end

@interface SHAddOn : NSObject
- (NSString *)providerName;
@end

@interface SHDefaultUserInterfaceManager_iPhone : NSObject
- (id)tabBarController;
- (UIViewController *)tagListViewController;
- (SHTaggingDataManager *)taggingDataManager;
@end

@interface NSObject (LSShazamAppDelegate)
- (SHDefaultUserInterfaceManager_iPhone *)userInterfaceManager;
@end

@interface SHTagListTableViewCell_iPhone : UITableViewCell
- (id)tagResult;
- (UILabel *)trackArtistLabel;
- (UILabel *)trackTitleLabel;
@end

static UIImage *LS720CachedCover(id result, NSString *title, NSString **resolvedArtist) {
    NSString *artist = *resolvedArtist;
    if ([result isKindOfClass:[NSManagedObject class]]) {
        NSManagedObject *record = result;
        NSDictionary *attributes = record.entity.attributesByName;
        if (attributes[@"name"]) {
            title = [record valueForKey:@"name"] ?: title;
        }
        if (!artist.length && attributes[@"cachedArtistString"]) {
            artist = [record valueForKey:@"cachedArtistString"];
        }
        if (!artist.length && attributes[@"subtitle"]) {
            artist = [record valueForKey:@"subtitle"];
        }
    }
    if (!artist.length) {
        NSString *indexBase = LS720CoverPath(title, @"title-index", NO);
        NSDictionary *entry = indexBase ? [NSDictionary dictionaryWithContentsOfFile:
            [indexBase stringByAppendingPathExtension:@"plist"]] : nil;
        artist = entry[@"artist"];
    }

    NSString *path = LS720CoverPath(title, artist, NO);
    *resolvedArtist = artist;
    if (!path) {
        return nil;
    }

    NSCache *cache = LS720CoverCache();
    UIImage *cover = [cache objectForKey:path];
    if (!cover) {
        cover = [UIImage imageWithContentsOfFile:path];
        CGImageRef pixels = cover.CGImage;
        if (pixels) {
            uint64_t cost = (uint64_t)CGImageGetWidth(pixels) * CGImageGetHeight(pixels) * 4;
            if (cost <= cache.totalCostLimit) {
                [cache setObject:cover forKey:path cost:(NSUInteger)cost];
            }
        }
    }
    return cover;
}

@interface SHTagResultCardTrackView_iPhone : SHTagResultDefaultTrackView_iPhone
@end

@interface SHAddOnTableViewCell : UITableViewCell
// Available on iOS 7 and later. The tweak also builds against the iOS 6.1 SDK.
- (UIEdgeInsets)separatorInset;
- (void)setSeparatorInset:(UIEdgeInsets)insets;
@end

static char LS720ThumbnailKey;
static char LS720DetailCoverKey;
static char LS720DeleteIconVisibilityKey;
static char LS720DeleteSeparatorInsetKey;

static void LS720ApplyDetailCover(SHTagResultDefaultTrackView_iPhone *header) {
    UIImage *cover = objc_getAssociatedObject(header, &LS720DetailCoverKey);
    if (!cover) {
        return;
    }
    UIImageView *artwork = [header albumArtImageView];
    if (artwork.image != cover) {
        artwork.image = cover;
    }
}

static void LS720ConfigureDetailCover(SHTagResultDefaultTrackView_iPhone *header) {
    NSManagedObject *result = [header tagResult];
    UIImage *cover = nil;
    if ([result isKindOfClass:[NSManagedObject class]] && result.managedObjectContext && !result.isDeleted) {
        NSString *artist = nil;
        cover = LS720CachedCover(result, nil, &artist);
    }
    objc_setAssociatedObject(header, &LS720DetailCoverKey, cover, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (cover) {
        LS720ApplyDetailCover(header);
        [header setNeedsLayout];
    }
}

%group TagArtwork720
%hook SHTagListTableViewCell_iPhone
- (void)configureWithTag:(id)tag isEditing:(BOOL)editing showFavouriteButton:(BOOL)showFavourite
              indexPath:(NSIndexPath *)indexPath {
    %orig;
    UIImageView *thumbnail = objc_getAssociatedObject(self, &LS720ThumbnailKey);
    thumbnail.image = nil;
    thumbnail.hidden = YES;
    if (editing) {
        return;
    }

    UILabel *artistLabel = [self trackArtistLabel];
    NSString *artist = artistLabel.text;
    UIImage *cover = LS720CachedCover([self tagResult], [self trackTitleLabel].text, &artist);
    if (!cover) {
        return;
    }
    if (!thumbnail) {
        thumbnail = [[[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 0, 0)] autorelease];
        thumbnail.contentMode = UIViewContentModeScaleAspectFit;
        thumbnail.userInteractionEnabled = NO;
        [self.contentView addSubview:thumbnail];
        objc_setAssociatedObject(self, &LS720ThumbnailKey, thumbnail, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    thumbnail.image = cover;
    if (!artistLabel.text.length) {
        artistLabel.text = artist;
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    %orig;
    UIImageView *thumbnail = objc_getAssociatedObject(self, &LS720ThumbnailKey);
    if (!thumbnail.image) {
        return;
    }
    UILabel *titleLabel = [self trackTitleLabel];
    if (!titleLabel.superview) {
        thumbnail.hidden = YES;
        return;
    }
    CGRect titleFrame = [titleLabel.superview convertRect:titleLabel.frame toView:self.contentView];
    CGFloat height = self.contentView.bounds.size.height;
    CGFloat side = floor(MIN(44, MIN(height - 8, titleFrame.origin.x - 16)));
    thumbnail.hidden = self.editing || side <= 0;
    if (!thumbnail.hidden) {
        thumbnail.frame = CGRectMake(8, floor((height - side) / 2), side, side);
    }
}

- (void)prepareForReuse {
    %orig;
    UIImageView *thumbnail = objc_getAssociatedObject(self, &LS720ThumbnailKey);
    thumbnail.image = nil;
    thumbnail.hidden = YES;
}
%end

%hook SHTagResultDefaultTrackView_iPhone
- (void)configureWithTag:(id)tag {
    %orig;
    LS720ConfigureDetailCover(self);
}

- (void)layoutSubviews {
    LS720ApplyDetailCover(self);
    %orig;
}
%end

// The card header implements its own configureWithTag: and creates its own image view.
%hook SHTagResultCardTrackView_iPhone
- (void)configureWithTag:(id)tag {
    %orig;
    LS720ConfigureDetailCover(self);
}
%end

%hook SHAddOnTableViewCell
- (void)configureWithAddOn:(SHAddOn *)action {
    NSNumber *previousVisibility = objc_getAssociatedObject(self, &LS720DeleteIconVisibilityKey);
    if (previousVisibility) {
        self.imageView.hidden = previousVisibility.boolValue;
    }
    NSValue *previousInset = objc_getAssociatedObject(self, &LS720DeleteSeparatorInsetKey);
    if (previousInset) {
        [self setSeparatorInset:previousInset.UIEdgeInsetsValue];
        objc_setAssociatedObject(self, &LS720DeleteSeparatorInsetKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    %orig;
    if ([[action providerName] isEqualToString:@"tag_delete"]) {
        previousVisibility = @(self.imageView.hidden);
        self.imageView.hidden = YES;
    } else {
        previousVisibility = nil;
    }
    objc_setAssociatedObject(self, &LS720DeleteIconVisibilityKey, previousVisibility, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    %orig;
    if (!objc_getAssociatedObject(self, &LS720DeleteIconVisibilityKey)) {
        return;
    }

    UILabel *label = self.textLabel;
    CGRect frame = label.frame;
    CGFloat leadingInset = 15.0;
    if (CGRectGetMinX(frame) > leadingInset) {
        frame.size.width = CGRectGetMaxX(frame) - leadingInset;
        frame.origin.x = leadingInset;
        label.frame = frame;
    }
    if ([self respondsToSelector:@selector(setSeparatorInset:)]) {
        UIEdgeInsets inset = [self separatorInset];
        if (!UIEdgeInsetsEqualToEdgeInsets(inset, UIEdgeInsetsZero)) {
            if (!objc_getAssociatedObject(self, &LS720DeleteSeparatorInsetKey)) {
                objc_setAssociatedObject(self, &LS720DeleteSeparatorInsetKey,
                    [NSValue valueWithUIEdgeInsets:inset], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            [self setSeparatorInset:UIEdgeInsetsZero];
        }
    }
}
%end
%end

@interface SHTagResultDefaultParentViewController_iPhone : UIViewController
- (id)initWithTagResult:(NSManagedObject *)result;
@end

%group ClassicResult
%hook SHTagResultMO

- (NSString *)displayTitle {
    if (objc_getAssociatedObject(self, &FixtureMarker)) {
        return [objc_getAssociatedObject(self, &FixtureMarker) objectForKey:@"title"];
    }
    return %orig;
}

- (NSString *)artistString {
    if (objc_getAssociatedObject(self, &FixtureMarker)) {
        return [objc_getAssociatedObject(self, &FixtureMarker) objectForKey:@"artist"];
    }
    return %orig;
}

%end

%end

static char LSRelayResultPresenterKey;
static char LSRelayResultSavedKey;

@interface LSResultPresenter : NSObject {
    UIWindow *_previewWindow;
    UIWindow *_previousWindow;
}
- (void)addRelayResultToMyTags:(SHTagResultViewController_iPhone *)screen;
+ (void)showTitle:(NSString *)title artist:(NSString *)artist artwork:(NSData *)artwork artworkURL:(NSURL *)artworkURL;
- (void)openTitle:(NSString *)title artist:(NSString *)artist artwork:(NSData *)artwork artworkURL:(NSURL *)artworkURL;
@end

@implementation LSResultPresenter

- (void)closePreview {
    _previewWindow.hidden = YES;
    [_previousWindow makeKeyWindow];
    [_previewWindow release];
    _previewWindow = nil;
    [_previousWindow release];
    _previousWindow = nil;
}

static BOOL LSSaveRelayMatch720(NSManagedObject *preview, SHTaggingDataManager *manager, NSError **error) {
    if (!preview || ![manager respondsToSelector:@selector(saveTagWithTrackId:eventId:tagId:)]) {
        return NO;
    }
    SHCoreDataHelper *store = [manager coreDataHelper];
    if (![store respondsToSelector:@selector(save:)]) {
        return NO;
    }

    // A relay match has a local tag ID, but no native Shazam track or event ID.
    NSManagedObject *saved = [manager saveTagWithTrackId:nil eventId:nil tagId:[[NSUUID UUID] UUIDString]];
    NSManagedObjectContext *context = saved.managedObjectContext;
    if (!context) {
        return NO;
    }
    NSManagedObject *tag = [saved valueForKey:@"audioTag"];
    LSCopyMatchFields(preview, saved);
    [saved setValue:@YES forKey:@"wasAddedToMyTags"];
    if ([store save:error]) {
        if ([manager respondsToSelector:@selector(cacheTagCountData)]) {
            [manager cacheTagCountData];
        }
        return YES;
    }
    if (tag.managedObjectContext == context) {
        [context deleteObject:tag];
    }
    if (saved.managedObjectContext == context) {
        [context deleteObject:saved];
    }
    return NO;
}

- (void)addRelayResultToMyTags:(SHTagResultViewController_iPhone *)screen {
    if (!_previewWindow || screen.view.window != _previewWindow) {
        return;
    }

    id delegate = [UIApplication sharedApplication].delegate;
    SHDefaultUserInterfaceManager_iPhone *manager = [delegate respondsToSelector:@selector(userInterfaceManager)]
        ? [delegate userInterfaceManager] : nil;
    NSManagedObject *result = [screen tagResult];
    if (!objc_getAssociatedObject(screen, &LSRelayResultSavedKey)) {
        NSError *error = nil;
        SHTaggingDataManager *tagManager = LSTagManager();
        if (!tagManager && [manager respondsToSelector:@selector(taggingDataManager)]) {
            tagManager = [manager taggingDataManager];
        }
        if (!LSSaveRelayMatch720(result, tagManager, &error)) {
            NSLog(@"[ShazamX] Native My Tags save failed: %@", error);
            screen.navigationItem.prompt = error.localizedDescription ?: @"Could not save to My Tags.";
            return;
        }
        objc_setAssociatedObject(screen, &LSRelayResultSavedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [result setValue:@YES forKey:@"wasAddedToMyTags"];
    }
    id tabs = [manager respondsToSelector:@selector(tabBarController)] ? [manager tabBarController] : nil;
    UIViewController *list = [manager respondsToSelector:@selector(tagListViewController)]
        ? [manager tagListViewController] : nil;
    if (!list || ![tabs respondsToSelector:@selector(setSelectedViewController:)]) {
        screen.navigationItem.prompt = @"Saved to My Tags.";
        return;
    }

    [self closePreview];
    [tabs setSelectedViewController:list];
    UINavigationController *navigation = [list isKindOfClass:[UINavigationController class]]
        ? (UINavigationController *)list : list.navigationController;
    [navigation popToRootViewControllerAnimated:NO];
}

+ (void)showTitle:(NSString *)title artist:(NSString *)artist artwork:(NSData *)artwork artworkURL:(NSURL *)artworkURL {
    static LSResultPresenter *presenter;
    if (!presenter) {
        presenter = [[LSResultPresenter alloc] init];
    }
    [presenter openTitle:title artist:artist artwork:artwork artworkURL:artworkURL];
}

- (void)openTitle:(NSString *)title artist:(NSString *)artist artwork:(NSData *)artwork artworkURL:(NSURL *)artworkURL {
    if (_previewWindow) {
        return;
    }
    @try {
        // The app version is fixed for this process. Keep the entity and its owning model alive.
        static NSManagedObjectModel *resultModel;
        static NSEntityDescription *resultEntity;
        if (!resultModel) {
            NSURL *modelURL = [[NSBundle mainBundle]
                URLForResource:(LSShazam720 ? @"ShazamDataModel 7.2.0-0" : @"ShazamDataModel 5.5.1-0")
                withExtension:@"mom"
                subdirectory:@"ShazamDataModel.momd"];
            if (!modelURL) {
                [NSException raise:NSInternalInconsistencyException format:@"The Shazam data model was not found."];
            }
            NSManagedObjectModel *model = [[[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL] autorelease];
            for (NSEntityDescription *entity in model.entities) {
                if ([entity.managedObjectClassName isEqualToString:@"SHTagResultMO"]) {
                    resultModel = [model retain];
                    resultEntity = entity;
                    break;
                }
            }
        }

        Class resultClass = %c(SHTagResultMO);
        Class controllerClass = LSShazam720 ? %c(SHTagResultViewController_iPhone)
            : %c(SHTagResultDefaultParentViewController_iPhone);
        if (!resultEntity) {
            [NSException raise:NSInternalInconsistencyException format:@"The Core Data model has no SHTagResultMO entity."];
        }
        if (!resultClass || !controllerClass) {
            [NSException raise:NSInternalInconsistencyException
                        format:@"Missing runtime class: %@.",
                               !resultClass ? @"SHTagResultMO" : @"SHTagResultDefaultParentViewController_iPhone"];
        }

        NSManagedObject *result = [[[resultClass alloc] initWithEntity:resultEntity
                                     insertIntoManagedObjectContext:nil] autorelease];
        objc_setAssociatedObject(result, &FixtureMarker, @{@"title": title, @"artist": artist}, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [result setValue:title forKey:@"name"];
        [result setValue:artist forKey:@"subtitle"];
        [result setValue:artist forKey:@"cachedArtistString"];
        [result setValue:@"music" forKey:@"type"];
        [result setValue:[NSDate date] forKey:@"date"];
        [result setValue:@YES forKey:@"completeResult"];
        if (!LSShazam720 && artwork.length) {
            NSDictionary *attributes = resultEntity.attributesByName;
            for (NSString *key in @[@"albumArtData", @"albumArtThumbnailData"]) {
                if ([attributes objectForKey:key]) {
                    [result setValue:artwork forKey:key];
                }
            }
        }

        SHTagResultDefaultParentViewController_iPhone *screen =
            [[[controllerClass alloc] initWithTagResult:result] autorelease];
        if (!screen) {
            [NSException raise:NSInternalInconsistencyException format:@"Shazam could not create its result screen."];
        }
        // Exercise the native screen before presenting so setup errors are visible.
        [screen view];
        if (LSShazam720) {
            screen.navigationItem.prompt = artist;
            objc_setAssociatedObject(screen, &LSRelayResultPresenterKey, self, OBJC_ASSOCIATION_ASSIGN);
        }
        screen.navigationItem.leftBarButtonItem = [[[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemDone
            target:self action:@selector(closePreview)] autorelease];
        UINavigationController *navigation =
            [[[UINavigationController alloc] initWithRootViewController:screen] autorelease];
        _previousWindow = [[UIApplication sharedApplication].keyWindow retain];
        _previewWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        _previewWindow.rootViewController = navigation;
        [_previewWindow makeKeyAndVisible];
        NSManagedObject *saved = LSShazam720 ? nil : LSSaveMatch(result);
        if (!LSShazam720 && !saved) {
            screen.navigationItem.prompt = @"Could not save to My Tags.";
        }
        UIWindow *resultWindow = _previewWindow;
        void (^showCover)(NSData *) = ^(NSData *cover) {
            if (!LSShazam720 || !cover.length) {
                return;
            }
            NSString *path = LS720CoverPath(title, artist, YES);
            if (path && [cover writeToFile:path atomically:YES]) {
                [LS720CoverCache() removeObjectForKey:path];
                NSString *indexBase = LS720CoverPath(title, @"title-index", NO);
                NSString *indexPath = [indexBase stringByAppendingPathExtension:@"plist"];
                NSDictionary *previous = [NSDictionary dictionaryWithContentsOfFile:indexPath];
                // A title-only lookup is safe only while the cached title has one artist.
                NSString *indexedArtist = !previous || [previous[@"artist"] isEqualToString:artist] ? artist : @"";
                [@{@"artist": indexedArtist} writeToFile:indexPath atomically:YES];
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2),
                           dispatch_get_main_queue(), ^{
                if (_previewWindow != resultWindow) {
                    return;
                }
                UIImage *image = [UIImage imageWithData:cover];
                if (!image) {
                    return;
                }
                SHTagResultViewController_iPhone *resultScreen = (SHTagResultViewController_iPhone *)screen;
                UITableView *table = [resultScreen tableView];
                if (!table) {
                    return;
                }
                // The stock header has incomplete geometry for a relay result.
                // Reserve the full cover height so the first action row starts below it.
                CGFloat width = table.bounds.size.width;
                UIView *header = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 164)] autorelease];
                UIImageView *coverView = [[[UIImageView alloc] initWithImage:image] autorelease];
                coverView.frame = CGRectMake((width - 144) / 2, 10, 144, 144);
                coverView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                    UIViewAutoresizingFlexibleRightMargin;
                coverView.contentMode = UIViewContentModeScaleAspectFit;
                [header addSubview:coverView];
                table.tableHeaderView = header;
                coverView.alpha = 0;
                [UIView animateWithDuration:0.2 animations:^{ coverView.alpha = 1; }];
            });
        };
        showCover(artwork);
        if (artworkURL && (!LSShazam720 || !artwork.length)) {
            NSURLRequest *request = [NSURLRequest requestWithURL:artworkURL
                cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:12];
            [NSURLConnection sendAsynchronousRequest:request queue:[NSOperationQueue mainQueue]
                completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) {
                if (error || !data.length ||
                    ![response isKindOfClass:[NSHTTPURLResponse class]] ||
                    [(NSHTTPURLResponse *)response statusCode] != 200) {
                    return;
                }
                id payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
                NSData *cover = [payload isKindOfClass:[NSDictionary class]]
                    ? LSDecodeArtwork([payload objectForKey:@"artwork"]) : nil;
                if (cover.length) {
                    NSManagedObjectContext *context = saved.managedObjectContext;
                    if (context && ![saved isDeleted]) {
                        [saved setValue:cover forKey:@"albumArtData"];
                        [saved setValue:cover forKey:@"albumArtThumbnailData"];
                        NSError *error = nil;
                        if (![context save:&error]) {
                            NSLog(@"[ShazamX] Could not save artwork: %@", error);
                        }
                    }
                    if (LSShazam720) {
                        showCover(cover);
                    } else if (_previewWindow == resultWindow) {
                        [result setValue:cover forKey:@"albumArtData"];
                        [result setValue:cover forKey:@"albumArtThumbnailData"];
                        LSResultArtworkView(screen.view).image = [UIImage imageWithData:cover];
                    }
                }
            }];
        }
    } @catch (NSException *exception) {
        if (_previewWindow) {
            [self closePreview];
        }
        if (LSShazam720) {
            NSLog(@"[ShazamX] Native 7.2.0 result screen: %@", exception.reason);
            UIAlertView *match = [[[UIAlertView alloc] initWithTitle:title message:artist
                delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] autorelease];
            [match show];
            return;
        }
        UIAlertView *error = [[[UIAlertView alloc] initWithTitle:@"Result preview unavailable"
            message:exception.reason delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] autorelease];
        [error show];
    }
}

@end

%group RelayAddToTags720
%hook SHTagResultViewController_iPhone
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    LSResultPresenter *presenter = objc_getAssociatedObject(self, &LSRelayResultPresenterKey);
    // Section 2 is the stock add-on list. Identify the action by its provider, independent of locale.
    if (presenter && table == [self tableView] && path.section == 2) {
        NSArray *actions = [self filteredAddOns];
        if (path.row < actions.count) {
            SHAddOn *action = [actions objectAtIndex:path.row];
            if ([action respondsToSelector:@selector(providerName)] &&
                [[action providerName] isEqualToString:@"tag_add"]) {
                [table deselectRowAtIndexPath:path animated:YES];
                [presenter addRelayResultToMyTags:self];
                return;
            }
        }
    }
    %orig;
}
%end
%end

#import <AVFoundation/AVFoundation.h>

#import <math.h>
#import <errno.h>
#import <CFNetwork/CFNetwork.h>

@interface SHTagButtonView_iPhone : UIView
- (UIView *)audioReactiveView;
- (void)startTaggingAnimation;
- (void)stopTaggingAnimation;
@end

@interface SHTagViewController_iPhone : UIViewController
- (SHTagButtonView_iPhone *)taggingView;
- (UIButton *)cancelTaggingButton;
- (UIButton *)settingsButton;
- (UILabel *)taggingStatusLabel;
- (BOOL)startTaggingOnAppear;
- (void)setStartTaggingOnAppear:(BOOL)enabled;
- (void)taggingButtonPressed:(id)sender;
@end

// The native visualizer requests levels through these two methods.
enum { LSClassicBandCount = 4 };

@interface LSAnimationMeter : NSObject {
    float _level;
    float _bandFilters[LSClassicBandCount - 1][2];
    float _bandWeights[LSClassicBandCount];
    BOOL _hasPCM;
}
- (void)updateFromRecorder:(AVAudioRecorder *)recorder;
- (void)updateFromPCM:(const int16_t *)samples count:(NSUInteger)count;
- (float)spectrumLevelAtIndex:(NSUInteger)index;
- (BOOL)hasPCM;
- (float)levelForBand:(id)band;
- (float)trebleLevel;
@end

@implementation LSAnimationMeter

- (void)updateFromRecorder:(AVAudioRecorder *)recorder {
    float level = 0;
    if (recorder.isRecording) {
        [recorder updateMeters];
        float power = [recorder averagePowerForChannel:0];
        level = fminf(1.0f, fmaxf(0.0f, (power + 52.0f) / 46.0f));
    }
    // One broadband level drives every classic band, so limit its visual amplitude.
    level *= 0.60f;
    _level += (level - _level) * (level > _level ? 0.65f : 0.20f);
}

- (void)updateFromPCM:(const int16_t *)samples count:(NSUInteger)count {
    // Two cascaded low-pass stages at each crossover for 16 kHz microphone PCM.
    static const float coefficients[] = {0.1005f, 0.3138f, 0.6442f};
    float powers[LSClassicBandCount] = {};
    float broadbandPower = 0;
    for (NSUInteger i = 0; i < count; i++) {
        float input = samples[i] / 32768.0f;
        broadbandPower += input * input;
        float previous = 0;
        for (NSUInteger band = 0; band < LSClassicBandCount - 1; band++) {
            float *filter = _bandFilters[band];
            filter[0] += coefficients[band] * (input - filter[0]);
            filter[1] += coefficients[band] * (filter[0] - filter[1]);
            float component = filter[1] - previous;
            powers[band] += component * component;
            previous = filter[1];
        }
        float upper = input - previous;
        powers[LSClassicBandCount - 1] += upper * upper;
    }

    float decibels = 10.0f * log10f(fmaxf(1e-12f, broadbandPower / count));
    float level = 0.60f * fminf(1.0f, fmaxf(0.0f, (decibels + 52.0f) / 46.0f));
    _level += (level - _level) * (level > _level ? 0.65f : 0.20f);

    float amplitudes[LSClassicBandCount];
    float total = 0;
    for (NSUInteger band = 0; band < LSClassicBandCount; band++) {
        amplitudes[band] = sqrtf(powers[band]);
        total += amplitudes[band];
    }
    for (NSUInteger band = 0; band < LSClassicBandCount; band++) {
        float share = total > 0 ? amplitudes[band] / total : 0;
        float weight = fminf(1.6f, 0.35f + 2.6f * share);
        float previous = _bandWeights[band];
        _bandWeights[band] = _hasPCM ? previous + (weight - previous) *
            (weight > previous ? 0.60f : 0.30f) : weight;
    }
    _hasPCM = YES;
}

- (BOOL)hasPCM {
    return _hasPCM;
}

- (float)spectrumLevelAtIndex:(NSUInteger)index {
    return _hasPCM ? _level * _bandWeights[index] : _level;
}

- (float)levelForBand:(id)band {
    return _level;
}

- (float)trebleLevel {
    return _level;
}

@end

static id ActiveAnimationView;
static LSAnimationMeter *FrameMeter;


static NSDictionary *LSPreferences(void) {
    return [NSDictionary dictionaryWithContentsOfFile:
        @"/var/mobile/Library/Preferences/org.legacyshazam.settings.plist"];
}

static BOOL LSRecognitionEnabled(void) {
    id enabled = [LSPreferences() objectForKey:@"Enabled"];
    return ![enabled isKindOfClass:[NSNumber class]] || [enabled boolValue];
}

@interface SHAudioMetering : NSObject
- (id)initWithFrameSize:(int)frameSize sampleRate:(float)sampleRate;
- (void)performFFTOnAudioData:(int16_t *)samples size:(unsigned long)size;
- (unsigned int)fftFrameSize;
- (float)sampleRate;
@end

@interface SHTaggingAnimationView_PNG : UIView
- (id)pngLayer;
- (void)startRotationAnimation;
- (CADisplayLink *)displayLink;
@end

@interface SHTaggingAnimationRingLayer_PNG : NSObject
- (SHAudioMetering *)audioMetering;
- (void)update;
- (NSArray *)layerArray;
@end

@interface SHTaggingAnimationView : UIView
- (NSArray *)rings;
@end

@interface SHTaggingAnimationRingLayer : CALayer
- (NSArray *)wedges;
@end

@interface SHTaggingAnimationWedgeLayer : CAShapeLayer
- (SHAudioMetering *)audioMetering;
- (float)currentScaleFromAudio;
- (void)setAudioMetering:(SHAudioMetering *)meter;
- (BOOL)isTagging;
- (void)setIsTagging:(BOOL)tagging;
@end

enum {
    LSStockMeterSampleRate = 44100,
    LSPCMSampleRate = 16000,
    LSPCMFrameCount = 8 * LSPCMSampleRate,
    LSFFTFrameCount = 512
};

static char LSNativeMeterKey;
static char LSWedgeMeterGainKey;
static const float LSWedgeMeterGain = 1.25f;

@interface LSRecognition : NSObject <AVAudioRecorderDelegate> {
    AVAudioRecorder *_recorder;
    NSString *_previousCategory;
    BOOL _busy;
    BOOL _waitingForRelay;
    NSUInteger _relayAttempt;
    LSRelayWebRequest *_relayWebRequest;
    UILabel *_statusLabel;
    NSString *_previousStatus;
    BOOL _statusWasHidden;
    CGFloat _statusAlpha;
    BOOL _statusWasChanged;
    BOOL _ownsStatusLabel;
    UIButton *_cancelButton;
    UIButton *_relayCancelButton;
    UIButton *_settingsButton;
    BOOL _settingsWasHidden;
    BOOL _cancelWasHidden;
    BOOL _cancelWasEnabled;
    CGFloat _cancelOriginalAlpha;
    SHTagButtonView_iPhone *_dial;
    LSAnimationMeter *_animationMeter;
    AudioQueueRef _pcmQueue;
    NSMutableData *_pcmRecording;
    NSUInteger _pcmCaptureID;
    BOOL _pcmFinishing;
    SHAudioMetering *_nativeMeter;
    SHAudioMetering *_wedgeMeter;
    NSArray *_wedgeMeterState;
    int16_t _wedgeFrame[LSFFTFrameCount];
    NSUInteger _wedgeFrameCount;
    unsigned int _wedgePhase;
    int16_t _wedgePreviousSample;
    BOOL _wedgeHasPreviousSample;
    SHTaggingAnimationRingLayer_PNG *_nativeRing;
    UIView *_meteredRingView;
    CGAffineTransform _ringRestTransform;
    NSArray *_ringBars;
    NSArray *_ringBarTransforms;
    CGFloat _recentLevels[6];
}
- (void)startWithDial:(SHTagButtonView_iPhone *)dial cancelButton:(UIButton *)button statusLabel:(UILabel *)statusLabel
       settingsButton:(UIButton *)settingsButton hostView:(UIView *)hostView;
- (BOOL)cancelListening;
- (void)submitAudio:(NSData *)audio relayURL:(NSURL *)relayURL attempt:(NSUInteger)attempt retryAvailable:(BOOL)retryAvailable;
- (void)waitForRelayWithAudio:(NSData *)audio relayURL:(NSURL *)relayURL deadline:(NSTimeInterval)deadline attempt:(NSUInteger)attempt;
- (LSAnimationMeter *)updateAnimationMeter;
- (void)receivePCMBuffer:(AudioQueueBufferRef)buffer fromQueue:(AudioQueueRef)queue;
- (void)submitFinishedRecording:(NSData *)audio;
@end

static void LSReceivePCM(void *context, AudioQueueRef queue, AudioQueueBufferRef buffer,
                         const AudioTimeStamp *startTime, UInt32 packetCount,
                         const AudioStreamPacketDescription *packets) {
    [(LSRecognition *)context receivePCMBuffer:buffer fromQueue:queue];
}

static NSData *LSWaveFromPCM(NSData *samples) {
    const uint32_t byteCount = (uint32_t)samples.length;
    // The capture format is signed 16-bit little-endian mono PCM on ARM.
    const uint32_t header[] = {
        0x46464952, 36 + byteCount, 0x45564157, 0x20746d66, 16,
        0x00010001, LSPCMSampleRate, 2 * LSPCMSampleRate, 0x00100002,
        0x61746164, byteCount
    };
    NSMutableData *wave = [NSMutableData dataWithCapacity:sizeof(header) + byteCount];
    [wave appendBytes:header length:sizeof(header)];
    [wave appendData:samples];
    return wave;
}

static NSData *LSShortRelayWAV(NSData *recording) {
    const unsigned char *bytes = (const unsigned char *)recording.bytes;
    NSUInteger length = recording.length;
    if (length < 12 || memcmp(bytes, "RIFF", 4) || memcmp(bytes + 8, "WAVE", 4)) {
        return nil;
    }
    for (NSUInteger offset = 12; offset + 8 <= length;) {
        uint32_t encodedSize;
        memcpy(&encodedSize, bytes + offset + 4, sizeof(encodedSize));
        NSUInteger chunkSize = CFSwapInt32LittleToHost(encodedSize);
        NSUInteger payload = offset + 8;
        if (chunkSize > length - payload) {
            return nil;
        }
        if (!memcmp(bytes + offset, "data", 4)) {
            // Keep the uploaded excerpt within the size proven on the device.
            const NSUInteger excerptSize = 120000;
            if (chunkSize < excerptSize || payload + excerptSize >= 128 * 1024) {
                return nil;
            }
            NSMutableData *excerpt = [NSMutableData dataWithBytes:bytes length:payload];
            NSUInteger start = chunkSize >= excerptSize + 64000 ? 64000 : 0;
            [excerpt appendBytes:bytes + payload + start
                         length:excerptSize];
            uint32_t riffSize = CFSwapInt32HostToLittle((uint32_t)excerpt.length - 8);
            uint32_t dataSize = CFSwapInt32HostToLittle((uint32_t)excerptSize);
            [excerpt replaceBytesInRange:NSMakeRange(4, 4) withBytes:&riffSize];
            [excerpt replaceBytesInRange:NSMakeRange(offset + 4, 4) withBytes:&dataSize];
            return excerpt;
        }
        offset = payload + chunkSize + (chunkSize & 1);
    }
    return nil;
}

@implementation LSRecognition

- (void)sendRecognitionRequest:(NSURLRequest *)request completion:(LSRelayCompletion)completion {
    if (!LSRelayUsesWebKit(request)) {
        [NSURLConnection sendAsynchronousRequest:request queue:[NSOperationQueue mainQueue] completionHandler:completion];
        return;
    }
    LSRelayWebRequest *transfer = [[[LSRelayWebRequest alloc] initWithRequest:request
        completion:^(NSURLResponse *response, NSData *data, NSError *error) {
            [_relayWebRequest release];
            _relayWebRequest = nil;
            completion(response, data, error);
        }] autorelease];
    _relayWebRequest = [transfer retain];
    [transfer start];
}

- (void)showMessage:(NSString *)message {
    UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:@"ShazamX"
        message:message delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] autorelease];
    [alert show];
}

- (LSAnimationMeter *)updateAnimationMeter {
    if (!_pcmQueue && ![_animationMeter hasPCM]) {
        [_animationMeter updateFromRecorder:_recorder];
    }
    return _animationMeter;
}

- (void)startWedgeMeterForView:(SHTaggingAnimationView *)view {
    NSMutableArray *states = [NSMutableArray array];
    for (SHTaggingAnimationRingLayer *ring in [view rings]) {
        for (SHTaggingAnimationWedgeLayer *wedge in [ring wedges]) {
            SHAudioMetering *meter = [wedge audioMetering];
            if ([meter fftFrameSize] != LSFFTFrameCount || [meter sampleRate] != LSStockMeterSampleRate) {
                return;
            }
            [states addObject:@[wedge, meter, @([wedge isTagging])]];
        }
    }
    if (!states.count) {
        return;
    }
    _wedgeMeter = [[%c(SHAudioMetering) alloc] initWithFrameSize:LSFFTFrameCount
        sampleRate:LSStockMeterSampleRate];
    if (!_wedgeMeter) {
        return;
    }
    // Apply gain to the visualizer's FFT magnitudes after conversion, without clipping PCM.
    objc_setAssociatedObject(_wedgeMeter, &LSWedgeMeterGainKey, @(LSWedgeMeterGain),
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    _wedgeMeterState = [states copy];
    _wedgeFrameCount = 0;
    _wedgePhase = 0;
    _wedgeHasPreviousSample = NO;
    for (NSArray *state in _wedgeMeterState) {
        SHTaggingAnimationWedgeLayer *wedge = [state objectAtIndex:0];
        [wedge setAudioMetering:_wedgeMeter];
        [wedge setIsTagging:YES];
    }
}

- (void)feedWedgeMeter:(const int16_t *)frame {
    // Keep the fractional position across buffers. Only the meter needs 44.1 kHz.
    for (NSUInteger i = 0; i < LSFFTFrameCount; i++) {
        int16_t next = frame[i];
        if (_wedgeHasPreviousSample) {
            while (_wedgePhase < LSStockMeterSampleRate) {
                int32_t delta = (int32_t)next - _wedgePreviousSample;
                int32_t interpolated = _wedgePreviousSample +
                    (int64_t)delta * _wedgePhase / LSStockMeterSampleRate;
                _wedgeFrame[_wedgeFrameCount++] = (int16_t)interpolated;
                if (_wedgeFrameCount == LSFFTFrameCount) {
                    [_wedgeMeter performFFTOnAudioData:_wedgeFrame size:LSFFTFrameCount];
                    _wedgeFrameCount = 0;
                }
                _wedgePhase += LSPCMSampleRate;
            }
            _wedgePhase -= LSStockMeterSampleRate;
        }
        _wedgePreviousSample = next;
        _wedgeHasPreviousSample = YES;
    }
}

- (void)displayPCMFrame:(int16_t *)frame {
    if (_wedgeMeter) {
        [self feedWedgeMeter:frame];
        return;
    }
    if (!_meteredRingView) {
        return;
    }
    if (_nativeMeter) {
        [_nativeMeter performFFTOnAudioData:frame size:LSFFTFrameCount];
    }

    float energy = 0;
    for (NSUInteger i = 0; i < LSFFTFrameCount; i++) {
        float sample = frame[i] / 32768.0f;
        energy += sample * sample;
    }
    float decibels = 10 * log10f(fmaxf(1e-12f, energy / LSFFTFrameCount));
    CGFloat level = fminf(1, fmaxf(0, (decibels + 55) / 44));
    for (NSUInteger i = 5; i > 0; i--) {
        _recentLevels[i] = _recentLevels[i - 1];
    }
    _recentLevels[0] = level;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (_nativeMeter && _ringBars.count) {
        // Run the native geometry update even if its display link is idle.
        [_nativeRing update];
        CGFloat lowest = INFINITY;
        CGFloat highest = 0;
        for (CALayer *bar in _ringBars) {
            CATransform3D transform = bar.transform;
            CGFloat radius = hypotf(transform.m11, transform.m12);
            lowest = MIN(lowest, radius);
            highest = MAX(highest, radius);
        }
        if (highest - lowest < 0.08 && level > 0.12) {
            for (NSUInteger i = 0; i < _ringBars.count; i++) {
                CALayer *bar = [_ringBars objectAtIndex:i];
                CATransform3D base = [[_ringBarTransforms objectAtIndex:i] CATransform3DValue];
                CGFloat weight = 0.35 + 0.65 * (i % 4) / 3.0;
                CGFloat scale = 1 + 1.6 * weight * _recentLevels[(2 * i) % 5];
                bar.transform = CATransform3DScale(base, scale, scale, 1);
            }
        }
    } else {
        CGFloat scale = 1 + 0.48 * sqrtf(level);
        CGAffineTransform transform = _ringRestTransform;
        transform.a *= scale;
        transform.b *= scale;
        transform.c *= scale;
        transform.d *= scale;
        _meteredRingView.transform = transform;
    }
    [CATransaction commit];
}

- (void)stopAnimation {
    if (_nativeRing) {
        objc_setAssociatedObject(_nativeRing, &LSNativeMeterKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    ActiveAnimationView = nil;
    if (_meteredRingView && !(_nativeMeter && _ringBars.count)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _meteredRingView.transform = _ringRestTransform;
        [CATransaction commit];
    }

    // Stock cleanup invalidates the metering link and collapses the listening wedges.
    [_dial stopTaggingAnimation];
    for (NSArray *state in _wedgeMeterState) {
        SHTaggingAnimationWedgeLayer *wedge = [state objectAtIndex:0];
        [wedge setAudioMetering:[state objectAtIndex:1]];
        [wedge setIsTagging:[[state objectAtIndex:2] boolValue]];
    }
    [_wedgeMeterState release];
    _wedgeMeterState = nil;
    [_wedgeMeter release];
    _wedgeMeter = nil;
    if (LSShazam720) {
        SHTaggingAnimationView_PNG *ringView = (SHTaggingAnimationView_PNG *)[_dial audioReactiveView];
        ringView.hidden = YES;
        if ([ringView respondsToSelector:@selector(startRotationAnimation)]) {
            [ringView startRotationAnimation];
        }
    }

    [_meteredRingView release];
    _meteredRingView = nil;
    [_ringBars release];
    _ringBars = nil;
    [_ringBarTransforms release];
    _ringBarTransforms = nil;
    [_nativeRing release];
    _nativeRing = nil;
    [_nativeMeter release];
    _nativeMeter = nil;
    [_dial release];
    _dial = nil;
    [_animationMeter release];
    _animationMeter = nil;
}

- (void)prepareStatusLabel:(UILabel *)label hostView:(UIView *)hostView {
    if (!LSShazam720 && hostView && (!label.superview || label.bounds.size.width <= 0 ||
        label.bounds.size.height <= 0)) {
        CGRect bounds = hostView.bounds;
        UIView *ring = [_dial audioReactiveView];
        CGFloat top = bounds.size.height * 0.20f;
        if (ring.superview) {
            CGPoint center = [ring.superview convertPoint:ring.center toView:hostView];
            top = MAX(48.0f, MIN(top, center.y - 92.0f));
        }
        label = [[[UILabel alloc] initWithFrame:CGRectMake(44, top,
            MAX(0.0f, bounds.size.width - 88), 32)] autorelease];
        label.backgroundColor = [UIColor clearColor];
        label.textColor = [UIColor whiteColor];
        label.font = [UIFont systemFontOfSize:22];
        label.textAlignment = NSTextAlignmentCenter;
        label.adjustsFontSizeToFitWidth = YES;
        label.userInteractionEnabled = NO;
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
        [hostView addSubview:label];
        _ownsStatusLabel = YES;
    }

    _statusLabel = [label retain];
    _previousStatus = [_statusLabel.text copy];
    _statusWasHidden = _statusLabel.hidden;
    _statusAlpha = _statusLabel.alpha;
    _statusWasChanged = _statusLabel != nil;
}

- (void)restoreStatusLabel {
    if (_statusWasChanged) {
        _statusLabel.text = _previousStatus;
        _statusLabel.hidden = _statusWasHidden;
        _statusLabel.alpha = _statusAlpha;
        [_previousStatus release];
        _previousStatus = nil;
        _statusWasChanged = NO;
    }
}

- (void)showRecognitionPhase:(NSString *)phase {
    _statusLabel.text = phase;
    _statusLabel.hidden = NO;
    _statusLabel.alpha = 1;
}

- (void)finish {
    _waitingForRelay = NO;
    [_relayWebRequest cancel];
    [_relayWebRequest release];
    _relayWebRequest = nil;
    [self stopAnimation];
    [self restoreStatusLabel];
    if (_ownsStatusLabel) {
        [_statusLabel removeFromSuperview];
        _ownsStatusLabel = NO;
    }
    [_statusLabel release];
    _statusLabel = nil;
    [self restoreCancelButton];
    _busy = NO;
    [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
}

- (void)cancelFromRelayButton:(UIButton *)sender {
    [self cancelListening];
}

- (void)revealCancelButton {
    if (LSShazam720) {
        if (!_relayCancelButton) {
            UIWindow *window = [UIApplication sharedApplication].keyWindow;
            if (!window) {
                return;
            }
            CGSize size = window.bounds.size;
            _relayCancelButton = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
            _relayCancelButton.frame = CGRectMake(size.width - 52, 24, 44, 44);
            if (_settingsButton.window == window) {
                CGPoint center = [_settingsButton.superview convertPoint:_settingsButton.center toView:window];
                _relayCancelButton.center = center;
            }
            _relayCancelButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                UIViewAutoresizingFlexibleBottomMargin;
            [_relayCancelButton setTitle:@"\u00d7" forState:UIControlStateNormal];
            [_relayCancelButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            _relayCancelButton.titleLabel.font = [UIFont systemFontOfSize:34];
            _relayCancelButton.accessibilityLabel = @"Cancel tagging";
            [_relayCancelButton addTarget:self action:@selector(cancelFromRelayButton:)
                forControlEvents:UIControlEventTouchUpInside];
            [window addSubview:_relayCancelButton];
        }
        _settingsButton.hidden = YES;
        _relayCancelButton.hidden = NO;
        _relayCancelButton.alpha = 1;
        _relayCancelButton.enabled = YES;
        [_relayCancelButton.superview bringSubviewToFront:_relayCancelButton];
        return;
    }
    _cancelButton.hidden = NO;
    _cancelButton.enabled = YES;
    _cancelButton.alpha = 1.0;
}

- (void)showCancelButton:(UIButton *)button {
    _cancelButton = [button retain];
    _cancelWasHidden = button.hidden;
    _cancelWasEnabled = button.enabled;
    _cancelOriginalAlpha = button.alpha;
    if (!LSShazam720) {
        [self revealCancelButton];
    }
}

- (void)restoreCancelButton {
    [_relayCancelButton removeFromSuperview];
    [_relayCancelButton release];
    _relayCancelButton = nil;
    _settingsButton.hidden = _settingsWasHidden;
    [_settingsButton release];
    _settingsButton = nil;
    _cancelButton.hidden = _cancelWasHidden;
    _cancelButton.enabled = _cancelWasEnabled;
    _cancelButton.alpha = _cancelOriginalAlpha;
    [_cancelButton release];
    _cancelButton = nil;
}

- (void)discardRecorder {
    _pcmCaptureID++;
    _pcmFinishing = NO;
    if (_pcmQueue) {
        AudioQueueRef queue = _pcmQueue;
        _pcmQueue = NULL;
        AudioQueueDispose(queue, true);
    }
    [_pcmRecording release];
    _pcmRecording = nil;

    NSURL *url = _recorder.url;
    if (url) {
        [[NSFileManager defaultManager] removeItemAtURL:url error:NULL];
    }
    _recorder.delegate = nil;
    [_recorder release];
    _recorder = nil;
    if (_previousCategory) {
        [[AVAudioSession sharedInstance] setCategory:_previousCategory error:NULL];
        [_previousCategory release];
        _previousCategory = nil;
    }
}

- (BOOL)cancelListening {
    if (_waitingForRelay) {
        [self finish];
        return YES;
    }
    if (!_recorder && !_pcmQueue) {
        return NO;
    }
    _recorder.delegate = nil;
    [_recorder stop];
    [self discardRecorder];
    [self finish];
    return YES;
}

- (void)applicationWillResignActive:(NSNotification *)notification {
    [self cancelListening];
    [self stopAnimation];
}

- (BOOL)startPCMCapture {
    AudioStreamBasicDescription format = {};
    format.mSampleRate = LSPCMSampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = sizeof(int16_t);
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = sizeof(int16_t);
    format.mChannelsPerFrame = 1;
    format.mBitsPerChannel = 16;
    OSStatus status = AudioQueueNewInput(&format, LSReceivePCM, self, CFRunLoopGetMain(),
                                         kCFRunLoopCommonModes, 0, &_pcmQueue);
    if (status != noErr) {
        return NO;
    }
    _pcmRecording = [[NSMutableData alloc] initWithCapacity:LSPCMFrameCount * sizeof(int16_t)];
    for (NSUInteger i = 0; i < 3; i++) {
        AudioQueueBufferRef buffer = NULL;
        if (AudioQueueAllocateBuffer(_pcmQueue, LSFFTFrameCount * sizeof(int16_t), &buffer) != noErr ||
            AudioQueueEnqueueBuffer(_pcmQueue, buffer, 0, NULL) != noErr) {
            return NO;
        }
    }
    if (AudioQueueStart(_pcmQueue, NULL) != noErr) {
        return NO;
    }

    NSUInteger captureID = ++_pcmCaptureID;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 11 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (captureID == _pcmCaptureID && _pcmQueue && !_pcmFinishing) {
            [self discardRecorder];
            [self submitFinishedRecording:nil];
        }
    });
    return YES;
}

- (void)receivePCMBuffer:(AudioQueueBufferRef)buffer fromQueue:(AudioQueueRef)queue {
    if (queue != _pcmQueue || _pcmFinishing) {
        return;
    }
    const NSUInteger targetBytes = LSPCMFrameCount * sizeof(int16_t);
    const NSUInteger fftBytes = LSFFTFrameCount * sizeof(int16_t);
    NSUInteger oldLength = _pcmRecording.length;
    NSUInteger count = MIN(targetBytes - oldLength, buffer->mAudioDataByteSize);
    count -= count % sizeof(int16_t);
    [_pcmRecording appendBytes:buffer->mAudioData length:count];

    if (_meteredRingView || _animationMeter) {
        for (NSUInteger start = oldLength - oldLength % fftBytes;
             start + fftBytes <= _pcmRecording.length; start += fftBytes) {
            int16_t frame[LSFFTFrameCount];
            [_pcmRecording getBytes:frame range:NSMakeRange(start, fftBytes)];
            if (_animationMeter) {
                [_animationMeter updateFromPCM:frame count:LSFFTFrameCount];
            } else {
                [self displayPCMFrame:frame];
            }
        }
    }

    BOOL complete = _pcmRecording.length == targetBytes;
    if (!complete && AudioQueueEnqueueBuffer(queue, buffer, 0, NULL) == noErr) {
        return;
    }
    _pcmFinishing = YES;
    NSUInteger captureID = _pcmCaptureID;
    // Dispose after this callback returns.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (captureID != _pcmCaptureID || queue != _pcmQueue) {
            return;
        }
        NSData *wave = complete ? LSWaveFromPCM(_pcmRecording) : nil;
        [self discardRecorder];
        [self submitFinishedRecording:wave];
    });
}

- (void)startWithDial:(SHTagButtonView_iPhone *)dial cancelButton:(UIButton *)button statusLabel:(UILabel *)statusLabel
       settingsButton:(UIButton *)settingsButton hostView:(UIView *)hostView {
    if (_busy || [UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        return;
    }
    _busy = YES;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    _previousCategory = [session.category copy];
    NSError *error = nil;
    BOOL recording = NO;
    if ([session setCategory:AVAudioSessionCategoryRecord error:&error] &&
        [session setActive:YES error:&error]) {
        recording = [self startPCMCapture];
        if (!recording && !LSShazam720) {
            if (_pcmQueue) {
                AudioQueueDispose(_pcmQueue, true);
                _pcmQueue = NULL;
            }
            [_pcmRecording release];
            _pcmRecording = nil;
            NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [[[NSProcessInfo processInfo] globallyUniqueString] stringByAppendingPathExtension:@"wav"]];
            NSURL *url = [NSURL fileURLWithPath:path];
            _recorder = [[AVAudioRecorder alloc] initWithURL:url settings:@{
                AVFormatIDKey: @(kAudioFormatLinearPCM),
                AVSampleRateKey: @16000,
                AVNumberOfChannelsKey: @1,
                AVLinearPCMBitDepthKey: @16,
                AVLinearPCMIsBigEndianKey: @NO,
                AVLinearPCMIsFloatKey: @NO
            } error:&error];
            _recorder.delegate = self;
            _recorder.meteringEnabled = YES;
            recording = [_recorder recordForDuration:8.0];
        }
    }
    if (!recording) {
        [self discardRecorder];
        [self finish];
        [self showMessage:error.localizedDescription ?: @"The microphone could not start."];
        return;
    }

    [self showCancelButton:button];
    _settingsButton = [settingsButton retain];
    _settingsWasHidden = settingsButton.hidden;
    _dial = [dial retain];
    [self prepareStatusLabel:statusLabel hostView:hostView];
    if (!LSShazam720 && _dial) {
        _animationMeter = [[LSAnimationMeter alloc] init];
    }
    ActiveAnimationView = [_dial audioReactiveView];
    if (LSShazam720 && [ActiveAnimationView isKindOfClass:[UIView class]]) {
        _meteredRingView = [ActiveAnimationView retain];
        _ringRestTransform = _meteredRingView.transform;
        memset(_recentLevels, 0, sizeof(_recentLevels));
    }

    if (LSShazam720) {
        [_dial audioReactiveView].hidden = NO;
    }
    [_dial startTaggingAnimation];
    ActiveAnimationView = [_dial audioReactiveView];
    if (LSShazam720) {
        if ([ActiveAnimationView respondsToSelector:@selector(pngLayer)]) {
            SHTaggingAnimationView_PNG *ringView = (SHTaggingAnimationView_PNG *)ActiveAnimationView;
            id ring = [ringView pngLayer];
            if ([ring isKindOfClass:%c(SHTaggingAnimationRingLayer_PNG)]) {
                _nativeRing = [ring retain];
                _nativeMeter = [[%c(SHAudioMetering) alloc] initWithFrameSize:LSFFTFrameCount
                    sampleRate:LSPCMSampleRate];

                // Reading layerArray creates the wedges, so wait until listening starts.
                NSMutableArray *bars = [NSMutableArray array];
                NSMutableArray *transforms = [NSMutableArray array];
                for (CALayer *bar in [_nativeRing layerArray]) {
                    if (![bar isKindOfClass:[CALayer class]]) {
                        continue;
                    }
                    [bars addObject:bar];
                    CATransform3D transform = bar.transform;
                    if (transform.m11 == 0 && transform.m12 == 0) {
                        // A previous native stop may have collapsed this wedge to zero.
                        transform = CATransform3DIdentity;
                    }
                    [transforms addObject:[NSValue valueWithCATransform3D:transform]];
                }
                _ringBars = [bars copy];
                _ringBarTransforms = [transforms copy];

                if (_nativeMeter && _ringBars.count) {
                    // PCM callbacks drive updates until the stock stop invalidates this link.
                    ringView.displayLink.paused = YES;
                }
                objc_setAssociatedObject(_nativeRing, &LSNativeMeterKey, _nativeMeter, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
        if ([ActiveAnimationView isMemberOfClass:%c(SHTaggingAnimationView)]) {
            [self startWedgeMeterForView:ActiveAnimationView];
        }
    }
    [self revealCancelButton];
    [self showRecognitionPhase:@"Listening..."];
    [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
}

- (void)audioRecorderDidFinishRecording:(AVAudioRecorder *)recorder successfully:(BOOL)success {
    if (recorder != _recorder) {
        return;
    }
    NSData *audio = success ? [NSData dataWithContentsOfURL:recorder.url] : nil;
    [self discardRecorder];
    [self submitFinishedRecording:audio];
}

- (void)submitFinishedRecording:(NSData *)audio {
    if (!audio.length) {
        [self finish];
        [self showMessage:@"No audio was recorded."];
        return;
    }

    _waitingForRelay = YES;
    [self stopAnimation];
    [self revealCancelButton];
    [self showRecognitionPhase:@"Sending..."];
    NSUInteger attempt = ++_relayAttempt;
    BOOL render = [[LSPreferences() objectForKey:@"RecognitionServer"] isEqual:@"render"];
    NSURL *relayURL = [NSURL URLWithString:render
        ? @"https://legacy-shazam-relay.onrender.com/recognize" : LS_RELAY_URL];
    if (LSShazam720 && (render || ![LS_RELAY_TOKEN length])) {
        audio = LSShortRelayWAV(audio);
        if (!audio) {
            [self finish];
            [self showMessage:@"Could not prepare the recording for the selected relay."];
            return;
        }
    }
    if (render || LSShazam720) {
        [self waitForRelayWithAudio:audio relayURL:relayURL
                           deadline:[NSProcessInfo processInfo].systemUptime + 78 attempt:attempt];
    } else {
        [self submitAudio:audio relayURL:relayURL attempt:attempt retryAvailable:YES];
    }
}

- (void)waitForRelayWithAudio:(NSData *)audio relayURL:(NSURL *)relayURL deadline:(NSTimeInterval)deadline attempt:(NSUInteger)attempt {
    if (!_waitingForRelay || attempt != _relayAttempt) {
        return;
    }
    NSTimeInterval remaining = deadline - [NSProcessInfo processInfo].systemUptime;
    if (remaining <= 0) {
        [self finish];
        [self showMessage:[NSString stringWithFormat:@"%@ did not become ready. Try tagging again.", relayURL.host]];
        return;
    }

    NSURL *healthURL = [[NSURL URLWithString:@"/health" relativeToURL:relayURL] absoluteURL];
    NSURLRequest *request = [NSURLRequest requestWithURL:healthURL
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:MIN(12, remaining)];
    [self sendRecognitionRequest:request completion:^(NSURLResponse *response, NSData *data, NSError *error) {
        if (!_waitingForRelay || attempt != _relayAttempt) {
            return;
        }
        if (!LSRecognitionEnabled() || [UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
            [self finish];
            return;
        }
        if ([error.domain isEqualToString:NSURLErrorDomain] &&
                (error.code == NSURLErrorNotConnectedToInternet || error.code == NSURLErrorSecureConnectionFailed ||
                 error.code == NSURLErrorServerCertificateUntrusted)) {
            [self finish];
            [self showMessage:LSShazam720 ? LSRelayDiagnostic(healthURL, @"GET /health", error) : error.localizedDescription];
            return;
        }
        id body = !error && data.length && [(NSHTTPURLResponse *)response statusCode] == 200
            ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if ([body isKindOfClass:[NSDictionary class]] && [[body objectForKey:@"ok"] isEqual:@YES]) {
            [self submitAudio:audio relayURL:relayURL attempt:attempt retryAvailable:NO];
            return;
        }
        [self showRecognitionPhase:@"Sending..."];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self waitForRelayWithAudio:audio relayURL:relayURL deadline:deadline attempt:attempt];
        });
    }];
}


static BOOL LSConnectionWasReset(NSError *error) {
    for (NSError *cause = error; cause; cause = [cause.userInfo objectForKey:NSUnderlyingErrorKey]) {
        if (([cause.domain isEqualToString:NSPOSIXErrorDomain] && cause.code == ECONNRESET) ||
            (([cause.domain isEqualToString:NSURLErrorDomain] ||
              [cause.domain isEqualToString:(NSString *)kCFErrorDomainCFNetwork]) &&
             cause.code == NSURLErrorNetworkConnectionLost)) {
            return YES;
        }
    }
    return NO;
}

- (void)submitAudio:(NSData *)audio relayURL:(NSURL *)relayURL attempt:(NSUInteger)attempt retryAvailable:(BOOL)retryAvailable {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:relayURL
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:(LSShazam720 ? 60 : 32)];
    request.HTTPMethod = @"POST";
    request.HTTPBody = audio;
    [request setValue:@"audio/wav" forHTTPHeaderField:@"Content-Type"];
    if (!LSShazam720) {
        [request setValue:@"deferred" forHTTPHeaderField:@"X-ShazamX-Artwork"];
    }
    if ([LS_RELAY_TOKEN length]) {
        [request setValue:LS_RELAY_TOKEN forHTTPHeaderField:@"X-Relay-Token"];
    }
    [self sendRecognitionRequest:request completion:^(NSURLResponse *response, NSData *data, NSError *error) {
        if (!_waitingForRelay || attempt != _relayAttempt) {
            return;
        }
        if (!LSRecognitionEnabled() || [UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
            [self finish];
            return;
        }
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (retryAvailable && (status == 503 || LSConnectionWasReset(error))) {
            [self showRecognitionPhase:@"Sending..."];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                if (!_waitingForRelay || attempt != _relayAttempt) {
                    return;
                }
                if (!LSRecognitionEnabled() || [UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
                    [self finish];
                    return;
                }
                [self submitAudio:audio relayURL:relayURL attempt:attempt retryAvailable:NO];
            });
            return;
        }
        [self finish];
        if (error) {
            [self showMessage:LSShazam720 ? LSRelayDiagnostic(relayURL, @"POST /recognize", error) :
                [NSString stringWithFormat:@"Could not contact the recognition server. %@", error.localizedDescription]];
            return;
        }
        id payload = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if (![payload isKindOfClass:[NSDictionary class]]) {
            [self showMessage:@"The recognition server returned an invalid response."];
            return;
        }
        NSString *detail = [payload objectForKey:@"detail"];
        if (status != 200) {
            [self showMessage:[detail isKindOfClass:[NSString class]] ? detail : @"Recognition failed."];
            return;
        }
        if (![[payload objectForKey:@"matched"] boolValue]) {
            [self showMessage:@"No match. Try again with the music closer to the phone."];
            return;
        }
        NSString *title = [payload objectForKey:@"title"];
        NSString *artist = [payload objectForKey:@"artist"];
        if (![title isKindOfClass:[NSString class]] || ![artist isKindOfClass:[NSString class]]) {
            [self showMessage:@"The relay returned an incomplete match."];
            return;
        }
        NSURL *artworkURL = nil;
        id ticket = [payload objectForKey:@"artworkTicket"];
        if ([ticket isKindOfClass:[NSString class]] && [ticket length] == 32 &&
            [ticket rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location == NSNotFound) {
            artworkURL = [[NSURL URLWithString:[@"/artwork/" stringByAppendingString:ticket]
                                  relativeToURL:relayURL] absoluteURL];
        }
        [LSResultPresenter showTitle:title artist:artist
                           artwork:LSDecodeArtwork([payload objectForKey:@"artwork"]) artworkURL:artworkURL];
    }];
}

@end

static LSRecognition *Recognition;

static char LSClassicSegmentMeterKey;

@interface LSClassicSegmentMeter : NSObject {
    float _gain;
    NSUInteger _bandIndex;
}
- (id)initWithGain:(float)gain bandIndex:(NSUInteger)index;
- (float)levelForBand:(id)band;
- (float)trebleLevel;
@end

@implementation LSClassicSegmentMeter
- (id)initWithGain:(float)gain bandIndex:(NSUInteger)index {
    self = [super init];
    if (self) {
        _gain = gain;
        _bandIndex = index;
    }
    return self;
}
- (float)levelForBand:(id)band {
    return fminf(1.0f, [FrameMeter spectrumLevelAtIndex:_bandIndex] * _gain);
}
- (float)trebleLevel {
    return fminf(1.0f, [FrameMeter spectrumLevelAtIndex:_bandIndex] * _gain);
}
@end

static void LSClassicCollectLayers(CALayer *layer, NSMutableArray *layers, NSUInteger depth) {
    if (layers.count > 21 || depth > 8) {
        return;
    }
    [layers addObject:layer];
    for (CALayer *child in layer.sublayers) {
        LSClassicCollectLayers(child, layers, depth + 1);
    }
}

static NSUInteger LSClassicCalibrateSegments(UIView *view) {
    // Preorder layer indices match the measured 5.5.1 Bezier layout.
    static const float gains[] = {
        0, 0, 4.2f, 0.55f, 5.0f, 5.0f, 4.4f, 0.18f, 0,
        3.3f, 3.5f, 2.8f, 3.5f, 3.3f, 3.4f, 3.0f, 3.5f, 3.5f, 3.2f, 0, 2.0f
    };
    // Spread adjacent arcs across different bands. The index order matches the traced renderer.
    static const NSUInteger bands[] = {
        0, 0, 0, 1, 1, 2, 0, 3, 0, 0, 1, 2, 3, 1, 2, 0, 3, 1, 0, 0, 2
    };
    NSMutableArray *layers = [NSMutableArray arrayWithCapacity:21];
    LSClassicCollectLayers(view.layer, layers, 0);
    if (layers.count != sizeof(gains) / sizeof(gains[0])) {
        return 0;
    }
    Class segmentClass = NSClassFromString(@"SHAudioVisualisationSegmentLayer");
    NSUInteger calibrated = 0;
    for (NSUInteger i = 0; i < layers.count; i++) {
        if (gains[i] > 0 && [[layers objectAtIndex:i] isKindOfClass:segmentClass]) {
            LSClassicSegmentMeter *meter = [[[LSClassicSegmentMeter alloc] initWithGain:gains[i] bandIndex:bands[i]] autorelease];
            objc_setAssociatedObject([layers objectAtIndex:i], &LSClassicSegmentMeterKey, meter,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            calibrated++;
        }
    }
    return calibrated;
}

static BOOL LSClassicHasCalibratedSegments;

%group ClassicUI
%hook SHTagButtonView_iPhone
- (void)startTaggingAnimation {
    %orig;
    UIView *view = [self audioReactiveView];
    LSClassicHasCalibratedSegments = LSRecognitionEnabled() &&
        [view isMemberOfClass:NSClassFromString(@"SHTaggingAnimationView_BezierPath")] &&
        LSClassicCalibrateSegments(view) > 0;
}
%end
%hook SHTaggingAnimationView_BezierPath
- (void)updateMetering {
    LSAnimationMeter *previousMeter = FrameMeter;
    FrameMeter = self == ActiveAnimationView ? [Recognition updateAnimationMeter] : nil;
    @try {
        %orig;
    } @finally {
        FrameMeter = previousMeter;
    }
}
%end

%hook SHTaggingAnimationView_PNG
- (void)updateMetering {
    LSAnimationMeter *previousMeter = FrameMeter;
    FrameMeter = self == ActiveAnimationView ? [Recognition updateAnimationMeter] : nil;
    @try {
        %orig;
    } @finally {
        FrameMeter = previousMeter;
    }
}
%end

%hook SHAudioVisualisationSegmentLayer
- (id)audioMetering {
    if (!FrameMeter) {
        return %orig;
    }
    id meter = LSClassicHasCalibratedSegments
        ? objc_getAssociatedObject(self, &LSClassicSegmentMeterKey) : nil;
    return meter ?: FrameMeter;
}
%end

%hook SHAudioVisualisationPNGLayer
- (id)audioMetering {
    return FrameMeter ?: %orig;
}
%end


@interface SHUnsubmittedTagView : UIView
@end

%hook SHUnsubmittedTagView
- (void)didMoveToSuperview {
    %orig;
    if (LSRecognitionEnabled()) {
        self.hidden = YES;
    }
}

- (void)setHidden:(BOOL)hidden {
    %orig(hidden || LSRecognitionEnabled());
}

- (BOOL)shouldAppear {
    return LSRecognitionEnabled() ? NO : %orig;
}
%end

@interface SHBeaconManager : NSObject
+ (SHBeaconManager *)sharedBeaconManager;
- (NSMutableArray *)reliableBeacons;
- (BOOL)persistReliableBeacons:(NSArray *)beacons;
- (void)updateReliableBeaconsCopy;
- (BOOL)isBeaconing;
@end

@interface ShazamAppDelegate : NSObject
- (SHTaggingDataManager *)taggingDataManager;
- (SHBeaconManager *)sharedBeaconManager;
@end

@interface SHSettingsViewController : UITableViewController
@end

@interface LSPendingTagCleaner : NSObject <UIAlertViewDelegate>
- (void)confirmClear;
@end

// The dial counts SHUnsubmittedTagBeacon entries independently of the tag store.
static NSString *LSClearPendingQueue(SHBeaconManager *manager, NSUInteger *removed) {
    Class pendingClass = %c(SHUnsubmittedTagBeacon);
    if (!pendingClass || ![manager respondsToSelector:@selector(reliableBeacons)] ||
        ![manager respondsToSelector:@selector(persistReliableBeacons:)] ||
        ![manager respondsToSelector:@selector(updateReliableBeaconsCopy)] ||
        ![manager respondsToSelector:@selector(isBeaconing)]) {
        return @"Could not verify Shazam's pending queue.";
    }
    NSMutableArray *queue = [manager reliableBeacons];
    if (![queue isKindOfClass:[NSMutableArray class]]) {
        return @"Could not read Shazam's pending queue.";
    }
    NSMutableArray *remaining = [NSMutableArray arrayWithCapacity:queue.count];
    for (id item in queue) {
        if (![item isKindOfClass:pendingClass]) {
            [remaining addObject:item];
        }
    }
    NSUInteger count = queue.count - remaining.count;
    if (!count) {
        return nil;
    }
    if ([manager isBeaconing]) {
        return @"Shazam is processing its queue. Turn off Wi-Fi and cellular data, then try again.";
    }
    if (![manager persistReliableBeacons:remaining]) {
        return @"Could not save the cleared pending queue.";
    }
    [queue setArray:remaining];
    [manager updateReliableBeaconsCopy];
    *removed = count;
    return nil;
}

@implementation LSPendingTagCleaner
- (void)confirmClear {
    UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:@"Clear Pending Tags?"
        message:@"This removes old unmatched tags. Saved matches will be kept."
        delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Clear", nil] autorelease];
    [alert show];
}

- (void)alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)index {
    if (index == alert.cancelButtonIndex) {
        return;
    }
    NSString *message = @"Could not verify the pending-tag queue.";
    @try {
        id delegate = [UIApplication sharedApplication].delegate;
        SHTaggingDataManager *manager = [delegate respondsToSelector:@selector(taggingDataManager)]
            ? [delegate taggingDataManager] : nil;
        if (LSShazam720) {
            Class beaconClass = %c(SHBeaconManager);
            SHBeaconManager *beaconManager = [delegate respondsToSelector:@selector(sharedBeaconManager)]
                ? [delegate sharedBeaconManager] : nil;
            if (!beaconManager && [beaconClass respondsToSelector:@selector(sharedBeaconManager)]) {
                beaconManager = [beaconClass sharedBeaconManager];
            }
            NSUInteger queued = 0;
            NSString *queueError = LSClearPendingQueue(beaconManager, &queued);
            message = queueError ?: (queued ? @"Pending tags cleared. Reopen Shazam if the dial still shows the old count."
                                           : @"There are no pending tags to clear.");
        } else if ([manager respondsToSelector:@selector(unsubmittedTags)] &&
            [manager respondsToSelector:@selector(deleteTag:)]) {
            NSArray *tags = [[[manager unsubmittedTags] copy] autorelease];
            Class audioTagClass = %c(SHAudioTagMO);
            BOOL valid = audioTagClass && [tags isKindOfClass:[NSArray class]];
            for (id tag in tags) {
                if (![tag isKindOfClass:audioTagClass] ||
                    ![tag isKindOfClass:[NSManagedObject class]] ||
                    ![[[tag entity] relationshipsByName] objectForKey:@"tagResult"] ||
                    [tag valueForKey:@"tagResult"] != nil) {
                    valid = NO;
                    break;
                }
            }
            if (valid) {
                SHBeaconManager *beaconManager = [delegate respondsToSelector:@selector(sharedBeaconManager)]
                    ? [delegate sharedBeaconManager] : nil;
                NSUInteger queued = 0;
                NSString *queueError = LSClearPendingQueue(beaconManager, &queued);
                if (queueError) {
                    [NSException raise:NSInternalInconsistencyException format:@"%@", queueError];
                }
                for (NSManagedObject *tag in tags) {
                    if (tag.managedObjectContext && ![tag isDeleted] && ![tag valueForKey:@"tagResult"]) {
                        [manager deleteTag:tag];
                    }
                }
                if ([manager respondsToSelector:@selector(cacheTagCountData)]) {
                    [manager cacheTagCountData];
                }
                NSArray *remaining = [manager unsubmittedTags];
                if ([remaining isKindOfClass:[NSArray class]] && remaining.count == 0) {
                    message = (queued || tags.count) ? @"Pending tags cleared." : @"There are no pending tags to clear.";
                } else {
                    message = @"Some pending tags may remain.";
                }
            }
        }
    } @catch (NSException *exception) {
        NSLog(@"[ShazamX] Pending tag cleanup: %@", exception.reason);
        message = exception.reason ?: message;
    }
    UIAlertView *result = [[[UIAlertView alloc] initWithTitle:@"ShazamX" message:message
        delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] autorelease];
    [result show];
}
@end

%end

%group PendingSettings
%hook SHSettingsViewController
- (void)viewDidLoad {
    %orig;
    static LSPendingTagCleaner *cleaner;
    if (!cleaner) {
        cleaner = [[LSPendingTagCleaner alloc] init];
    }
    if (![self respondsToSelector:@selector(tableView)]) {
        return;
    }
    UITableView *table = self.tableView;
    UIView *previous = table.tableFooterView;
    CGFloat previousHeight = previous.frame.size.height;
    UIView *footer = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, table.bounds.size.width, previousHeight + 64)] autorelease];
    if (previous) {
        [footer addSubview:previous];
    }
    UIButton *button = [UIButton buttonWithType:UIButtonTypeRoundedRect];
    button.frame = CGRectMake(20, previousHeight + 10, footer.bounds.size.width - 40, 44);
    button.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [button setTitle:@"Clear Pending Tags" forState:UIControlStateNormal];
    [button addTarget:cleaner action:@selector(confirmClear) forControlEvents:UIControlEventTouchUpInside];
    [footer addSubview:button];
    table.tableFooterView = footer;
}
%end
%end

@interface LSClassicTagCoverLookup : NSObject {
    UIImage *_cover;
}
- (id)initWithCover:(UIImage *)cover;
- (id)objectForKey:(id)key;
@end

@implementation LSClassicTagCoverLookup
- (id)initWithCover:(UIImage *)cover {
    self = [super init];
    if (self) {
        _cover = [cover retain];
    }
    return self;
}

- (id)objectForKey:(id)key {
    return _cover;
}

- (void)dealloc {
    [_cover release];
    [super dealloc];
}
@end

@interface SHTagListViewController : UIViewController
- (NSFetchedResultsController *)fetchedResultsControllerForTableView:(UITableView *)table;
- (id)imageCache;
@end

@interface SHTagListTableViewCell : UITableViewCell
- (UILabel *)dateLabel;
@end

static char LSClassicTagCoverLookupKey;
static char LSClassicThumbnailModeKey;
static const CGFloat LSClassicThumbnailSide = 64.0;

static UIImage *LSClassicThumbnail(NSData *data) {
    if (!data.length) {
        return nil;
    }

    static NSCache *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 16;
        cache.totalCostLimit = 1024 * 1024;
    });
    UIImage *thumbnail = [cache objectForKey:data];
    if (thumbnail) {
        return thumbnail;
    }

    CGFloat scale = [UIScreen mainScreen].scale;
    NSDictionary *sourceOptions = @{(NSString *)kCGImageSourceShouldCache: @NO};
    CGImageSourceRef source = CGImageSourceCreateWithData((CFDataRef)data, (CFDictionaryRef)sourceOptions);
    if (source) {
        NSDictionary *options = @{
            (NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
            (NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
            (NSString *)kCGImageSourceThumbnailMaxPixelSize: @(LSClassicThumbnailSide * scale)
        };
        CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (CFDictionaryRef)options);
        if (image) {
            thumbnail = [UIImage imageWithCGImage:image scale:scale orientation:UIImageOrientationUp];
            NSUInteger cost = data.length + CGImageGetBytesPerRow(image) * CGImageGetHeight(image);
            if (cost <= cache.totalCostLimit) {
                [cache setObject:thumbnail forKey:data cost:cost];
            }
            CGImageRelease(image);
        }
        CFRelease(source);
    }
    return thumbnail ?: [UIImage imageWithData:data];
}

static void LSClassicSetThumbnailLayout(UITableViewCell *cell, BOOL enabled) {
    NSNumber *originalMode = objc_getAssociatedObject(cell, &LSClassicThumbnailModeKey);
    if (enabled && !originalMode) {
        objc_setAssociatedObject(cell, &LSClassicThumbnailModeKey, @(cell.imageView.contentMode),
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        cell.imageView.contentMode = UIViewContentModeScaleAspectFit;
        [cell setNeedsLayout];
    } else if (!enabled && originalMode) {
        cell.imageView.contentMode = (UIViewContentMode)originalMode.integerValue;
        objc_setAssociatedObject(cell, &LSClassicThumbnailModeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [cell setNeedsLayout];
    }
}

%group ClassicHistory
%hook SHTagListTableViewCell
- (void)layoutSubviews {
    %orig;
    if (!objc_getAssociatedObject(self, &LSClassicThumbnailModeKey)) {
        return;
    }
    UIImageView *image = self.imageView;
    UIView *container = image.superview;
    if (!container) {
        return;
    }
    CGFloat height = CGRectGetHeight(self.contentView.bounds);
    CGFloat side = MAX(0, MIN(LSClassicThumbnailSide, height - 4.0));
    CGRect slot = CGRectMake(0, floor((height - side) / 2.0), side, side);
    image.frame = [container convertRect:slot fromView:self.contentView];
    UILabel *labels[] = {self.textLabel, self.detailTextLabel, [self dateLabel]};
    for (NSUInteger index = 0; index < sizeof(labels) / sizeof(labels[0]); index++) {
        UILabel *label = labels[index];
        if (!label.superview) {
            continue;
        }
        CGRect frame = label.frame;
        CGFloat left = [label.superview convertPoint:CGPointMake(side + 8.0, 0) fromView:self.contentView].x;
        frame.size.width = MAX(0, CGRectGetMaxX(frame) - left);
        frame.origin.x = left;
        label.frame = frame;
    }
}
%end

%hook SHTagListViewController
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    NSManagedObject *result = [[self fetchedResultsControllerForTableView:table] objectAtIndexPath:path];
    BOOL localTag = ![[result valueForKey:@"trackId"] longLongValue] &&
        ![[result valueForKey:@"albumArtURLString"] length] &&
        [[result valueForKey:@"completeResult"] boolValue] &&
        [[[result valueForKey:@"audioTag"] valueForKey:@"submitted"] boolValue];
    if (!localTag) {
        UITableViewCell *cell = %orig;
        LSClassicSetThumbnailLayout(cell, NO);
        return cell;
    }

    UIImage *cover = LSClassicThumbnail([result valueForKey:@"albumArtThumbnailData"]);
    if (!cover) {
        cover = LSClassicThumbnail([result valueForKey:@"albumArtData"]);
    }
    cover = cover ?: [UIImage imageNamed:@"cover_noproduct"];
    if (!cover) {
        UITableViewCell *cell = %orig;
        LSClassicSetThumbnailLayout(cell, NO);
        return cell;
    }

    // The stock row would look up all local tags under the same missing track ID.
    // Give it this row's image synchronously so it also skips the async thumbnail load.
    id previousLookup = [objc_getAssociatedObject(self, &LSClassicTagCoverLookupKey) retain];
    LSClassicTagCoverLookup *lookup = [[[LSClassicTagCoverLookup alloc] initWithCover:cover] autorelease];
    objc_setAssociatedObject(self, &LSClassicTagCoverLookupKey, lookup, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try {
        UITableViewCell *cell = %orig;
        LSClassicSetThumbnailLayout(cell, YES);
        return cell;
    } @finally {
        objc_setAssociatedObject(self, &LSClassicTagCoverLookupKey, previousLookup, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [previousLookup release];
    }
}

- (id)imageCache {
    return objc_getAssociatedObject(self, &LSClassicTagCoverLookupKey) ?: %orig;
}
%end
@interface LSManageTagsController : UITableViewController <UIAlertViewDelegate> {
    NSArray *_tags;
}
@end

@implementation LSManageTagsController
- (void)dealloc {
    [_tags release];
    [super dealloc];
}

- (void)showMessage:(NSString *)message {
    UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:@"My Tags" message:message
        delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] autorelease];
    [alert show];
}

- (void)loadTags {
    NSManagedObjectContext *context = LSHistoryContext();
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"SHTagResultMO"];
    request.predicate = [NSPredicate predicateWithFormat:@"isInUserTagList == YES"];
    request.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"date" ascending:NO]];
    NSArray *tags = [context executeFetchRequest:request error:NULL];
    [_tags release];
    _tags = [tags copy];
    [self.tableView reloadData];
    self.navigationItem.rightBarButtonItem.enabled = _tags.count > 0;
    if (!tags) {
        [self showMessage:@"Could not load saved tags."];
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Manage Tags";
    self.navigationItem.leftBarButtonItem = [[[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)] autorelease];
    self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc]
        initWithTitle:@"Delete All" style:UIBarButtonItemStylePlain target:self action:@selector(confirmDeleteAll)] autorelease];
    [self loadTags];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)confirmDeleteAll {
    UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:@"Delete All Saved Tags?"
        message:@"This permanently removes the saved songs in My Tags."
        delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Delete All", nil] autorelease];
    [alert show];
}

- (void)alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)index {
    if (index != alert.cancelButtonIndex) {
        [self deleteTags:_tags];
    }
}

- (void)deleteTags:(NSArray *)tags {
    NSManagedObjectContext *source = LSHistoryContext();
    NSPersistentStoreCoordinator *store = source.persistentStoreCoordinator;
    if (!store) {
        [self showMessage:@"Could not open saved tags."];
        return;
    }
    // Isolate deletion so an unsuccessful save cannot leave the app's live context modified.
    NSManagedObjectContext *transaction = [[[NSManagedObjectContext alloc] init] autorelease];
    transaction.persistentStoreCoordinator = store;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    id observer = [center addObserverForName:NSManagedObjectContextDidSaveNotification
        object:transaction queue:nil usingBlock:^(NSNotification *note) {
        [source mergeChangesFromContextDidSaveNotification:note];
    }];
    for (NSManagedObject *tag in tags) {
        NSManagedObject *result = [transaction existingObjectWithID:tag.objectID error:NULL];
        if (![[result valueForKey:@"isInUserTagList"] boolValue]) {
            continue;
        }
        NSManagedObject *audio = [result valueForKey:@"audioTag"];
        if (audio && [audio valueForKey:@"tagResult"] == result) {
            [transaction deleteObject:audio];
        }
        if (![result isDeleted]) {
            [transaction deleteObject:result];
        }
    }
    BOOL saved = [transaction save:NULL];
    [center removeObserver:observer];
    if (!saved) {
        [self showMessage:@"Could not delete the selected saved tags."];
    } else {
        LSRefreshTagCount();
    }
    [self loadTags];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _tags.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SavedTag"];
    if (!cell) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"SavedTag"] autorelease];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    NSManagedObject *tag = [_tags objectAtIndex:path.row];
    cell.textLabel.text = [tag valueForKey:@"name"];
    cell.detailTextLabel.text = [tag valueForKey:@"cachedArtistString"] ?: [tag valueForKey:@"subtitle"];
    return cell;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style
forRowAtIndexPath:(NSIndexPath *)path {
    if (style == UITableViewCellEditingStyleDelete) {
        [self deleteTags:@[[_tags objectAtIndex:path.row]]];
    }
}
@end

@interface SHTagListViewController_iPhone : UIViewController
@end

%hook SHTagListViewController_iPhone
- (void)viewDidLoad {
    %orig;
    UIBarButtonItem *manage = [[[UIBarButtonItem alloc] initWithTitle:@"Manage"
        style:UIBarButtonItemStylePlain target:self action:@selector(lsManageTags)] autorelease];
    NSArray *buttons = self.navigationItem.rightBarButtonItems ?: @[];
    self.navigationItem.rightBarButtonItems = [buttons arrayByAddingObject:manage];
}

%new
- (void)lsManageTags {
    LSManageTagsController *controller = [[[LSManageTagsController alloc] initWithStyle:UITableViewStylePlain] autorelease];
    UINavigationController *navigation = [[[UINavigationController alloc] initWithRootViewController:controller] autorelease];
    [self presentViewController:navigation animated:YES completion:nil];
}
%end

%end

%group NativeSpectrum720
%hook SHAudioMetering
- (float)meanMagnitudeFromBin:(unsigned int)bin count:(unsigned int)count {
    float magnitude = %orig;
    NSNumber *gain = objc_getAssociatedObject(self, &LSWedgeMeterGainKey);
    return gain ? magnitude * [gain floatValue] : magnitude;
}
%end

%hook SHTaggingAnimationRingLayer_PNG
- (id)audioMetering {
    return objc_getAssociatedObject(self, &LSNativeMeterKey) ?: %orig;
}
%end
%end

%group TabTagInput
%hook SHTagViewController_iPhone
- (void)viewDidAppear:(BOOL)animated {
    BOOL start = LSRecognitionEnabled() &&
        [self respondsToSelector:@selector(startTaggingOnAppear)] &&
        [self respondsToSelector:@selector(setStartTaggingOnAppear:)] &&
        [self startTaggingOnAppear];
    if (start) {
        [self setStartTaggingOnAppear:NO];
    }
    %orig;
    if (start) {
        [self taggingButtonPressed:nil];
    }
}
%end
%end

%group TabTagAction
%hook SHTagViewController_iPhone
- (void)tagNowAction:(id)sender {
    if (LSRecognitionEnabled()) {
        [self taggingButtonPressed:sender];
    } else {
        %orig;
    }
}
%end
%end

%group ClassicStartTagging
%hook SHTagViewController_iPhone
- (void)startTagging {
    if (LSRecognitionEnabled()) {
        [self taggingButtonPressed:nil];
    } else {
        %orig;
    }
}
%end
%end

%group TagInput
%hook SHTagViewController_iPhone
- (void)cancelTagging:(id)sender {
    if (![Recognition cancelListening]) {
        %orig;
    }
}

- (void)taggingButtonPressed:(id)sender {
    if (!LSRecognitionEnabled()) {
        %orig;
        return;
    }
    SHTagButtonView_iPhone *dial = [self taggingView];
    if (LSShazam720 && (![dial respondsToSelector:@selector(startTaggingAnimation)] ||
        ![dial respondsToSelector:@selector(stopTaggingAnimation)] ||
        ![dial respondsToSelector:@selector(audioReactiveView)])) {
        dial = nil;
    }
    UIButton *settingsButton = LSShazam720 && [self respondsToSelector:@selector(settingsButton)]
        ? [self settingsButton] : nil;
    UILabel *statusLabel = [self respondsToSelector:@selector(taggingStatusLabel)]
        ? [self taggingStatusLabel] : nil;
    [Recognition startWithDial:dial cancelButton:[self cancelTaggingButton]
        statusLabel:statusLabel settingsButton:settingsButton hostView:self.view];
}
%end

%end

%ctor {
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *build = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
    BOOL classic = [build isEqualToString:@"572"];
    LSShazam720 = [build isEqualToString:@"741"] &&
        [[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] isEqualToString:@"7.2.0"] &&
        NSClassFromString(@"NSURLSession") != Nil;
    if (!classic && !LSShazam720) {
        return;
    }
    Recognition = [[LSRecognition alloc] init];
    [[NSNotificationCenter defaultCenter] addObserver:Recognition
        selector:@selector(applicationWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
    if (classic) {
        %init(ClassicResult);
        %init(ClassicUI);
        %init(ClassicHistory);
    }
    %init(TagInput);
    %init(PendingSettings);
    Class controller = NSClassFromString(@"SHTagViewController_iPhone");
    %init(TabTagInput);
    if (class_getInstanceMethod(controller, @selector(tagNowAction:))) {
        %init(TabTagAction);
    }
    if (classic && class_getInstanceMethod(controller, @selector(startTagging))) {
        %init(ClassicStartTagging);
    }
    if (LSShazam720) {
        %init(NativeSpectrum720);
        %init(TagArtwork720);
        %init(RelayAddToTags720);
    }
}



