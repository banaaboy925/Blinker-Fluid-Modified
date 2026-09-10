// Copyright 2023 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "ui/shell_dialogs/select_file_dialog_ios.h"

#import <MobileCoreServices/MobileCoreServices.h>
#import <PhotosUI/PhotosUI.h>
#import <UIKit/UIDocumentPickerViewController.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <algorithm>

#include "base/apple/foundation_util.h"
#include "base/apple/scoped_cftyperef.h"
#include "base/memory/weak_ptr.h"
#include "base/notreached.h"
#include "base/strings/string_util.h"
#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "ui/shell_dialogs/select_file_policy.h"
#include "ui/shell_dialogs/selected_file_info.h"

@interface NativeFileDialog
    : NSObject <UIDocumentPickerDelegate,
                UIImagePickerControllerDelegate,
                UINavigationControllerDelegate,
                PHPickerViewControllerDelegate> {
 @private
  base::WeakPtr<ui::SelectFileDialogImpl> _dialog;
  UIViewController* __weak _viewController;
  bool _allowMultipleFiles;
  UIDocumentPickerViewController* __strong _documentPickerController;
  UIImagePickerController* __strong _imagePickerController;
  PHPickerViewController* __strong _photoPickerController API_AVAILABLE(ios(14));
  NSArray* __strong _fileUTTypeLists;
  bool _allowsOtherFileTypes;
  bool _isDirectory;
  bool _mediaOnly;
  bool _useMediaCapture;
  bool _acceptsImages;
  bool _acceptsVideos;
}

- (instancetype)initWithDialog:(base::WeakPtr<ui::SelectFileDialogImpl>)dialog
                viewController:(UIViewController*)viewController
            allowMultipleFiles:(bool)allowMultipleFiles
               fileUTTypeLists:(NSArray*)fileUTTypeLists
          allowsOtherFileTypes:(bool)allowsOtherFileTypes
                   isDirectory:(bool)isDirectory
                      mediaOnly:(bool)mediaOnly
                useMediaCapture:(bool)useMediaCapture
                  acceptsImages:(bool)acceptsImages
                  acceptsVideos:(bool)acceptsVideos;
- (void)dealloc;
- (void)showFilePickerMenu;
- (void)showDocumentPicker;
- (void)showPhotoPicker;
- (void)showCameraPicker;
- (void)documentPicker:(UIDocumentPickerViewController*)controller
    didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls;
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController*)controller;
@end

@implementation NativeFileDialog

- (void)presentController:(UIViewController*)controller {
  UIViewController* presenter = _viewController;
  while (presenter.presentedViewController) {
    presenter = presenter.presentedViewController;
  }
  [presenter presentViewController:controller animated:YES completion:nil];
}

- (NSURL*)temporaryURLForFilename:(NSString*)filename {
  NSString* safeName = filename.length ? filename : @"upload";
  NSString* directory = [NSTemporaryDirectory()
      stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
  if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:nil]) {
    return nil;
  }
  return [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:safeName]];
}

- (void)finishWithURLs:(NSArray<NSURL*>*)urls cancelled:(BOOL)cancelled {
  if (!_dialog) {
    return;
  }
  std::vector<base::FilePath> paths;
  for (NSURL* url in urls) {
    if (url.isFileURL) {
      paths.push_back(base::apple::NSStringToFilePath(url.path));
    }
  }
  _dialog->FileWasSelected(_allowMultipleFiles, cancelled, paths, 0);
}

- (instancetype)initWithDialog:(base::WeakPtr<ui::SelectFileDialogImpl>)dialog
                viewController:(UIViewController*)viewController
            allowMultipleFiles:(bool)allowMultipleFiles
               fileUTTypeLists:(NSArray*)fileUTTypeLists
          allowsOtherFileTypes:(bool)allowsOtherFileTypes
                   isDirectory:(bool)isDirectory
                      mediaOnly:(bool)mediaOnly
                useMediaCapture:(bool)useMediaCapture
                  acceptsImages:(bool)acceptsImages
                  acceptsVideos:(bool)acceptsVideos {
  if (!(self = [super init])) {
    return nil;
  }
  _dialog = dialog;
  _viewController = viewController;
  _allowMultipleFiles = allowMultipleFiles;
  _fileUTTypeLists = fileUTTypeLists;
  _allowsOtherFileTypes = allowsOtherFileTypes;
  _isDirectory = isDirectory;
  _mediaOnly = mediaOnly;
  _useMediaCapture = useMediaCapture;
  // If neither was constrained (e.g. a generic file input using `capture`),
  // default to allowing both so the camera UI still offers a shutter and a
  // record toggle, matching what a plain `<input type="file" capture>`
  // should do.
  _acceptsImages = acceptsImages || (!acceptsImages && !acceptsVideos);
  _acceptsVideos = acceptsVideos || (!acceptsImages && !acceptsVideos);
  return self;
}

