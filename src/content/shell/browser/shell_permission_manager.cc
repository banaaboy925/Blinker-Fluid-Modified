// Copyright 2015 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/shell_permission_manager.h"

#include "base/barrier_closure.h"
#include "base/command_line.h"
#include "base/functional/bind.h"
#include "base/functional/callback.h"
#include "base/memory/ref_counted.h"
#include "components/content_settings/core/common/features.h"
#include "components/permissions/permission_util.h"
#include "content/public/browser/permission_controller.h"
#include "content/public/browser/permission_result.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/common/content_switches.h"
#include "content/shell/common/shell_switches.h"
#include "media/base/media_switches.h"
#include "third_party/blink/public/common/features.h"
#include "third_party/blink/public/common/permissions/permission_utils.h"
#include "url/origin.h"

using blink::PermissionType;

#if BUILDFLAG(IS_IOS)
extern "C" int BlinkIOSSystemPermissionStatus(int permission);
// Triggers the actual iOS "<App> Would Like to Access the Camera/Microphone"
// system prompt for AVCaptureDevice permission 1 (mic) or 2 (camera) when its
// authorization status is still "not determined", i.e. the first time any
// site asks for it. `on_result` is invoked (on the main/UI thread) with 1 if
// the person allowed it and 0 otherwise. If the status is already settled
// (previously allowed or denied in iOS Settings) this resolves immediately
// with that existing answer instead of re-prompting.
extern "C" void BlinkIOSRequestSystemPermission(int permission,
                                                 void (*on_result)(void*,
                                                                   int),
                                                 void* context);
#endif

