// Copyright 2026 The Blinker Fluid Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Shows the per-site "example.com Would Like to Access the Camera and
// Microphone" style prompt (mirroring Safari/Chrome's combined getUserMedia
// permission UI) before a website is allowed to use the camera and/or
// microphone, and reconciles that decision with the app's OS-level
// AVCaptureDevice authorization.
//
// This is distinct from the app-wide "Website Permissions" settings screen
// (which only reflects the *system* authorization for the app as a whole):
// this prompt is the per-origin decision a browser is expected to make
// every time a page calls getUserMedia({audio, video}).

#ifndef CONTENT_SHELL_BROWSER_SHELL_MEDIA_PERMISSION_PROMPT_IOS_H_
#define CONTENT_SHELL_BROWSER_SHELL_MEDIA_PERMISSION_PROMPT_IOS_H_

#include "base/functional/callback.h"
#include "url/gurl.h"

namespace content {

class ShellMediaPermissionPromptIOS {
 public:
  ShellMediaPermissionPromptIOS() = delete;

  // Result callback: (audio_granted, video_granted). Either may be true
  // independent of whether it was requested (unrequested types are always
  // reported as false).
  using ResultCallback = base::OnceCallback<void(bool audio_granted,
                                                   bool video_granted)>;

  // Requests site-level + system-level access for `origin`. If both
  // `want_audio` and `want_video` are true, a single combined prompt is
  // shown ("Camera and Microphone"), matching how Safari/Chrome present a
  // simultaneous audio+video getUserMedia() request. Must be called on the
  // UI thread.
  static void RequestAccess(const GURL& origin,
                             bool want_audio,
                             bool want_video,
                             ResultCallback callback);

  // Clears the in-memory per-origin decision cache (e.g. when clearing
  // browsing data). Does not affect OS-level authorization, which can only
  // be changed via iOS Settings.
  static void ClearCachedDecisions();
};

}  // namespace content

#endif  // CONTENT_SHELL_BROWSER_SHELL_MEDIA_PERMISSION_PROMPT_IOS_H_