- (void)dealloc {
  _documentPickerController.delegate = nil;
  _imagePickerController.delegate = nil;
  if (@available(iOS 14.0, *)) {
    _photoPickerController.delegate = nil;
  }
}

- (void)showFilePickerMenu {
  // A directory picker (webkitdirectory / upload-folder) has no media
  // affordance, so it always goes straight to Files.
  if (_isDirectory) {
    [self showDocumentPicker];
    return;
  }

  bool cameraAvailable = [UIImagePickerController
      isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera];

  // `<input capture>` is an explicit request to skip the chooser and go
  // straight to the camera, matching the HTML spec's intent for that
  // attribute (and how Reynard's 0.2.0 file-input support behaved).
  if (_useMediaCapture && _mediaOnly && cameraAvailable) {
    [self showCameraPicker];
    return;
  }

  // Otherwise mirror Safari/WebKit's own file-input sheet: offer every
  // source that can plausibly satisfy the accept type together — Take
  // Photo/Video, Photo Library, and Browse (Files) — rather than jumping
  // straight into just one of them. A plain `<input type="file">` with no
  // accept restriction gets all three; an `accept="image/*"` input still
  // gets all three but the camera and Photos steps are scoped to images.
  NSMutableArray<UIAlertAction*>* actions = [NSMutableArray array];
  __weak NativeFileDialog* weakSelf = self;

  if (cameraAvailable) {
    NSString* cameraTitle = (_acceptsImages && !_acceptsVideos)
                                ? @"Take Photo"
                                : (!_acceptsImages && _acceptsVideos)
                                      ? @"Take Video"
                                      : @"Take Photo or Video";
    [actions addObject:[UIAlertAction actionWithTitle:cameraTitle
                                                style:UIAlertActionStyleDefault
                                              handler:^(UIAlertAction*) {
                                                [weakSelf showCameraPicker];
                                              }]];
  }

  [actions addObject:[UIAlertAction actionWithTitle:@"Photo Library"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction*) {
                                              [weakSelf showPhotoPicker];
                                            }]];

  [actions addObject:[UIAlertAction actionWithTitle:@"Browse…"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction*) {
                                              [weakSelf showDocumentPicker];
                                            }]];

  [actions addObject:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction*) {
                                              [weakSelf finishWithURLs:@[]
                                                             cancelled:YES];
                                            }]];

  UIAlertController* sheet =
      [UIAlertController alertControllerWithTitle:nil
                                           message:nil
                                    preferredStyle:UIAlertControllerStyleActionSheet];
  for (UIAlertAction* action in actions) {
    [sheet addAction:action];
  }

  // Action sheets on iPad must be anchored to a source view/rect or UIKit
  // will throw at presentation time.
  UIViewController* presenter = _viewController;
  while (presenter.presentedViewController) {
    presenter = presenter.presentedViewController;
  }
  sheet.popoverPresentationController.sourceView = presenter.view;
  sheet.popoverPresentationController.sourceRect =
      CGRectMake(CGRectGetMidX(presenter.view.bounds),
                 CGRectGetMaxY(presenter.view.bounds), 1, 1);
  sheet.popoverPresentationController.permittedArrowDirections = 0;

  [self presentController:sheet];
}

