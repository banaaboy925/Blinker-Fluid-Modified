// Copyright 2026 The Blinker Fluid Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/shell_file_select_helper.h"

#import <MobileCoreServices/MobileCoreServices.h>
#import <PhotosUI/PhotosUI.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "base/apple/foundation_util.h"
#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/strings/utf_string_conversions.h"
#include "base/strings/sys_string_conversions.h"
#include "base/uuid.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"

namespace content {
namespace {

// Bag that keeps the Objective-C picker session alive for as long as an
// async pick is outstanding. Chromium's C++ objects have no natural owner
// for a modal iOS UI flow, so we park a strong reference here and drop it
// once the flow completes (either via delegate callback or cancellation).
NSMutableSet* g_active_sessions;

NSMutableSet* ActiveSessions() {
  if (!g_active_sessions)
    g_active_sessions = [[NSMutableSet alloc] init];
  return g_active_sessions;
}

bool AcceptTypesWant(const std::vector<std::u16string>& accept_types,
                      bool* wants_images,
                      bool* wants_videos,
                      bool* wants_any_file) {
  *wants_images = false;
  *wants_videos = false;
  *wants_any_file = accept_types.empty();

  for (const auto& accept16 : accept_types) {
    std::string accept = base::UTF16ToUTF8(accept16);
    if (accept.empty())
      continue;
    if (accept == "image/*" || accept.rfind("image/", 0) == 0) {
      *wants_images = true;
    } else if (accept == "video/*" || accept.rfind("video/", 0) == 0) {
      *wants_videos = true;
    } else if (accept[0] == '.') {
      // Extension-based accept (".png", ".pdf", ...): image/video
      // extensions still count toward the media pickers, anything else
      // routes through the generic "Browse" document picker.
      NSString* ext = base::SysUTF8ToNSString(accept.substr(1));
      UTType* type = [UTType typeWithFilenameExtension:ext];
      if ([type conformsToType:UTTypeImage]) {
        *wants_images = true;
      } else if ([type conformsToType:UTTypeMovie]) {
        *wants_videos = true;
      } else {
        *wants_any_file = true;
      }
    } else {
      // Any other MIME type (application/pdf, text/*, etc.) can only be
      // satisfied by the document picker.
      *wants_any_file = true;
    }
  }

  if (!*wants_images && !*wants_videos && !*wants_any_file)
    *wants_any_file = true;

  return *wants_images || *wants_videos || *wants_any_file;
}

base::FilePath TempDirForThisPick() {
  base::FilePath dir;
  base::GetTempDir(&dir);
  dir = dir.Append("blinker_file_chooser")
            .Append(base::Uuid::GenerateRandomV4().AsLowercaseString());
  base::CreateDirectory(dir);
  return dir;
}

blink::mojom::FileChooserFileInfoPtr MakeNativeFileInfo(
    const base::FilePath& path,
    const std::u16string& display_name) {
  return blink::mojom::FileChooserFileInfo::NewNativeFile(
      blink::mojom::NativeFileInfo::New(path, display_name));
}

}  // namespace

}  // namespace content

// -----------------------------------------------------------------------
// Objective-C session object.
// -----------------------------------------------------------------------

@interface BlinkFileChooserSession
    : NSObject <UIImagePickerControllerDelegate, UINavigationControllerDelegate,
                PHPickerViewControllerDelegate,
                UIDocumentPickerDelegate>

- (instancetype)initWithListener:
                    (scoped_refptr<content::FileSelectListener>)listener
                             mode:(blink::mojom::FileChooserParams::Mode)mode
                    wantsImages:(BOOL)wantsImages
                    wantsVideos:(BOOL)wantsVideos
                    wantsAnyFile:(BOOL)wantsAnyFile
                  useMediaCapture:(BOOL)useMediaCapture;

- (void)presentFrom:(UIViewController*)presenter;

@end

@implementation BlinkFileChooserSession {
  scoped_refptr<content::FileSelectListener> _listener;
  blink::mojom::FileChooserParams::Mode _mode;
  BOOL _wantsImages;
  BOOL _wantsVideos;
  BOOL _wantsAnyFile;
  BOOL _useMediaCapture;
  BOOL _finished;
}

