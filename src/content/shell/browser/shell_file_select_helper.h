// Copyright 2026 The Blinker Fluid Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// ShellFileSelectHelper presents the native iOS UI for HTML <input
// type="file"> elements: an action sheet offering "Take Photo or Video",
// "Photo Library", and "Browse" (Files app / document providers), or (when
// the `capture` attribute is present) jumping straight to the camera.
//
// It honors blink::mojom::FileChooserParams::accept_types so that, e.g.,
// accept="image/*" only offers photo capture / image picking, and
// accept="video/*" only offers video capture / video picking -- matching
// the fix shipped in reynard-browser 0.4.0 ("Fixed an issue where opening
// the camera for file input would always allow both video recording and
// image capture instead of respecting the accepted file types").

#ifndef CONTENT_SHELL_BROWSER_SHELL_FILE_SELECT_HELPER_H_
#define CONTENT_SHELL_BROWSER_SHELL_FILE_SELECT_HELPER_H_

#include "base/memory/scoped_refptr.h"
#include "content/public/browser/file_select_listener.h"
#include "content/public/browser/render_frame_host.h"
#include "third_party/blink/public/mojom/choosers/file_chooser.mojom.h"

namespace content {

class ShellFileSelectHelper {
 public:
  ShellFileSelectHelper() = delete;
  ShellFileSelectHelper(const ShellFileSelectHelper&) = delete;
  ShellFileSelectHelper& operator=(const ShellFileSelectHelper&) = delete;

  // Presents the appropriate native picker for `params` and reports the
  // result back to `listener`. Safe to call from the UI thread only.
  static void RunFileChooser(RenderFrameHost* render_frame_host,
                              scoped_refptr<FileSelectListener> listener,
                              const blink::mojom::FileChooserParams& params);
};

}  // namespace content

#endif  // CONTENT_SHELL_BROWSER_SHELL_FILE_SELECT_HELPER_H_
