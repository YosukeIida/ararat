#include "ararat/core/ararat_capture.h"

#include <algorithm>
#include <cmath>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/base64.h"
#include "base/check.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/memory/weak_ptr.h"
#include "base/task/bind_post_task.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "base/values.h"
#include "components/viz/common/frame_sinks/copy_output_result.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/devtools_agent_host_client.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/visibility.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "third_party/blink/public/common/web_preferences/web_preferences.h"
#include "ui/gfx/codec/png_codec.h"
#include "ui/gfx/geometry/rect_conversions.h"
#include "ui/gfx/geometry/rect_f.h"

namespace {
using Completion = void (^)(NSData*, NSString*);
// Why not Chromium's 128K limit: compositor readback can tile before that limit; verify 16K in the VM.
constexpr uint32_t kMaxCaptureDimension = 16384;
constexpr uint32_t ReadDimension(const uint8_t* data) {
  return (uint32_t(data[0]) << 24) | (uint32_t(data[1]) << 16) |
         (uint32_t(data[2]) << 8) | uint32_t(data[3]);
}
constexpr uint8_t kDimensionCheck[] = {0, 0, 64, 0};
static_assert(ReadDimension(kDimensionCheck) == kMaxCaptureDimension);

class Capture : public content::WebContentsObserver,
                public content::DevToolsAgentHostClient {
 public:
  Capture(content::WebContents* contents, Completion completion)
      : content::WebContentsObserver(contents), completion_([completion copy]) {}
  ~Capture() override { Finish(nil, @"tabGone"); }

  bool done() const { return !completion_; }
  content::WebContents* contents() const { return web_contents(); }
  void Cancel(NSString* error) { Finish(nil, error); }

  void StartFullPage() {
    auto* contents = web_contents();
    auto* view = contents ? contents->GetRenderWidgetHostView() : nullptr;
    if (!contents || !view || contents->GetVisibility() != content::Visibility::VISIBLE) {
      Finish(nil, @"failed"); return;
    }
    if (content::DevToolsAgentHost::IsDebuggerAttached(contents)) {
      Finish(nil, @"devtoolsBusy"); return;
    }
    agent_ = content::DevToolsAgentHost::GetOrCreateFor(contents);
    if (!agent_ || agent_->IsAttached() || !agent_->AttachClient(this)) {
      agent_ = nullptr;
      Finish(nil, @"devtoolsBusy"); return;
    }
    attached_ = true;
    constexpr char command[] = R"({"id":1,"method":"Page.getLayoutMetrics"})";
    agent_->DispatchProtocolMessage(this, base::as_byte_span(std::string_view(command)));
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
        FROM_HERE, base::BindOnce(&Capture::Timeout, weak_.GetWeakPtr()), base::Seconds(30));
  }