- (void)showDocumentPicker {
  if (@available(iOS 14.0, *)) {
    NSArray* documentTypes = _isDirectory ? @[ UTTypeFolder ] : @[ UTTypeItem ];
    if (!_isDirectory && !_allowsOtherFileTypes) {
      documentTypes = _fileUTTypeLists;
    }
    _documentPickerController = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:documentTypes];
  } else {
    NSArray* documentTypes = _isDirectory
                                 ? @[ (__bridge NSString*)kUTTypeFolder ]
                                 : @[ (__bridge NSString*)kUTTypeItem ];
    if (!_isDirectory && !_allowsOtherFileTypes) {
      documentTypes = _fileUTTypeLists;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    _documentPickerController = [[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:documentTypes
                       inMode:UIDocumentPickerModeOpen];
#pragma clang diagnostic pop
  }
  _documentPickerController.allowsMultipleSelection = _allowMultipleFiles;

  _documentPickerController.delegate = self;

  [self presentController:_documentPickerController];
}

- (NSArray*)legacyMediaTypesForCurrentAccept {
  // Only offer the media kinds the <input accept> actually allows; a picker
  // whose mediaTypes includes a kind the page can't use just wastes a step
  // (photo picked -> page rejects it) or, worse, silently swaps in the wrong
  // capture UI (camera opens in video mode for an image-only input).
  NSMutableArray* types = [NSMutableArray array];
  if (_acceptsImages) {
    [types addObject:(__bridge NSString*)kUTTypeImage];
  }
  if (_acceptsVideos) {
    [types addObject:(__bridge NSString*)kUTTypeMovie];
  }
  if (!types.count) {
    [types addObject:(__bridge NSString*)kUTTypeImage];
  }
  return types;
}

- (void)showPhotoPicker {
  if (@available(iOS 14.0, *)) {
    PHPickerConfiguration* configuration =
        [[PHPickerConfiguration alloc] initWithPhotoLibrary:
                                           [PHPhotoLibrary sharedPhotoLibrary]];
    if (_acceptsImages && _acceptsVideos) {
      configuration.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[
        PHPickerFilter.imagesFilter, PHPickerFilter.videosFilter
      ]];
    } else if (_acceptsVideos) {
      configuration.filter = PHPickerFilter.videosFilter;
    } else {
      configuration.filter = PHPickerFilter.imagesFilter;
    }
    configuration.selectionLimit = _allowMultipleFiles ? 0 : 1;
    _photoPickerController =
        [[PHPickerViewController alloc] initWithConfiguration:configuration];
    _photoPickerController.delegate = self;
    [self presentController:_photoPickerController];
    return;
  }

  _imagePickerController = [[UIImagePickerController alloc] init];
  _imagePickerController.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
  _imagePickerController.mediaTypes = [self legacyMediaTypesForCurrentAccept];
  _imagePickerController.delegate = self;
  [self presentController:_imagePickerController];
}

- (void)showCameraPicker {
  _imagePickerController = [[UIImagePickerController alloc] init];
  _imagePickerController.sourceType = UIImagePickerControllerSourceTypeCamera;
  // Respect the accept type: an image-only input should launch straight into
  // the still-photo shutter with no way to flip into video (and vice versa
  // for a video-only input). Previously this always advertised both image
  // and movie UTIs, so the camera sheet showed a photo/video mode toggle
  // regardless of what the page asked for.
  _imagePickerController.mediaTypes = [self legacyMediaTypesForCurrentAccept];
  _imagePickerController.cameraCaptureMode =
      (!_acceptsImages && _acceptsVideos)
          ? UIImagePickerControllerCameraCaptureModeVideo
          : UIImagePickerControllerCameraCaptureModePhoto;
  _imagePickerController.delegate = self;
  [self presentController:_imagePickerController];
}

- (void)documentPicker:(UIDocumentPickerViewController*)controller
    didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
  [self finishWithURLs:urls cancelled:NO];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController*)controller {
  [self finishWithURLs:@[] cancelled:YES];
}

- (void)imagePickerController:(UIImagePickerController*)picker
    didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id>*)info {
  NSURL* mediaURL = info[UIImagePickerControllerMediaURL];
  NSURL* resultURL = nil;
  if (mediaURL) {
    resultURL = [self temporaryURLForFilename:mediaURL.lastPathComponent];
    if (resultURL) {
      [[NSFileManager defaultManager] copyItemAtURL:mediaURL
                                              toURL:resultURL
                                              error:nil];
    }
  } else {
    UIImage* image = info[UIImagePickerControllerOriginalImage];
    NSData* data = UIImageJPEGRepresentation(image, 0.92);
    resultURL = [self temporaryURLForFilename:@"photo.jpg"];
    if (![data writeToURL:resultURL atomically:YES]) {
      resultURL = nil;
    }
  }
  [picker dismissViewControllerAnimated:YES completion:nil];
  [self finishWithURLs:resultURL ? @[ resultURL ] : @[]
               cancelled:resultURL == nil];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController*)picker {
  [picker dismissViewControllerAnimated:YES completion:nil];
  [self finishWithURLs:@[] cancelled:YES];
}

