// Copyright 2026 The Blinker Fluid Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/shell_media_permission_prompt_ios.h"

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

#include <map>
#include <string>

#include "base/apple/foundation_util.h"
#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/strings/sys_string_conversions.h"

namespace content {
namespace {

// Per-origin site-level decision cache, valid for the lifetime of the app
// process (i.e. "for this session"), matching typical mobile browser
// behavior of not re-prompting on every navigation once a site has been
// allowed or denied camera/mic during the session.
enum class SiteDecision { kUnknown, kAllowed, kDenied };

struct CachedDecision {
  SiteDecision audio = SiteDecision::kUnknown;
  SiteDecision video = SiteDecision::kUnknown;
};

std::map<std::string, CachedDecision>& DecisionCache() {
  static base::NoDestructor<std::map<std::string, CachedDecision>> cache;
  return *cache;
}

UIViewController* TopPresenterViewController() {
  UIWindow* keyWindow = nil;
  for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:[UIWindowScene class]])
      continue;
    for (UIWindow* window in ((UIWindowScene*)scene).windows) {
      if (window.isKeyWindow) {
        keyWindow = window;
        break;
      }
    }
    if (keyWindow)
      break;
  }
  UIViewController* top = keyWindow.rootViewController;
  while (top.presentedViewController &&
         !top.presentedViewController.isBeingDismissed) {
    top = top.presentedViewController;
  }
  return top;
}

// Requests OS-level AVCaptureDevice authorization for the given media
// types (only for types the site was actually allowed to use), then
// reports the combined site+system result.
void ResolveSystemAuthorization(bool audio_allowed_by_site,
                                 bool video_allowed_by_site,
                                 ShellMediaPermissionPromptIOS::ResultCallback callback) {
  __block bool audio_granted = false;
  __block bool video_granted = false;
  __block int pending = (audio_allowed_by_site ? 1 : 0) +
                        (video_allowed_by_site ? 1 : 0);
  // A __block-captured callback can be safely std::move()'d exactly once;
  // `complete` guarantees it only ever runs after `pending` reaches zero.
  __block ShellMediaPermissionPromptIOS::ResultCallback owned_callback =
      std::move(callback);
  auto complete = ^{
    if (pending > 0)
      return;
    std::move(owned_callback).Run(audio_granted, video_granted);
  };

  if (pending == 0) {
    complete();
    return;
  }

  if (audio_allowed_by_site) {
    AVAuthorizationStatus status =
        [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (status == AVAuthorizationStatusAuthorized) {
      audio_granted = true;
      pending--;
    } else if (status == AVAuthorizationStatusNotDetermined) {
      [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio
                                completionHandler:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
          audio_granted = granted;
          pending--;
          complete();
        });
      }];
    } else {
      pending--;  // Denied/restricted at the OS level.
    }
  }

  if (video_allowed_by_site) {
    AVAuthorizationStatus status =
        [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (status == AVAuthorizationStatusAuthorized) {
      video_granted = true;
      pending--;
    } else if (status == AVAuthorizationStatusNotDetermined) {
      [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                                completionHandler:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
          video_granted = granted;
          pending--;
          complete();
        });
      }];
    } else {
      pending--;
    }
  }

  complete();
}

}  // namespace

// static
void ShellMediaPermissionPromptIOS::RequestAccess(const GURL& origin,
                                                    bool want_audio,
                                                    bool want_video,
                                                    ResultCallback callback) {
  if (!want_audio && !want_video) {
    std::move(callback).Run(false, false);
    return;
  }

  const std::string origin_key = origin.DeprecatedGetOriginAsURL().spec();
  CachedDecision& cached = DecisionCache()[origin_key];

  bool audio_known = !want_audio || cached.audio != SiteDecision::kUnknown;
  bool video_known = !want_video || cached.video != SiteDecision::kUnknown;
  if (audio_known && video_known) {
    bool audio_site_ok = want_audio && cached.audio == SiteDecision::kAllowed;
    bool video_site_ok = want_video && cached.video == SiteDecision::kAllowed;
    ResolveSystemAuthorization(audio_site_ok, video_site_ok,
                                std::move(callback));
    return;
  }

  UIViewController* presenter = TopPresenterViewController();
  if (!presenter) {
    std::move(callback).Run(false, false);
    return;
  }

  NSString* host = base::SysUTF8ToNSString(origin.host());
  NSString* message;
  if (want_audio && want_video) {
    message = [NSString
        stringWithFormat:@"%@ would like to use your camera and microphone.",
                          host];
  } else if (want_video) {
    message =
        [NSString stringWithFormat:@"%@ would like to use your camera.", host];
  } else {
    message = [NSString
        stringWithFormat:@"%@ would like to use your microphone.", host];
  }

  UIAlertController* alert = [UIAlertController
      alertControllerWithTitle:@"Allow Access?"
                        message:message
                 preferredStyle:UIAlertControllerStyleAlert];

  __block ResultCallback owned_callback = std::move(callback);
  const GURL origin_copy = origin;

  [alert addAction:[UIAlertAction
                        actionWithTitle:@"Don't Allow"
                                  style:UIAlertActionStyleCancel
                                handler:^(UIAlertAction*) {
    CachedDecision& d = DecisionCache()[origin_copy.DeprecatedGetOriginAsURL().spec()];
    if (want_audio)
      d.audio = SiteDecision::kDenied;
    if (want_video)
      d.video = SiteDecision::kDenied;
    std::move(owned_callback).Run(false, false);
  }]];

  [alert addAction:[UIAlertAction
                        actionWithTitle:@"Allow"
                                  style:UIAlertActionStyleDefault
                                handler:^(UIAlertAction*) {
    CachedDecision& d = DecisionCache()[origin_copy.DeprecatedGetOriginAsURL().spec()];
    if (want_audio)
      d.audio = SiteDecision::kAllowed;
    if (want_video)
      d.video = SiteDecision::kAllowed;
    ResolveSystemAuthorization(want_audio, want_video,
                                std::move(owned_callback));
  }]];

  [presenter presentViewController:alert animated:YES completion:nil];
}

// static
void ShellMediaPermissionPromptIOS::ClearCachedDecisions() {
  DecisionCache().clear();
}

}  // namespace content
