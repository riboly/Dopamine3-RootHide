//
//  DOLogCrashViewController.m
//  Dopamine
//
//  Created by tomt000 on 14/02/2024.
//

#import "DOLogCrashViewController.h"
#import "DOPSListController.h"
#import "DOPSListItemsController.h"
#import "DOActionMenuButton.h"
#import "DOGlobalAppearance.h"
#import "DOUIManager.h"

@interface DOLogCrashViewController ()

@property (nonatomic, retain) NSString *title;
@property (nonatomic, assign) BOOL exitOnDisappear;
@property (nonatomic, retain) NSObject<DOLogViewProtocol> *previousLogView;
@property (nonatomic, retain) NSMutableArray<NSString *> *pendingLogs;

@end

@implementation DOLogCrashViewController

- (id)initWithTitle:(NSString*)title
{
    return [self initWithTitle:title exitOnDisappear:YES];
}

- (id)initWithTitle:(NSString *)title exitOnDisappear:(BOOL)exitOnDisappear
{
    if (self = [super init]) {
        self.title = title;
        self.exitOnDisappear = exitOnDisappear;
        self.pendingLogs = [NSMutableArray array];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [DOPSListController setupViewControllerStyle:self];

    NSString *headerTitle = self.exitOnDisappear ? DOLocalizedString(@"Log_Error") : (self.title ?: DOLocalizedString(@"Log_Error"));
    UIView *header = [DOPSListItemsController makeHeader:headerTitle withTarget:self];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:header];

    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:5],
        [header.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [header.heightAnchor constraintEqualToConstant:70]
    ]];
    
    __block DOActionMenuButton *shareButton;
    UIAction *shareAction = [UIAction actionWithTitle:DOLocalizedString(@"Button_Share") image:[UIImage systemImageNamed:@"square.and.arrow.up" withConfiguration:[DOGlobalAppearance smallIconImageConfiguration]] identifier:@"share" handler:^(__kindof UIAction * _Nonnull action) {
        [[DOUIManager sharedInstance] shareLogRecordFromView:shareButton];
    }];
    shareButton = [DOActionMenuButton buttonWithAction:shareAction chevron:NO];
    
    shareButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:shareButton];

    [NSLayoutConstraint activateConstraints:@[
        [shareButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [shareButton.heightAnchor constraintEqualToConstant:30],
        [shareButton.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-30]
    ]];
    
    if (@available(iOS 16.0, *)) {
        _logView = [UITextView textViewUsingTextLayoutManager:false];
    }
    else {
        _logView = [[UITextView alloc] init];
    }
    _logView.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:_logView];

    [NSLayoutConstraint activateConstraints:@[
        [_logView.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:-12],
        [_logView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [_logView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [_logView.bottomAnchor constraintEqualToAnchor:shareButton.topAnchor constant:-10]
    ]];

    if (self.exitOnDisappear) {
        NSArray *reverseLog = [[[DOUIManager sharedInstance] logRecord] reverseObjectEnumerator].allObjects;
        _logView.text = [reverseLog componentsJoinedByString:@"\n"];
    } else {
        _logView.text = @"";
    }
    _logView.editable = NO;
    _logView.font = [UIFont systemFontOfSize:14];
    _logView.textColor = [UIColor whiteColor];
    _logView.backgroundColor = [UIColor clearColor];

    self.previousLogView = [DOUIManager sharedInstance].logView;
    [DOUIManager sharedInstance].logView = (id<DOLogViewProtocol>)self;
    for (NSString *pendingLog in self.pendingLogs) {
        [self showLog:pendingLog];
    }
    [self.pendingLogs removeAllObjects];
}

- (void)showLog:(NSString *)log
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self showLog:log]; });
        return;
    }
    if (!_logView) {
        if (log) [self.pendingLogs addObject:log];
        return;
    }
    NSString *existingText = _logView.text ?: @"";
    _logView.text = [existingText stringByAppendingFormat:@"%@\n", log ?: @""];
    [_logView scrollRangeToVisible:NSMakeRange(_logView.text.length, 0)];
}

- (void)didComplete
{
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    if ([DOUIManager sharedInstance].logView == (id<DOLogViewProtocol>)self) {
        [DOUIManager sharedInstance].logView = self.previousLogView;
    }
    if (self.exitOnDisappear) {
        [[UIApplication sharedApplication] performSelector:@selector(suspend)];
        [NSThread sleepForTimeInterval:0.3];
        exit(0);
    }
}

- (void)dismiss
{
    [self.navigationController popViewControllerAnimated:YES];
}


@end