- (void)picker:(PHPickerViewController*)picker
    didFinishPicking:(NSArray<PHPickerResult*>*)results API_AVAILABLE(ios(14)) {
  [picker dismissViewControllerAnimated:YES completion:nil];
  if (!results.count) {
    [self finishWithURLs:@[] cancelled:YES];
    return;
  }

  dispatch_group_t group = dispatch_group_create();
  NSMutableArray<NSURL*>* copiedURLs = [NSMutableArray array];
  for (PHPickerResult* result in results) {
    NSItemProvider* provider = result.itemProvider;
    NSString* type = provider.registeredTypeIdentifiers.firstObject;
    if (!type) {
      continue;
    }
    dispatch_group_enter(group);
    [provider loadFileRepresentationForTypeIdentifier:type
                                    completionHandler:^(NSURL* url, NSError*) {
      if (url) {
        NSURL* destination = [self temporaryURLForFilename:url.lastPathComponent];
        if (destination && [[NSFileManager defaultManager] copyItemAtURL:url
                                                                   toURL:destination
                                                                   error:nil]) {
          @synchronized(copiedURLs) {
            [copiedURLs addObject:destination];
          }
        }
      }
      dispatch_group_leave(group);
    }];
  }
  dispatch_group_notify(group, dispatch_get_main_queue(), ^{
    [self finishWithURLs:copiedURLs cancelled:copiedURLs.count == 0];
  });
}

@end