  void StartRegion(NSRect region) {
    auto* contents = web_contents();
    auto* view = contents ? contents->GetRenderWidgetHostView() : nullptr;
    if (!view || !view->IsSurfaceAvailableForCopy() ||
        !std::isfinite(region.origin.x) || !std::isfinite(region.origin.y) ||
        !std::isfinite(region.size.width) || !std::isfinite(region.size.height) ||
        region.size.width <= 0 || region.size.height <= 0) {
      Finish(nil, @"failed"); return;
    }
    NSRect bounds = NSMakeRect(0, 0, view->GetViewBounds().width(), view->GetViewBounds().height());
    NSRect clipped = NSIntersectionRect(region, bounds);
    if (NSIsEmptyRect(clipped)) { Finish(nil, @"failed"); return; }
    gfx::Rect source = gfx::ToEnclosingRect(gfx::RectF(
        clipped.origin.x, clipped.origin.y, clipped.size.width, clipped.size.height));
    source.Intersect(gfx::Rect(view->GetViewBounds().size()));
    if (source.IsEmpty()) { Finish(nil, @"failed"); return; }
    DCHECK(gfx::Rect(view->GetViewBounds().size()).Contains(source));
    view->CopyFromSurface(source, gfx::Size(), base::Seconds(10),
        base::BindPostTask(base::SingleThreadTaskRunner::GetCurrentDefault(),
                           base::BindOnce(&Capture::RegionDone, weak_.GetWeakPtr())));
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
        FROM_HERE, base::BindOnce(&Capture::Timeout, weak_.GetWeakPtr()), base::Seconds(15));
  }

  void DidFinishNavigation(content::NavigationHandle* navigation) override {
    if (navigation->IsInPrimaryMainFrame() && navigation->HasCommitted() && !navigation->IsSameDocument())
      Finish(nil, @"navigated");
  }
  void WebContentsDestroyed() override { Finish(nil, @"tabGone"); }
  bool IsTrusted() override { return true; }
  void AgentHostClosed(content::DevToolsAgentHost*) override {
    attached_ = false;
    Finish(nil, web_contents() ? @"failed" : @"tabGone");
  }
  void DispatchProtocolMessage(content::DevToolsAgentHost*, base::span<const uint8_t> message) override {
    std::string json(reinterpret_cast<const char*>(message.data()), message.size());
    auto parsed = base::JSONReader::ReadDict(json, base::JSON_PARSE_CHROMIUM_EXTENSIONS);
    if (!parsed) return;
    auto id = parsed->FindInt("id");
    if (id == 1) {
      const auto* result = parsed->FindDict("result");
      const auto* size = result ? result->FindDict("contentSize") : nullptr;
      auto width = size ? size->FindDouble("width") : std::nullopt;
      auto height = size ? size->FindDouble("height") : std::nullopt;
      if (!width || !height || !std::isfinite(*width) || !std::isfinite(*height) || *width <= 0 || *height <= 0) {
        base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
            FROM_HERE, base::BindOnce(&Capture::Finish, weak_.GetWeakPtr(), nil, @"failed"));
      } else if (*width > kMaxCaptureDimension || *height > kMaxCaptureDimension) {
        base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
            FROM_HERE, base::BindOnce(&Capture::Finish, weak_.GetWeakPtr(), nil, @"tooLarge"));
      } else {
        base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
            FROM_HERE, base::BindOnce(&Capture::RequestScreenshot, weak_.GetWeakPtr()));
      }
      return;
    }
    if (id != 2) return;
    full_page_ = false;
    NSString* error = @"failed";
    NSData* data = nil;
    if (const auto* result = parsed->FindDict("result")) {
      if (const auto* encoded = result->FindString("data")) {
        auto bytes = base::Base64Decode(*encoded);
        constexpr uint8_t signature[] = {137, 80, 78, 71, 13, 10, 26, 10};
        if (bytes && bytes->size() >= 24 &&
            std::equal(std::begin(signature), std::end(signature), bytes->begin()) &&
            (*bytes)[12] == 'I' && (*bytes)[13] == 'H' && (*bytes)[14] == 'D' && (*bytes)[15] == 'R') {
          uint32_t width = ReadDimension(bytes->data() + 16);
          uint32_t height = ReadDimension(bytes->data() + 20);
          if (width > kMaxCaptureDimension || height > kMaxCaptureDimension) error = @"tooLarge";
          else if (width && height) data = [NSData dataWithBytes:bytes->data() length:bytes->size()];
        }
      }
    } else if (const auto* failure = parsed->FindDict("error")) {
      const auto* text = failure->FindString("message");
      if (text && *text == "Page is too large.") error = @"tooLarge";
    }
    // The session cannot be detached while Chromium is delivering its reply.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&Capture::Finish, weak_.GetWeakPtr(), data, data ? nil : error));
  }

 private:
  void RequestScreenshot() {
    if (done()) return;
    auto* contents = web_contents();
    auto* view = contents ? contents->GetRenderWidgetHostView() : nullptr;
    if (!contents || !view || contents->GetVisibility() != content::Visibility::VISIBLE) {
      Finish(nil, @"failed"); return;
    }
    const auto& prefs = contents->GetOrCreateWebPreferences();
    original_hide_scrollbars_ = prefs.hide_scrollbars;
    original_whole_document_ = prefs.record_whole_document;
    original_size_ = view->GetViewBounds().size();
    full_page_ = true;
    constexpr char command[] = R"({"id":2,"method":"Page.captureScreenshot","params":{"format":"png","fromSurface":true,"captureBeyondViewport":true}})";
    agent_->DispatchProtocolMessage(this, base::as_byte_span(std::string_view(command)));
  }
  void RegionDone(const content::CopyFromSurfaceResult& result) {
    if (!result || result->bitmap.drawsNothing()) { Finish(nil, @"failed"); return; }
    auto png = gfx::PNGCodec::EncodeBGRASkBitmap(result->bitmap, false);
    if (!png || png->empty()) { Finish(nil, @"failed"); return; }
    Finish([NSData dataWithBytes:png->data() length:png->size()], nil);
  }
  void Timeout() { Finish(nil, @"failed"); }
  void Finish(NSData* data, NSString* error) {
    if (!completion_) return;
    Completion completion = completion_;
    completion_ = nil;
    if (attached_) {
      attached_ = false;
      agent_->DetachClient(this);
    }
    agent_ = nullptr;
    if (full_page_ && error && ![error isEqual:@"tooLarge"] && web_contents() && !web_contents()->IsBeingDestroyed()) {
      auto prefs = web_contents()->GetOrCreateWebPreferences();
      prefs.hide_scrollbars = original_hide_scrollbars_;
      prefs.record_whole_document = original_whole_document_;
      web_contents()->SetWebPreferences(prefs);
      if (auto* view = web_contents()->GetRenderWidgetHostView(); view && !original_size_.IsEmpty())
        view->SetSize(original_size_);
    }
    Observe(nullptr);
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(^{ completion(data, error); }));
  }
  Completion completion_;
  scoped_refptr<content::DevToolsAgentHost> agent_;
  gfx::Size original_size_;
  bool attached_ = false;
  bool full_page_ = false;
  bool original_hide_scrollbars_ = false;
  bool original_whole_document_ = false;
  base::WeakPtrFactory<Capture> weak_{this};
};
}  // namespace

@implementation ARCapture {
  std::unique_ptr<Capture> capture_;
}
- (void)selectContents:(content::WebContents*)contents {
  if (capture_ && !capture_->done() && capture_->contents() != contents)
    capture_->Cancel(@"navigated");
}
- (void)fullPage:(content::WebContents*)contents completion:(Completion)completion {
  if (capture_ && !capture_->done()) {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE, base::BindOnce(^{ completion(nil, @"devtoolsBusy"); })); return;
  }
  capture_ = std::make_unique<Capture>(contents, completion);
  capture_->StartFullPage();
}
- (void)region:(NSRect)rect contents:(content::WebContents*)contents completion:(Completion)completion {
  if (capture_ && !capture_->done()) {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE, base::BindOnce(^{ completion(nil, @"devtoolsBusy"); })); return;
  }
  capture_ = std::make_unique<Capture>(contents, completion);
  capture_->StartRegion(rect);
}
@end
