// The Steam sign-in's screens (PocketSignInViewController.h): each step is a PocketSignInStep,
// an inset grouped list of up to four sections: what to know (a problem first, in red), the
// fields, a waiting row, and the step's action, with a small line for support under the last.
#import "PocketSignInViewController.h"

static const NSUInteger CodeLength = 5;   // a Steam Guard code: five letters and digits

typedef NS_ENUM(NSInteger, StepSection) { SectionInfo, SectionFields, SectionWaiting, SectionAction, SectionCount };

@interface PocketSignInStep : UITableViewController
@property(nonatomic, copy, nullable) NSString *message, *problem, *fieldsNote, *waiting, *actionTitle, *detail;
@property(nonatomic, copy) NSArray<UITextField *> *fields;
@property(nonatomic, copy, nullable) dispatch_block_t action, back;
@property(nonatomic, nullable) UIBarButtonItem *primary;   // Sign In, Continue: enabled once the fields are filled in
@property(nonatomic) BOOL busy;
@end

@implementation PocketSignInStep
- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _fields = @[];
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"row"];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.navigationItem.rightBarButtonItem = self.primary;
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    UITextField *first = self.fields.firstObject;
    for (UITextField *field in self.fields) if (!field.text.length) { first = field; break; }
    [first becomeFirstResponder];
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, self.problem ?: self.message);
}
// A screen with a camera at one side only (the iPhone Duo's outer screen held upright, its
// camera at a corner) gives that side a safe-area inset all the way down, which left a band of
// the list empty: the list goes edge to edge then, the navigation bar still clear of it. With
// insets on both sides (an iPhone's notch in landscape), the list keeps to the safe area.
- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    UIEdgeInsets safe = self.view.window.safeAreaInsets;
    BOOL oneSide = (safe.left > 0) != (safe.right > 0);
    self.tableView.insetsLayoutMarginsFromSafeArea = !oneSide;
    self.tableView.insetsContentViewsToSafeArea = !oneSide;
}
// Back (the button or the swipe): the step before is the account again.
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isMovingFromParentViewController && self.back) self.back();
}

- (BOOL)has:(StepSection)section {
    switch (section) {
        case SectionInfo: return self.message.length || self.problem.length;
        case SectionFields: return self.fields.count > 0;
        case SectionWaiting: return self.waiting.length > 0;
        case SectionAction: return self.actionTitle.length > 0;
        default: return NO;
    }
}
- (StepSection)lastSection {
    for (StepSection section = SectionCount - 1; section > SectionInfo; section--) if ([self has:section]) return section;
    return SectionInfo;
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)table { return SectionCount; }
- (NSInteger)tableView:(__unused UITableView *)table numberOfRowsInSection:(NSInteger)section {
    if (![self has:section]) return 0;
    if (section == SectionInfo) return (self.problem.length ? 1 : 0) + (self.message.length ? 1 : 0);
    return section == SectionFields ? (NSInteger)self.fields.count : 1;
}
- (NSString *)tableView:(__unused UITableView *)table titleForFooterInSection:(NSInteger)section {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    if (section == SectionFields && self.fieldsNote.length) [lines addObject:self.fieldsNote];
    if (section == [self lastSection] && self.detail.length) [lines addObject:self.detail];
    return lines.count ? [lines componentsJoinedByString:@"\n\n"] : nil;
}
- (CGFloat)tableView:(UITableView *)table heightForHeaderInSection:(NSInteger)section {
    return [self has:section] ? UITableViewAutomaticDimension : CGFLOAT_MIN;
}
- (CGFloat)tableView:(UITableView *)table heightForFooterInSection:(NSInteger)section {
    return [self has:section] || [self tableView:table titleForFooterInSection:section] ? UITableViewAutomaticDimension : CGFLOAT_MIN;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:@"row" forIndexPath:path];
    cell.insetsLayoutMarginsFromSafeArea = table.insetsLayoutMarginsFromSafeArea;   // edge to edge with the list
    for (UIView *old in cell.contentView.subviews) [old removeFromSuperview];
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];
    switch ((StepSection)path.section) {
        case SectionInfo: {
            BOOL problem = self.problem.length && path.row == 0;
            content.text = problem ? self.problem : self.message;
            content.image = [UIImage systemImageNamed:problem ? @"exclamationmark.triangle.fill" : @"info.circle"];
            content.imageProperties.tintColor = problem ? UIColor.systemRedColor : UIColor.secondaryLabelColor;
            if (problem) content.textProperties.color = UIColor.systemRedColor;
            break;
        }
        case SectionFields: {
            UITextField *field = self.fields[(NSUInteger)path.row];
            field.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:field];
            UILayoutGuide *margins = cell.contentView.layoutMarginsGuide;
            [NSLayoutConstraint activateConstraints:@[
                [field.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
                [field.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
                [field.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor],
                [field.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor],
                [field.heightAnchor constraintGreaterThanOrEqualToConstant:44],
            ]];
            cell.contentConfiguration = nil;
            return cell;
        }
        case SectionWaiting: {
            content.text = self.waiting;
            content.textProperties.color = UIColor.secondaryLabelColor;
            UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
            [spinner startAnimating];
            cell.accessoryView = spinner;
            break;
        }
        case SectionAction:
            content.text = self.actionTitle;
            content.textProperties.color = self.busy ? UIColor.tertiaryLabelColor : self.view.tintColor;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.accessibilityTraits = UIAccessibilityTraitButton;
            break;
        default: break;
    }
    cell.contentConfiguration = content;
    return cell;
}
- (BOOL)tableView:(__unused UITableView *)table shouldHighlightRowAtIndexPath:(NSIndexPath *)path {
    return path.section == SectionAction && !self.busy;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (path.section == SectionAction && !self.busy && self.action) self.action();
}