- (instancetype)initWithListener:
                    (scoped_refptr<content::FileSelectListener>)listener
                             mode:(blink::mojom::FileChooserParams::Mode)mode
                    wantsImages:(BOOL)wantsImages
                    wantsVideos:(BOOL)wantsVideos
                    wantsAnyFile:(BOOL)wantsAnyFile
                  useMediaCapture:(BOOL)useMediaCapture {
  if ((self = [super init])) {
    _listener = listener;
    _mode = mode;
    _wantsImages = wantsImages;
    _wantsVideos = wantsVideos;
    _wantsAnyFile = wantsAnyFile;
    _useMediaCapture = useMediaCapture;
  }
  return self;
}

- (void)retainSelf {
  [content::ActiveSessions() addObject:self];
}

- (void)releaseSelfAfter:(void (^)(void))block {
  block();
  [content::ActiveSessions() removeObject:self];
}

- (void)cancel {
  if (_finished)
    return;
  _finished = YES;
  [self releaseSelfAfter:^{
    if (_listener) {
      _listener->FileSelectionCanceled();
      _listener = nullptr;
    }
  }];
}

- (void)finishWithFiles:(NSArray<NSURL*>*)fileURLs {
  if (_finished)
    return;
  _finished = YES;
  if (fileURLs.count == 0) {
    [self cancel];
    return;
  }

  base::FilePath destDir = content::TempDirForThisPick();
  blink::mojom::FileChooserParams::Mode mode = _mode;
  scoped_refptr<content::FileSelectListener> listener = std::move(_listener);
  _listener = nullptr;

  // `self` is retained by content::ActiveSessions() for the duration of
  // this flow, so it's safe to reference strongly here; we remove it from
  // the set (dropping the last strong ref) once we're back on the UI
  // thread with a result.
  BlinkFileChooserSession* strongSelf = self;

  dispatch_async(
      dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        std::vector<blink::mojom::FileChooserFileInfoPtr> out;
        for (NSURL* url in fileURLs) {
          BOOL scoped = [url startAccessingSecurityScopedResource];
          NSString* filename = url.lastPathComponent;
          base::FilePath dest =
              destDir.Append(base::SysNSStringToUTF8(filename));
          NSError* error = nil;
          [[NSFileManager defaultManager]
              copyItemAtURL:url
                      toURL:base::apple::FilePathToNSURL(dest)
                      error:&error];
          if (scoped)
            [url stopAccessingSecurityScopedResource];
          if (!error) {
            out.push_back(content::MakeNativeFileInfo(
                dest, base::SysNSStringToUTF16(filename)));
          }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
          if (out.empty()) {
            listener->FileSelectionCanceled();
          } else {
            listener->FileSelected(std::move(out), base::FilePath(), mode);
          }
          [content::ActiveSessions() removeObject:strongSelf];
        });
      });
}

// ---------------------------------------------------------------------
// Presentation
// ---------------------------------------------------------------------

- (void)presentFrom:(UIViewController*)presenter {
  [self retainSelf];

  if (_useMediaCapture &&
      [UIImagePickerController
          isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) {
    [self presentCameraFrom:presenter];
    return;
  }

  UIAlertController* sheet = [UIAlertController
      alertControllerWithTitle:nil
                        message:nil
                 preferredStyle:UIAlertControllerStyleActionSheet];

  BOOL cameraAvailable = [UIImagePickerController
      isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera];

  if (cameraAvailable && (_wantsImages || _wantsVideos || _wantsAnyFile)) {
    NSString* title = @"Take Photo or Video";
    if (_wantsImages && !_wantsVideos)
      title = @"Take Photo";
    else if (_wantsVideos && !_wantsImages)
      title = @"Take Video";
    __weak BlinkFileChooserSession* weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:title
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction*) {
      [weakSelf presentCameraFrom:presenter];
    }]];
  }

  if (_wantsImages || _wantsVideos || _wantsAnyFile) {
    __weak BlinkFileChooserSession* weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Photo Library"
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction*) {
      [weakSelf presentPhotoLibraryFrom:presenter];
    }]];
  }

  {
    __weak BlinkFileChooserSession* weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Browse"
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction*) {
      [weakSelf presentDocumentPickerFrom:presenter];
    }]];
  }

  __weak BlinkFileChooserSession* weakSelf = self;
  [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                             style:UIAlertActionStyleCancel
                                           handler:^(UIAlertAction*) {
    [weakSelf cancel];
  }]];

  if (sheet.popoverPresentationController) {
    sheet.popoverPresentationController.sourceView = presenter.view;
    sheet.popoverPresentationController.sourceRect =
        CGRectMake(presenter.view.bounds.size.width / 2,
                   presenter.view.bounds.size.height, 1, 1);
  }
  [presenter presentViewController:sheet animated:YES completion:nil];
}