namespace ui {

SelectFileDialogImpl::SelectFileDialogImpl(
    Listener* listener,
    std::unique_ptr<ui::SelectFilePolicy> policy)
    : SelectFileDialog(listener, std::move(policy)) {}

bool SelectFileDialogImpl::IsRunning(gfx::NativeWindow parent_window) const {
  return listener_;
}

void SelectFileDialogImpl::ListenerDestroyed() {
  listener_ = nullptr;
}

void SelectFileDialogImpl::FileWasSelected(
    bool is_multi,
    bool was_cancelled,
    const std::vector<base::FilePath>& files,
    int index) {
  if (!listener_) {
    return;
  }

  if (was_cancelled || files.empty()) {
    listener_->FileSelectionCanceled();
  } else {
    if (is_multi) {
      listener_->MultiFilesSelected(FilePathListToSelectedFileInfoList(files));
    } else {
      listener_->FileSelected(SelectedFileInfo(files[0]), index);
    }
  }
}

void SelectFileDialogImpl::SelectFileImpl(
    SelectFileDialog::Type type,
    const std::u16string& title,
    const base::FilePath& default_path,
    const FileTypeInfo* file_types,
    int file_type_index,
    const base::FilePath::StringType& default_extension,
    gfx::NativeWindow gfx_window,
    const GURL* caller) {
  has_multiple_file_type_choices_ =
      SelectFileDialog::SELECT_OPEN_MULTI_FILE == type;
  bool allows_other_file_types = false;
  bool media_only = !file_types->accept_types.empty();
  bool directory = SelectFileDialog::SELECT_FOLDER == type ||
                   SelectFileDialog::SELECT_UPLOAD_FOLDER == type ||
                   SelectFileDialog::SELECT_EXISTING_FOLDER == type;
  NSMutableArray* file_uttype_lists = [NSMutableArray array];
  for (const auto& ext_list : file_types->extensions) {
    for (const base::FilePath::StringType& ext : ext_list) {
      id uttype = nil;
      if (@available(iOS 14.0, *)) {
        uttype =
            [UTType typeWithFilenameExtension:base::SysUTF8ToNSString(ext)];
      } else {
        base::apple::ScopedCFTypeRef<CFStringRef> legacy_uttype(
            UTTypeCreatePreferredIdentifierForTag(
                kUTTagClassFilenameExtension,
                base::SysUTF8ToCFStringRef(ext).get(), nullptr));
        uttype = (__bridge NSString*)legacy_uttype.get();
      }
      if (!uttype) {
        continue;
      }

      if (![file_uttype_lists containsObject:uttype]) {
        [file_uttype_lists addObject:uttype];
      }
    }
  }
  for (const std::u16string& accept : file_types->accept_types) {
    std::string token = base::UTF16ToUTF8(accept);
    if (!base::StartsWith(token, "image/", base::CompareCase::INSENSITIVE_ASCII) &&
        !base::StartsWith(token, "video/", base::CompareCase::INSENSITIVE_ASCII)) {
      // Extension-only media accepts are handled by UTType conformance below.
      if (token.empty() || token.front() != '.') {
        media_only = false;
      }
    }
  }
  if (media_only && !file_uttype_lists.count) {
    media_only = false;
  }
  if (media_only) {
    for (id file_type in file_uttype_lists) {
      bool is_media = false;
      if (@available(iOS 14.0, *)) {
        UTType* ut = (UTType*)file_type;
        is_media = [ut conformsToType:UTTypeImage] ||
                   [ut conformsToType:UTTypeMovie];
      } else {
        CFStringRef ut = (__bridge CFStringRef)file_type;
        is_media = UTTypeConformsTo(ut, kUTTypeImage) ||
                   UTTypeConformsTo(ut, kUTTypeMovie);
      }
      if (!is_media) {
        media_only = false;
        break;
      }
    }
  }
  if (file_types->include_all_files || file_types->extensions.empty()) {
    allows_other_file_types = true;
  }

  // Work out which of image/video the accept list actually admits, so the
  // camera and Photos pickers can be scoped to match instead of always
  // offering both (see NativeFileDialog's legacyMediaTypesForCurrentAccept
  // and the PHPickerFilter selection in showPhotoPicker).
  bool accepts_images = false;
  bool accepts_videos = false;
  for (const std::u16string& accept : file_types->accept_types) {
    std::string token = base::UTF16ToUTF8(accept);
    if (base::StartsWith(token, "image/",
                          base::CompareCase::INSENSITIVE_ASCII)) {
      accepts_images = true;
    } else if (base::StartsWith(token, "video/",
                                base::CompareCase::INSENSITIVE_ASCII)) {
      accepts_videos = true;
    }
  }
  if (media_only && !accepts_images && !accepts_videos) {
    // No image/* or video/* MIME accept was given, but every extension in
    // the accept list happens to be a media UTType (e.g. accept=".png"):
    // inspect the resolved UTTypes themselves.
    for (id file_type in file_uttype_lists) {
      if (@available(iOS 14.0, *)) {
        UTType* ut = (UTType*)file_type;
        accepts_images |= [ut conformsToType:UTTypeImage] == YES;
        accepts_videos |= [ut conformsToType:UTTypeMovie] == YES;
      } else {
        CFStringRef ut = (__bridge CFStringRef)file_type;
        accepts_images |= UTTypeConformsTo(ut, kUTTypeImage);
        accepts_videos |= UTTypeConformsTo(ut, kUTTypeMovie);
      }
    }
  }

  UIViewController* controller = gfx_window.Get().rootViewController;
  native_file_dialog_ =
      [[NativeFileDialog alloc] initWithDialog:weak_factory_.GetWeakPtr()
                                viewController:controller
                            allowMultipleFiles:has_multiple_file_type_choices_
                               fileUTTypeLists:file_uttype_lists
                          allowsOtherFileTypes:allows_other_file_types
                                   isDirectory:directory
                                      mediaOnly:media_only
                                useMediaCapture:file_types->use_media_capture
                                  acceptsImages:accepts_images
                                  acceptsVideos:accepts_videos];
  [native_file_dialog_ showFilePickerMenu];
}

SelectFileDialogImpl::~SelectFileDialogImpl() {
  // Clear |weak_factory_| beforehand, to ensure that no callbacks will be made
  // when we cancel the NSSavePanels.
  weak_factory_.InvalidateWeakPtrs();
}

bool SelectFileDialogImpl::HasMultipleFileTypeChoicesImpl() {
  return has_multiple_file_type_choices_;
}

SelectFileDialog* CreateSelectFileDialog(
    SelectFileDialog::Listener* listener,
    std::unique_ptr<SelectFilePolicy> policy) {
  return new SelectFileDialogImpl(listener, std::move(policy));
}

}  // namespace ui