- (void)setBusy:(BOOL)busy {
    _busy = busy;
    for (UITextField *field in self.fields) field.enabled = !busy;
    if (busy) {
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:spinner];
    } else {
        self.navigationItem.rightBarButtonItem = self.primary;
    }
    self.navigationItem.leftBarButtonItem.enabled = !busy;
    self.navigationItem.hidesBackButton = busy;
    if ([self has:SectionAction] && self.isViewLoaded)
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:SectionAction] withRowAnimation:UITableViewRowAnimationNone];
}
@end

@interface PocketSignInViewController () <UITextFieldDelegate>
@end

@implementation PocketSignInViewController {
    NSString *_cancelTitle;
    dispatch_block_t _cancel;
    UITextField *_account, *_password, *_code;
    __weak PocketSignInStep *_accountStep;   // under a code or an approval, for Back
    void (^_submitCredentials)(NSString *, NSString *);
    void (^_submitCode)(NSString *);
}

- (instancetype)initWithCancelTitle:(NSString *)cancelTitle cancel:(dispatch_block_t)cancel {
    if (!(self = [super initWithNibName:nil bundle:nil])) return nil;
    _cancelTitle = [cancelTitle copy];
    _cancel = [cancel copy];
    self.modalPresentationStyle = UIModalPresentationFormSheet;
    self.modalInPresentation = YES;   // a way on is chosen, never swiped away
    return self;
}

// Full screen on a phone: no status bar, as over the game, so the sheet has the whole width
// (on the iPhone Duo's outer screen held upright, the status bar takes a column at the side).
- (BOOL)prefersStatusBarHidden { return YES; }

- (PocketSignInStep *)step { return [self.topViewController isKindOfClass:PocketSignInStep.class] ? (PocketSignInStep *)self.topViewController : nil; }

// A new step. Pushed over the account and password (a code, an approval), so Back returns to
// it; otherwise in place of every step shown so far.
- (void)show:(PocketSignInStep *)step title:(NSString *)title pushed:(BOOL)pushed {
    step.title = title;
    step.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    for (UIViewController *shown in self.viewControllers)
        if ([shown isKindOfClass:PocketSignInStep.class]) ((PocketSignInStep *)shown).back = nil;   // leaving them is not Back
    BOOL visible = self.viewIfLoaded.window != nil;
    PocketSignInStep *account = _accountStep;
    BOOL over = pushed && account && self.viewControllers.firstObject == account;
    if (over) {
        // A titled Back: iOS 26 drew the icon-only one out of the bar in a full-screen sheet
        // beside a camera (the iPhone Duo's outer screen). Leaving the step calls its back.
        step.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Back" style:UIBarButtonItemStylePlain target:self
                                                                                action:@selector(backTapped)];
    }
    if (over && self.topViewController == account) {
        [self pushViewController:step animated:visible];
        return;
    }
    if (!over) step.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:_cancelTitle style:UIBarButtonItemStylePlain
                                                                                       target:self action:@selector(cancelTapped)];
    [self setViewControllers:over ? @[account, step] : @[step] animated:NO];
    if (visible) [UIView transitionWithView:self.view duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve animations:nil completion:nil];
}