// ---------------------------------------------------------------------
// Camera capture -- respects accept type (image vs video vs both), per
// the fix in reynard-browser 0.4.0.
// ---------------------------------------------------------------------

- (void)presentCameraFrom:(UIViewController*)presenter {
  UIImagePickerController* picker = [[UIImagePickerController alloc] init];
  picker.sourceType = UIImagePickerControllerSourceTypeCamera;
  picker.delegate = self;
  picker.allowsEditing = NO;

  NSMutableArray<NSString*>* mediaTypes = [NSMutableArray array];
  if (_wantsImages || (!_wantsVideos && _wantsAnyFile))
    [mediaTypes addObject:(NSString*)kUTTypeImage];
  if (_wantsVideos)
    [mediaTypes addObject:(NSString*)kUTTypeMovie];
  if (mediaTypes.count == 0)
    [mediaTypes addObject:(NSString*)kUTTypeImage];
  picker.mediaTypes = mediaTypes;
  if (_wantsVideos && !_wantsImages)
    picker.cameraCaptureMode = UIImagePickerControllerCameraCaptureModeVideo;

  [presenter presentViewController:picker animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController*)picker
    didFinishPickingMediaWithInfo:
        (NSDictionary<UIImagePickerControllerInfoKey, id>*)info {
  [picker dismissViewControllerAnimated:YES completion:nil];

  NSURL* mediaURL = info[UIImagePickerControllerMediaURL];
  if (mediaURL) {
    // Captured video: already a file on disk.
    [self finishWithFiles:@[ mediaURL ]];
    return;
  }

  UIImage* image = info[UIImagePickerControllerEditedImage]
                        ?: info[UIImagePickerControllerOriginalImage];
  if (!image) {
    [self cancel];
    return;
  }
  NSData* jpeg = UIImageJPEGRepresentation(image, 0.92);
  NSString* filename =
      [NSString stringWithFormat:@"photo_%.0f.jpg", [NSDate date].timeIntervalSince1970 * 1000];
  NSURL* tmp = [NSURL fileURLWithPath:[NSTemporaryDirectory()
                                           stringByAppendingPathComponent:filename]];
  [jpeg writeToURL:tmp atomically:YES];
  [self finishWithFiles:@[ tmp ]];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController*)picker {
  [picker dismissViewControllerAnimated:YES completion:nil];
  [self cancel];
}

// ---------------------------------------------------------------------
// Photo library (PHPickerViewController, iOS 14+) -- also respects
// accept type and multiple-selection mode.
// ---------------------------------------------------------------------

- (void)presentPhotoLibraryFrom:(UIViewController*)presenter {
  PHPickerConfiguration* config = [[PHPickerConfiguration alloc] init];
  config.selectionLimit =
      (_mode == blink::mojom::FileChooserParams::Mode::kOpenMultiple) ? 0 : 1;
  if (_wantsImages && !_wantsVideos) {
    config.filter = [PHPickerFilter imagesFilter];
  } else if (_wantsVideos && !_wantsImages) {
    config.filter = [PHPickerFilter videosFilter];
  } else {
    config.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[
      [PHPickerFilter imagesFilter], [PHPickerFilter videosFilter]
    ]];
  }
  PHPickerViewController* picker =
      [[PHPickerViewController alloc] initWithConfiguration:config];
  picker.delegate = self;
  [presenter presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController*)picker
    didFinishPicking:(NSArray<PHPickerResult*>*)results {
  [picker dismissViewControllerAnimated:YES completion:nil];
  if (results.count == 0) {
    [self cancel];
    return;
  }

  NSMutableArray<NSURL*>* fileURLs = [NSMutableArray array];
  __block NSInteger remaining = results.count;
  __weak BlinkFileChooserSession* weakSelf = self;

  for (PHPickerResult* result in results) {
    NSItemProvider* provider = result.itemProvider;
    NSString* typeId = provider.registeredTypeIdentifiers.firstObject;
    if (!typeId) {
      remaining--;
      continue;
    }
    [provider loadFileRepresentationForTypeIdentifier:typeId
                                     completionHandler:^(NSURL* url,
                                                          NSError* error) {
      dispatch_async(dispatch_get_main_queue(), ^{
        if (url && !error) {
          NSString* filename = provider.suggestedName.length
                                    ? [provider.suggestedName
                                          stringByAppendingPathExtension:
                                              url.pathExtension]
                                    : url.lastPathComponent;
          NSURL* dest = [NSURL
              fileURLWithPath:[NSTemporaryDirectory()
                                   stringByAppendingPathComponent:filename]];
          [[NSFileManager defaultManager] removeItemAtURL:dest error:nil];
          NSError* copyError = nil;
          if ([[NSFileManager defaultManager] copyItemAtURL:url
                                                        toURL:dest
                                                        error:&copyError]) {
            @synchronized(fileURLs) {
              [fileURLs addObject:dest];
            }
          }
        }
        remaining--;
        if (remaining <= 0) {
          [weakSelf finishWithFiles:fileURLs];
        }
      });
    }];
  }
  if (results.count == 0) {
    [self finishWithFiles:fileURLs];
  }
}

// ---------------------------------------------------------------------
// Browse (any file, via document providers -- Files app, iCloud Drive,
// third-party cloud providers, etc).
// ---------------------------------------------------------------------

- (void)presentDocumentPickerFrom:(UIViewController*)presenter {
  NSMutableArray<UTType*>* types = [NSMutableArray array];
  if (_wantsImages)
    [types addObject:UTTypeImage];
  if (_wantsVideos)
    [types addObject:UTTypeMovie];
  if (_wantsAnyFile || types.count == 0)
    [types addObject:UTTypeItem];

  UIDocumentPickerViewController* picker = [[UIDocumentPickerViewController alloc]
      initForOpeningContentTypes:types];
  picker.allowsMultipleSelection =
      (_mode == blink::mojom::FileChooserParams::Mode::kOpenMultiple);
  picker.delegate = self;
  [presenter presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController*)controller
    didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
  [self finishWithFiles:urls];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController*)controller {
  [self cancel];
}

@end

namespace content {

namespace {

UIViewController* TopPresenterViewController() {
  UIWindow* keyWindow = nil;
  for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:[UIWindowScene class]])
      continue;
    UIWindowScene* windowScene = (UIWindowScene*)scene;
    for (UIWindow* window in windowScene.windows) {
      if (window.isKeyWindow) {
        keyWindow = window;
        break;
      }
    }
    if (keyWindow)
      break;
  }
  UIViewController* root = keyWindow.rootViewController;
  UIViewController* top = root;
  while (top.presentedViewController &&
         !top.presentedViewController.isBeingDismissed) {
    top = top.presentedViewController;
  }
  return top;
}

}  // namespace