namespace content {

namespace {

bool IsAllowlistedPermissionType(PermissionType permission) {
  switch (permission) {
    case PermissionType::GEOLOCATION:
    case PermissionType::GEOLOCATION_APPROXIMATE:
#if BUILDFLAG(IS_IOS)
      return BlinkIOSSystemPermissionStatus(0) != 0;
#else
      return true;
#endif
    case PermissionType::SENSORS:
    case PermissionType::PAYMENT_HANDLER:
    case PermissionType::WAKE_LOCK_SCREEN:

    // Background Sync and Background Fetch browser tests require
    // permission to be granted by default.
    case PermissionType::BACKGROUND_SYNC:
    case PermissionType::BACKGROUND_FETCH:
    case PermissionType::PERIODIC_BACKGROUND_SYNC:

    case PermissionType::IDLE_DETECTION:

    // WebNFC browser tests require permission to be granted by default.
    case PermissionType::NFC:
      return true;

    case PermissionType::MIDI:
      if (base::FeatureList::IsEnabled(blink::features::kBlockMidiByDefault)) {
        return false;
      }
      return true;
    case PermissionType::MIDI_SYSEX:
    case PermissionType::NOTIFICATIONS:
    case PermissionType::PROTECTED_MEDIA_IDENTIFIER:
    case PermissionType::PERSISTENT_STORAGE:
    case PermissionType::AUDIO_CAPTURE:
#if BUILDFLAG(IS_IOS)
      return BlinkIOSSystemPermissionStatus(1) != 0;
#else
      return false;
#endif
    case PermissionType::VIDEO_CAPTURE:
#if BUILDFLAG(IS_IOS)
      return BlinkIOSSystemPermissionStatus(2) != 0;
#else
      return false;
#endif
    case PermissionType::CLIPBOARD_READ_WRITE:
    case PermissionType::CLIPBOARD_SANITIZED_WRITE:
    case PermissionType::NUM:
    case PermissionType::WAKE_LOCK_SYSTEM:
    case PermissionType::HAND_TRACKING:
    case PermissionType::VR:
    case PermissionType::AR:
    case PermissionType::STORAGE_ACCESS_GRANT:
    case PermissionType::CAMERA_PAN_TILT_ZOOM:
    case PermissionType::WINDOW_MANAGEMENT:
    case PermissionType::LOCAL_FONTS:
    case PermissionType::DISPLAY_CAPTURE:
    case PermissionType::TOP_LEVEL_STORAGE_ACCESS:
    case PermissionType::CAPTURED_SURFACE_CONTROL:
    case PermissionType::SMART_CARD:
    case PermissionType::WEB_PRINTING:
    case PermissionType::SPEAKER_SELECTION:
    case PermissionType::KEYBOARD_LOCK:
    case PermissionType::POINTER_LOCK:
    case PermissionType::AUTOMATIC_FULLSCREEN:
    case PermissionType::WEB_APP_INSTALLATION:
    case PermissionType::LOCAL_NETWORK_ACCESS:
    case PermissionType::LOCAL_NETWORK:
    case PermissionType::LOOPBACK_NETWORK:
      return false;
  }

  NOTREACHED();
}

}  // namespace

ShellPermissionManager::ShellPermissionManager() = default;

ShellPermissionManager::~ShellPermissionManager() = default;


void ShellPermissionManager::ResetPermission(
    PermissionType permission,
    const GURL& requesting_origin,
    const GURL& embedding_origin) {
}

#if BUILDFLAG(IS_IOS)
namespace {

// Shared state for a RequestPermissionsFromCurrentDocument() call that has
// one or more pending async AVCaptureDevice prompts in flight (e.g. a
// `getUserMedia({audio: true, video: true})` call, which should show a
// single logical "allow this site to use your camera and microphone"
// decision even though iOS itself prompts once per media type).
struct PendingMediaPermissionRequest
    : public base::RefCountedThreadSafe<PendingMediaPermissionRequest> {
  std::vector<PermissionResult> result;
  base::OnceCallback<void(const std::vector<PermissionResult>&)> callback;

 private:
  friend class base::RefCountedThreadSafe<PendingMediaPermissionRequest>;
  ~PendingMediaPermissionRequest() = default;
};

// Bridges the C-ABI `BlinkIOSRequestSystemPermission` callback back into a
// base::OnceClosure. Allocated on the heap and owned by the trampoline: it
// is always exactly-once invoked and deleted by OnSystemPermissionTrampoline.
void OnSystemPermissionTrampoline(void* context, int granted) {
  auto* callback =
      static_cast<base::OnceCallback<void(bool)>*>(context);
  std::unique_ptr<base::OnceCallback<void(bool)>> owned(callback);
  std::move(*owned).Run(granted != 0);
}

void RequestSystemPermissionAsync(int permission,
                                   base::OnceCallback<void(bool)> callback) {
  auto* heap_callback =
      new base::OnceCallback<void(bool)>(std::move(callback));
  BlinkIOSRequestSystemPermission(permission, &OnSystemPermissionTrampoline,
                                  heap_callback);
}

}  // namespace
#endif  // BUILDFLAG(IS_IOS)

void ShellPermissionManager::RequestPermissionsFromCurrentDocument(
    content::RenderFrameHost* render_frame_host,
    const PermissionRequestDescription& request_description,
    base::OnceCallback<void(const std::vector<PermissionResult>&)> callback) {
  if (render_frame_host->IsNestedWithinFencedFrame()) {
    std::move(callback).Run(std::vector<PermissionResult>(
        request_description.permissions.size(),
        PermissionResult(blink::mojom::PermissionStatus::DENIED)));
    return;
  }

#if BUILDFLAG(IS_IOS)
  // Camera/microphone need special handling on iOS: the first time a site
  // asks (system authorization status "not determined"), we must actually
  // trigger the system "Allow <App> to access the Camera/Microphone" prompt
  // instead of just reporting DENIED, or getUserMedia() would always fail on
  // a device's very first use of the camera or mic from any website.
  std::vector<bool> needs_system_prompt(request_description.permissions.size(),
                                        false);
  bool any_needs_prompt = false;
  for (size_t i = 0; i < request_description.permissions.size(); ++i) {
    blink::PermissionType type = blink::PermissionDescriptorToPermissionType(
        request_description.permissions[i]);
    if (type != PermissionType::AUDIO_CAPTURE &&
        type != PermissionType::VIDEO_CAPTURE) {
      continue;
    }
    int system_permission = type == PermissionType::AUDIO_CAPTURE ? 1 : 2;
    if (!BlinkIOSSystemPermissionStatus(system_permission)) {
      // Not currently authorized. That's either "not determined" (worth
      // prompting) or "denied/restricted" (prompting would be a no-op, iOS
      // just re-reports denied); either way it's safe to route through the
      // same async prompt path and let AVFoundation decide.
      needs_system_prompt[i] = true;
      any_needs_prompt = true;
    }
  }

  if (any_needs_prompt) {
    auto request = base::MakeRefCounted<PendingMediaPermissionRequest>();
    request->result.resize(request_description.permissions.size(),
                            PermissionResult(
                                blink::mojom::PermissionStatus::DENIED));
    request->callback = std::move(callback);

    base::RepeatingClosure barrier = base::BarrierClosure(
        request_description.permissions.size(),
        base::BindOnce(
            [](scoped_refptr<PendingMediaPermissionRequest> request) {
              std::move(request->callback).Run(request->result);
            },
            request));

    for (size_t i = 0; i < request_description.permissions.size(); ++i) {
      blink::PermissionType type = blink::PermissionDescriptorToPermissionType(
          request_description.permissions[i]);
      if (!needs_system_prompt[i]) {
        request->result[i] = PermissionResult(
            IsAllowlistedPermissionType(type)
                ? blink::mojom::PermissionStatus::GRANTED
                : blink::mojom::PermissionStatus::DENIED);
        barrier.Run();
        continue;
      }
      int system_permission = type == PermissionType::AUDIO_CAPTURE ? 1 : 2;
      RequestSystemPermissionAsync(
          system_permission,
          base::BindOnce(
              [](scoped_refptr<PendingMediaPermissionRequest> request,
                 size_t index, base::RepeatingClosure barrier, bool granted) {
                request->result[index] = PermissionResult(
                    granted ? blink::mojom::PermissionStatus::GRANTED
                            : blink::mojom::PermissionStatus::DENIED);
                barrier.Run();
              },
              request, i, barrier));
    }
    return;
  }
#endif  // BUILDFLAG(IS_IOS)

  std::vector<PermissionResult> result;
  blink::PermissionType permission_type;
  for (const auto& permission : request_description.permissions) {
    permission_type = blink::PermissionDescriptorToPermissionType(permission);
    // When the `ApproximateGeolocationPermission` feature is enabled, granting
    // geolocation requires more granular control via `GeolocationSetting`.
    if (base::FeatureList::IsEnabled(
            content_settings::features::kApproximateGeolocationPermission) &&
        permission_type == blink::PermissionType::GEOLOCATION &&
        IsAllowlistedPermissionType(permission_type)) {
      GeolocationSetting setting = {PermissionOption::kAllowed,
                                    PermissionOption::kAllowed};
      result.emplace_back(blink::mojom::PermissionStatus::GRANTED,
                          PermissionStatusSource::UNSPECIFIED, setting);
    } else {
      result.emplace_back(IsAllowlistedPermissionType(permission_type)
                              ? blink::mojom::PermissionStatus::GRANTED
                              : blink::mojom::PermissionStatus::DENIED);
    }
  }
  std::move(callback).Run(result);
}

blink::mojom::PermissionStatus ShellPermissionManager::GetPermissionStatus(
    const blink::mojom::PermissionDescriptorPtr& permission_descriptor,
    const GURL& requesting_origin,
    const GURL& embedding_origin) {
  base::CommandLine* command_line = base::CommandLine::ForCurrentProcess();
  const auto permission_type =
      blink::PermissionDescriptorToPermissionType(permission_descriptor);

  if ((permission_type == PermissionType::AUDIO_CAPTURE ||
       permission_type == PermissionType::VIDEO_CAPTURE) &&
      command_line->HasSwitch(switches::kUseFakeDeviceForMediaStream) &&
      command_line->HasSwitch(switches::kUseFakeUIForMediaStream) &&
      command_line->GetSwitchValueASCII(
          switches::kUseFakeDeviceForMediaStream) != "deny") {
    return blink::mojom::PermissionStatus::GRANTED;
  }

  return IsAllowlistedPermissionType(permission_type)
             ? blink::mojom::PermissionStatus::GRANTED
             : blink::mojom::PermissionStatus::DENIED;
}

PermissionResult
ShellPermissionManager::GetPermissionResultForOriginWithoutContext(
    const blink::mojom::PermissionDescriptorPtr& permission_descriptor,
    const url::Origin& requesting_origin,
    const url::Origin& embedding_origin) {
  blink::mojom::PermissionStatus status =
      GetPermissionStatus(permission_descriptor, requesting_origin.GetURL(),
                          embedding_origin.GetURL());

  return PermissionResult(status);
}

PermissionResult ShellPermissionManager::GetPermissionResultForCurrentDocument(
    const blink::mojom::PermissionDescriptorPtr& permission_descriptor,
    content::RenderFrameHost* render_frame_host,
    bool should_include_device_status) {
  if (render_frame_host->IsNestedWithinFencedFrame())
    return PermissionResult(blink::mojom::PermissionStatus::DENIED);
  return PermissionResult(GetPermissionStatus(
      permission_descriptor,
      permissions::PermissionUtil::GetLastCommittedOriginAsURL(
          render_frame_host),
      permissions::PermissionUtil::GetLastCommittedOriginAsURL(
          render_frame_host->GetMainFrame())));
}

PermissionResult ShellPermissionManager::GetPermissionResultForWorker(
    const blink::mojom::PermissionDescriptorPtr& permission_descriptor,
    content::RenderProcessHost* render_process_host,
    const GURL& worker_origin) {
  return PermissionResult(
      GetPermissionStatus(permission_descriptor, worker_origin, worker_origin));
}

PermissionResult
ShellPermissionManager::GetPermissionResultForEmbeddedRequester(
    const blink::mojom::PermissionDescriptorPtr& permission_descriptor,
    content::RenderFrameHost* render_frame_host,
    const url::Origin& overridden_origin) {
  if (render_frame_host->IsNestedWithinFencedFrame()) {
    return PermissionResult(blink::mojom::PermissionStatus::DENIED);
  }
  return PermissionResult(GetPermissionStatus(
      permission_descriptor, overridden_origin.GetURL(),
      permissions::PermissionUtil::GetLastCommittedOriginAsURL(
          render_frame_host->GetMainFrame())));
}

}  // namespace content