- (UITextField *)field:(NSString *)placeholder {
    UITextField *field = [UITextField new];
    field.placeholder = placeholder;
    field.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    field.adjustsFontForContentSizeCategory = YES;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.delegate = self;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.spellCheckingType = UITextSpellCheckingTypeNo;
    field.smartQuotesType = UITextSmartQuotesTypeNo;
    field.smartDashesType = UITextSmartDashesTypeNo;
    [field addTarget:self action:@selector(edited:) forControlEvents:UIControlEventEditingChanged];
    return field;
}

// --- the steps ------------------------------------------------------------------------------
- (void)askForAccount:(NSString *)account problem:(NSString *)problem detail:(NSString *)detail
               submit:(void (^)(NSString *, NSString *))submit {
    UITextField *name = [self field:@"Account Name"];
    name.text = account;
    name.textContentType = UITextContentTypeUsername;
    name.returnKeyType = UIReturnKeyNext;
    UITextField *password = [self field:@"Password"];
    password.secureTextEntry = YES;
    password.textContentType = UITextContentTypePassword;
    password.returnKeyType = UIReturnKeyGo;
    password.clearButtonMode = UITextFieldViewModeNever;
    UIButton *eye = [UIButton buttonWithConfiguration:[UIButtonConfiguration plainButtonConfiguration] primaryAction:nil];
    [eye addTarget:self action:@selector(toggleShown:) forControlEvents:UIControlEventTouchUpInside];
    password.rightView = eye;
    password.rightViewMode = UITextFieldViewModeAlways;
    _account = name;
    _password = password;
    _code = nil;
    [self showPassword:NO];

    PocketSignInStep *step = [PocketSignInStep new];
    step.message = @"Brighter Shores plays with your Steam account. Sign in to play online.";
    step.problem = problem;
    step.fields = @[name, password];
    step.fieldsNote = @"Your password goes only to Steam. This device keeps Steam's sign-in in its keychain, so you won't be asked every time.";
    step.detail = detail;
    step.primary = [[UIBarButtonItem alloc] initWithTitle:@"Sign In" style:UIBarButtonItemStyleDone target:self action:@selector(submitCredentials)];
    _submitCredentials = [submit copy];
    [self show:step title:@"Steam" pushed:NO];
    _accountStep = step;
    [self updatePrimary];
}

- (void)askForCodeEmailedTo:(NSString *)email approve:(BOOL)approve problem:(NSString *)problem
                     submit:(void (^)(NSString *))submit back:(dispatch_block_t)back {
    NSString *message = email ? [NSString stringWithFormat:@"Steam emailed a code to %@. Enter it here.", email.length ? email : @"you"]
                              : @"Open the Steam Mobile app and enter the code it shows.";
    // (an emailed code comes with an emailed link to approve instead; the app's code with approval in the app)
    if (approve) message = [message stringByAppendingString:email ? @" Or open the link in that email to approve the sign-in."
                                                                  : @" Or approve the sign-in in the app."];
    UITextField *code = [self field:@"Code"];
    code.textContentType = UITextContentTypeOneTimeCode;
    code.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    code.keyboardType = UIKeyboardTypeASCIICapable;
    code.returnKeyType = UIReturnKeyGo;
    code.clearButtonMode = UITextFieldViewModeNever;
    UIFont *font = [UIFont monospacedSystemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleTitle2].pointSize weight:UIFontWeightSemibold];
    code.defaultTextAttributes = @{NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.labelColor, NSKernAttributeName: @6};
    code.textAlignment = NSTextAlignmentCenter;   // after the attributes, which set it too
    _code = code;

    PocketSignInStep *step = [PocketSignInStep new];
    step.message = message;
    step.problem = problem;
    step.fields = @[code];
    step.primary = [[UIBarButtonItem alloc] initWithTitle:@"Continue" style:UIBarButtonItemStyleDone target:self action:@selector(submitCode)];
    _submitCode = [submit copy];
    [self show:step title:@"Steam Guard" pushed:YES];
    step.back = back;
    [self updatePrimary];
}

