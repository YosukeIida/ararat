// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef ARARAT_ARARAT_EXTENSIONS_CONTAINER_H_
#define ARARAT_ARARAT_EXTENSIONS_CONTAINER_H_

#include <memory>
#include <optional>
#include <string>

#include "base/containers/flat_map.h"
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/scoped_observation.h"
#include "chrome/browser/ui/extensions/extensions_container.h"
#include "chrome/browser/ui/toolbar/toolbar_actions_model.h"
#include "chrome/browser/ui/views/extensions/extensions_container_views.h"
#include "ui/views/bubble/bubble_anchor.h"

// Based on Chromium's contextual_tasks/contextual_tasks_extensions_container.

class BrowserWindowInterface;
class ExtensionActionViewModel;
class ExtensionsMenuCoordinator;
class ToolbarActionViewModel;

namespace content {
class WebContents;
}  // namespace content

namespace ararat {

// Manages extension actions for an app Browser and its active WebContents.
class AraratExtensionsContainer
    : public ExtensionsContainer,
      public ExtensionsContainerViews,
      public ToolbarActionsModel::Observer {
 public:
  using AnchorProvider = base::RepeatingCallback<views::BubbleAnchor()>;

  AraratExtensionsContainer(BrowserWindowInterface* browser,
                                     content::WebContents* web_contents,
                                     AnchorProvider anchor_provider);
  AraratExtensionsContainer(
      const AraratExtensionsContainer&) = delete;
  AraratExtensionsContainer& operator=(
      const AraratExtensionsContainer&) = delete;
  ~AraratExtensionsContainer() override;

  // Shows the extensions menu, anchored to the anchor returned by the
  // container's `AnchorProvider`. Does nothing if there is no valid anchor.
  void ShowExtensionsMenu();

  // Returns whether the extensions menu is currently showing.
  bool IsExtensionsMenuShowing() const;

  // Updates the WebContents associated with this container.
  void SetWebContents(content::WebContents* web_contents);
  const auto& actions() const { return actions_; }
  void SetShortcutActive(bool active);

  // ExtensionsContainer:
  ToolbarActionViewModel* GetActionForId(const std::string& action_id) override;
  void HideActivePopup() override;
  void CloseExtensionsMenuIfOpen() override;
  bool ShowToolbarActionPopupForAPICall(const std::string& action_id,
                                        ShowPopupCallback callback) override;
  void ToggleExtensionsMenu() override;
  bool HasAnyExtensions() const override;
  content::WebContents* GetActiveWebContents() const override;

  // ExtensionsContainerViews:
  bool IsVisible() const override;
  std::optional<extensions::ExtensionId> GetPoppedOutActionId() const override;
  bool IsActionVisibleOnToolbar(const std::string& action_id) const override;
  void UndoPopOut() override;
  void SetPopupOwner(ToolbarActionViewModel* popup_owner) override;
  void PopOutAction(const extensions::ExtensionId& action_id,
                    base::OnceClosure closure) override;
  void ShowWidgetForExtension(views::Widget* widget,
                              const std::string& extension_id) override;
  void CollapseConfirmation() override;
  void ShowContextMenuAsFallback(
      const extensions::ExtensionId& action_id) override;
  void OnPopupShown(const extensions::ExtensionId& action_id,
                    bool by_user) override;
  void OnPopupClosed(const extensions::ExtensionId& action_id) override;
  views::FocusManager* GetFocusManagerForAccelerator() override;
  views::BubbleAnchor GetReferenceButtonForPopup(
      const extensions::ExtensionId& action_id) override;
  views::BubbleAnchor GetExtensionsButtonAnchor() override;
  views::BubbleBorder::Arrow GetPopupArrow() const override;

  // ToolbarActionsModel::Observer:
  void OnToolbarModelInitialized() override;
  void OnToolbarActionAdded(
      const ToolbarActionsModel::ActionId& action_id) override;
  void OnToolbarActionRemoved(
      const ToolbarActionsModel::ActionId& action_id) override;
  void OnToolbarActionUpdated(
      const ToolbarActionsModel::ActionId& action_id) override;
  void OnToolbarPinnedActionsChanged() override;
  void OnToolbarActionsModelShutdown() override;

 private:
  void CreateActions();
  void CreateActionForId(const ToolbarActionsModel::ActionId& action_id);

  views::BubbleAnchor GetAnchor() const;

  const raw_ptr<BrowserWindowInterface> browser_;
  base::WeakPtr<content::WebContents> web_contents_;
  const AnchorProvider anchor_provider_;
  raw_ptr<ToolbarActionsModel> toolbar_model_ = nullptr;
  bool shortcuts_active_ = false;
  base::ScopedObservation<ToolbarActionsModel, ToolbarActionsModel::Observer>
      toolbar_model_observation_{this};
  raw_ptr<ToolbarActionViewModel> popup_owner_ = nullptr;
  base::flat_map<ToolbarActionsModel::ActionId,
                 std::unique_ptr<ExtensionActionViewModel>>
      actions_;
  std::unique_ptr<ExtensionsMenuCoordinator> extensions_menu_coordinator_;
  base::WeakPtrFactory<ExtensionsContainerViews> weak_ptr_factory_{this};
};

}  // namespace ararat

#endif  // ARARAT_ARARAT_EXTENSIONS_CONTAINER_H_
