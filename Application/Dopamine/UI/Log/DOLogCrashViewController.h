//
//  DOLogCrashViewController.h
//  Dopamine
//
//  Created by tomt000 on 14/02/2024.
//

#import <UIKit/UIKit.h>
#import "DOLogViewProtocol.h"

NS_ASSUME_NONNULL_BEGIN

@interface DOLogCrashViewController : UIViewController <DOLogViewProtocol>
{
    UITextView *_logView;
}

- (id)initWithTitle:(NSString*)title;
- (id)initWithTitle:(NSString *)title exitOnDisappear:(BOOL)exitOnDisappear;

@end

NS_ASSUME_NONNULL_END