- (void)waitForApprovalInApp:(BOOL)inApp back:(dispatch_block_t)back {
    PocketSignInStep *step = [PocketSignInStep new];
    step.message = inApp ? @"Open the Steam Mobile app on your phone and approve this sign-in. Brighter Pocket carries on by itself."
                         : @"Steam emailed you a link. Open it to approve this sign-in. Brighter Pocket carries on by itself.";
    step.waiting = @"Waiting for your approval…";
    _code = nil;
    [self.view endEditing:YES];
    [self show:step title:@"Approve Sign-In" pushed:YES];
    step.back = back;
}

- (void)showWaiting:(NSString *)title text:(NSString *)text {
    PocketSignInStep *step = [PocketSignInStep new];
    step.waiting = text;
    _account = _password = _code = nil;
    _accountStep = nil;
    [self.view endEditing:YES];
    [self show:step title:title pushed:NO];
}

- (void)showProblem:(NSString *)title message:(NSString *)message detail:(NSString *)detail
             action:(NSString *)action handler:(dispatch_block_t)handler {
    PocketSignInStep *step = [PocketSignInStep new];
    step.problem = message;
    step.detail = detail;
    step.actionTitle = action;
    __weak PocketSignInStep *weakStep = step;
    step.action = ^{
        [weakStep setBusy:YES];
        handler();
    };
    _account = _password = _code = nil;
    _accountStep = nil;
    [self.view endEditing:YES];
    [self show:step title:title pushed:NO];
}

- (void)setBusy:(BOOL)busy {
    self.step.busy = busy;
    if (!busy) [self updatePrimary];
}

// --- what the player does ---------------------------------------------------------------------
- (void)updatePrimary {
    PocketSignInStep *step = self.step;
    BOOL ready = YES;
    if (_account && [step.fields containsObject:_account]) ready = [self trimmedAccount].length && _password.text.length;
    if (_code && [step.fields containsObject:_code]) ready = [self typedCode].length == CodeLength;
    step.primary.enabled = ready && !step.busy;
}
- (NSString *)trimmedAccount { return [_account.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; }
- (NSString *)typedCode {
    NSCharacterSet *other = NSCharacterSet.alphanumericCharacterSet.invertedSet;
    return [[_code.text componentsSeparatedByCharactersInSet:other] componentsJoinedByString:@""].uppercaseString;
}
- (void)edited:(UITextField *)field {
    if (field == _code) {
        NSString *code = [self typedCode];
        if (code.length > CodeLength) code = [code substringToIndex:CodeLength];
        if (![field.text isEqualToString:code]) field.text = code;
        [self updatePrimary];
        if (code.length == CodeLength && !self.step.busy) [self submitCode];
        return;
    }
    [self updatePrimary];
}
- (void)showPassword:(BOOL)shown {
    _password.secureTextEntry = !shown;
    UIButton *eye = (UIButton *)_password.rightView;
    UIButtonConfiguration *configuration = eye.configuration;
    configuration.image = [UIImage systemImageNamed:shown ? @"eye.slash" : @"eye"];
    configuration.baseForegroundColor = UIColor.secondaryLabelColor;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(0, 8, 0, 0);
    eye.configuration = configuration;
    eye.accessibilityLabel = shown ? @"Hide Password" : @"Show Password";
}
- (void)toggleShown:(__unused UIButton *)eye {
    // Keep what was typed: a secure field clears itself on the next key after it is turned back on.
    NSString *text = _password.text;
    [self showPassword:_password.secureTextEntry];
    _password.text = @"";
    [_password insertText:text];
}
- (void)submitCredentials {
    PocketSignInStep *step = self.step;
    if (!step.primary.enabled || !_submitCredentials) return;
    NSString *account = [self trimmedAccount], *password = _password.text;
    [self setBusy:YES];
    _submitCredentials(account, password);
}
- (void)submitCode {
    PocketSignInStep *step = self.step;
    if (!step.primary.enabled || !_submitCode) return;
    NSString *code = [self typedCode];
    [self setBusy:YES];
    _submitCode(code);
}
- (void)backTapped { [self popViewControllerAnimated:YES]; }
- (void)cancelTapped {
    [self.view endEditing:YES];
    if (_cancel) _cancel();
}

- (BOOL)textFieldShouldReturn:(UITextField *)field {
    if (field == _account) [_password becomeFirstResponder];
    else if (field == _password) [self submitCredentials];
    else if (field == _code) [self submitCode];
    return NO;
}
@end