// static
void ShellFileSelectHelper::RunFileChooser(
    RenderFrameHost* render_frame_host,
    scoped_refptr<FileSelectListener> listener,
    const blink::mojom::FileChooserParams& params) {
  DCHECK_CURRENTLY_ON(BrowserThread::UI);

  if (params.mode == blink::mojom::FileChooserParams::Mode::kSave) {
    // Save dialogs aren't relevant to <input type=file>; nothing to do.
    listener->FileSelectionCanceled();
    return;
  }

  bool wants_images = false;
  bool wants_videos = false;
  bool wants_any_file = false;
  AcceptTypesWant(params.accept_types, &wants_images, &wants_videos,
                  &wants_any_file);

  if (params.mode == blink::mojom::FileChooserParams::Mode::kUploadFolder)
    wants_any_file = true;

  UIViewController* presenter = TopPresenterViewController();
  if (!presenter) {
    listener->FileSelectionCanceled();
    return;
  }

  BlinkFileChooserSession* session = [[BlinkFileChooserSession alloc]
      initWithListener:listener
                  mode:params.mode
           wantsImages:wants_images
           wantsVideos:wants_videos
          wantsAnyFile:wants_any_file
       useMediaCapture:params.use_media_capture];
  [session presentFrom:presenter];
}

}  // namespace content
