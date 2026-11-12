// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "ararat/core/ararat_extensions_container.h"

#include <utility>

#include "base/feature_list.h"
#include "base/functional/bind.h"
#include "base/task/single_thread_task_runner.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/extensions/extension_action_view_model.h"
#include "chrome/browser/ui/toolbar/toolbar_action_view_model.h"
#include "chrome/browser/ui/views/extensions/extension_action_delegate_desktop.h"
#include "chrome/browser/ui/views/extensions/extension_view_utils.h"
#include "chrome/browser/ui/views/extensions/extensions_menu_coordinator.h"
#include "chrome/browser/ui/views/extensions/extensions_menu_view.h"
#include "content/public/browser/web_contents.h"
#include "extensions/common/extension_features.h"
#include "ui/views/widget/widget.h"
#include "ui/views/view.h"

namespace ararat {

AraratExtensionsContainer::AraratExtensionsContainer(
    BrowserWindowInterface* browser,
    content::WebContents* web_contents,
    AnchorProvider anchor_provider)
    : browser_(browser),
      anchor_provider_(std::move(anchor_provider)),
      toolbar_model_(browser && browser->GetProfile()
                         ? ToolbarActionsModel::Get(browser->GetProfile())
                         : nullptr),
      extensions_menu_coordinator_(
          base::FeatureList::IsEnabled(
              extensions_features::kExtensionsMenuAccessControl)
              ? std::make_unique<ExtensionsMenuCoordinator>(browser, this)
              : nullptr) {
  SetWebContents(web_contents);
  if (toolbar_model_) {
    toolbar_model_observation_.Observe(toolbar_model_);
    CreateActions();
  }
}

AraratExtensionsContainer::~AraratExtensionsContainer() {
  if (web_contents_) {
    SetExtensionsContainerViewsForWebContents(web_contents_.get(), nullptr);
  }
  CloseExtensionsMenuIfOpen();
  HideActivePopup();
  popup_owner_ = nullptr;
  for (const auto& [_, model] : actions_) {
    model->UnregisterCommand();
  }
  icon_observations_.clear();
  actions_.clear();
}

void AraratExtensionsContainer::SetChangedCallback(base::RepeatingClosure callback) {
  changed_ = std::move(callback);
}

void AraratExtensionsContainer::QueueChanged() {
  if (change_queued_) return;
  change_queued_ = true;
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&AraratExtensionsContainer::DispatchChanged,
                                notification_weak_.GetWeakPtr()));
}

void AraratExtensionsContainer::DispatchChanged() {
  change_queued_ = false;
  if (changed_) changed_.Run();
}

void AraratExtensionsContainer::ShowExtensionsMenu() {
  if (extensions_menu_coordinator_ &&
      extensions_menu_coordinator_->IsShowing()) {
    extensions_menu_coordinator_->Hide();
    return;
  }
  if (ExtensionsMenuView::IsShowing()) {
    ExtensionsMenuView::Hide();
    return;
  }

  // The anchor is resolved at show time; its backing element may have gone
  // away since the menu was last shown.
  views::BubbleAnchor anchor = GetAnchor();
  if (anchor.IsNull()) {
    return;
  }

  if (extensions_menu_coordinator_) {
    extensions_menu_coordinator_->Show(anchor, this);
  } else {
    ExtensionsMenuView::ShowBubble(anchor, browser_, this, this);
  }
}

bool AraratExtensionsContainer::IsExtensionsMenuShowing() const {
  if (extensions_menu_coordinator_) {
    return extensions_menu_coordinator_->IsShowing();
  }
  return ExtensionsMenuView::IsShowing();
}

void AraratExtensionsContainer::SetWebContents(
    content::WebContents* web_contents) {
  if (web_contents_.get() == web_contents) {
    return;
  }
  if (web_contents_) {
    // Unregister this container from the previous WebContents.
    SetExtensionsContainerViewsForWebContents(web_contents_.get(), nullptr);
  }
  web_contents_ = web_contents ? web_contents->GetWeakPtr() : nullptr;
  if (web_contents) {
    // Register this container with the incoming WebContents so extension views
    // and dialogs (e.g. reload page dialog) resolve to this container.
    SetExtensionsContainerViewsForWebContents(web_contents,
                                              weak_ptr_factory_.GetWeakPtr());
  }
  QueueChanged();
}

ToolbarActionViewModel* AraratExtensionsContainer::GetActionForId(
    const std::string& action_id) {
  auto it = actions_.find(action_id);
  return it != actions_.end() ? it->second.get() : nullptr;
}

void AraratExtensionsContainer::HideActivePopup() {
  if (popup_owner_) {
    popup_owner_->HidePopup();
  }
}

void AraratExtensionsContainer::CloseExtensionsMenuIfOpen() {
  if (extensions_menu_coordinator_ &&
      extensions_menu_coordinator_->IsShowing()) {
    extensions_menu_coordinator_->Hide();
  } else if (ExtensionsMenuView::IsShowing()) {
    ExtensionsMenuView::Hide();
  }
}

bool AraratExtensionsContainer::ShowToolbarActionPopupForAPICall(
    const std::string& action_id,
    ShowPopupCallback callback) {
  auto* action = GetActionForId(action_id);
  if (!action || popup_owner_ || GetAnchor().IsNull()) return false;
  action->TriggerPopupForAPI(std::move(callback));
  return true;
}

void AraratExtensionsContainer::ToggleExtensionsMenu() {
  ShowExtensionsMenu();
}

bool AraratExtensionsContainer::HasAnyExtensions() const {
  return !actions_.empty();
}

content::WebContents* AraratExtensionsContainer::GetActiveWebContents()
    const {
  return web_contents_.get();
}

bool AraratExtensionsContainer::IsVisible() const {
  return true;
}

std::optional<extensions::ExtensionId>
AraratExtensionsContainer::GetPoppedOutActionId() const {
  return std::nullopt;
}

bool AraratExtensionsContainer::IsActionVisibleOnToolbar(
    const std::string& action_id) const {
  return false;
}

void AraratExtensionsContainer::UndoPopOut() {}

void AraratExtensionsContainer::SetPopupOwner(
    ToolbarActionViewModel* popup_owner) {
  popup_owner_ = popup_owner;
}

void AraratExtensionsContainer::PopOutAction(
    const extensions::ExtensionId& action_id,
    base::OnceClosure closure) {
  if (closure) {
    std::move(closure).Run();
  }
}

void AraratExtensionsContainer::ShowWidgetForExtension(
    views::Widget* widget,
    const std::string& extension_id) {
  if (widget) {
    widget->Show();
  }
}

void AraratExtensionsContainer::CollapseConfirmation() {}

void AraratExtensionsContainer::ShowContextMenuAsFallback(
    const extensions::ExtensionId& action_id) {}

void AraratExtensionsContainer::OnPopupShown(
    const extensions::ExtensionId& action_id,
    bool by_user) {}

void AraratExtensionsContainer::OnPopupClosed(
    const extensions::ExtensionId& action_id) {}

views::FocusManager*
AraratExtensionsContainer::GetFocusManagerForAccelerator() {
  if (!shortcuts_active_) return nullptr;
  auto anchor = GetAnchor();
  auto* view = anchor.GetIfView();
  return view && view->GetWidget() ? view->GetWidget()->GetFocusManager() : nullptr;
}

void AraratExtensionsContainer::SetShortcutActive(bool active) {
  if (shortcuts_active_ == active) return;
  if (!active) {
    for (const auto& [_, model] : actions_) model->UnregisterCommand();
    shortcuts_active_ = false;
  } else {
    shortcuts_active_ = true;
    for (const auto& [_, model] : actions_) model->RegisterCommand();
  }
}

views::BubbleAnchor
AraratExtensionsContainer::GetReferenceButtonForPopup(
    const extensions::ExtensionId& action_id) {
  return GetAnchor();
}

views::BubbleAnchor
AraratExtensionsContainer::GetExtensionsButtonAnchor() {
  return GetAnchor();
}

views::BubbleBorder::Arrow AraratExtensionsContainer::GetPopupArrow()
    const {
  return views::BubbleBorder::TOP_LEFT;
}

void AraratExtensionsContainer::OnToolbarModelInitialized() {
  CreateActions();
  QueueChanged();
}

void AraratExtensionsContainer::OnToolbarActionAdded(
    const ToolbarActionsModel::ActionId& action_id) {
  CreateActionForId(action_id);
  QueueChanged();
}

void AraratExtensionsContainer::OnToolbarActionRemoved(
    const ToolbarActionsModel::ActionId& action_id) {
  auto it = actions_.find(action_id);
  if (it == actions_.end()) {
    return;
  }
  if (popup_owner_ == it->second.get()) {
    popup_owner_ = nullptr;
  }
  it->second->HidePopup();
  it->second->UnregisterCommand();
  icon_observations_.erase(action_id);
  actions_.erase(it);
  QueueChanged();
}

void AraratExtensionsContainer::OnToolbarActionUpdated(
    const ToolbarActionsModel::ActionId& action_id) { QueueChanged(); }

void AraratExtensionsContainer::OnToolbarPinnedActionsChanged() { QueueChanged(); }

void AraratExtensionsContainer::OnToolbarActionsModelShutdown() {
  toolbar_model_observation_.Reset();
  toolbar_model_ = nullptr;
  CloseExtensionsMenuIfOpen();
  HideActivePopup();
  popup_owner_ = nullptr;
  for (const auto& [_, model] : actions_) {
    model->UnregisterCommand();
  }
  icon_observations_.clear();
  actions_.clear();
  QueueChanged();
}

void AraratExtensionsContainer::CreateActions() {
  if (!toolbar_model_ || !toolbar_model_->actions_initialized()) {
    return;
  }

  for (const auto& action_id : toolbar_model_->action_ids()) {
    CreateActionForId(action_id);
  }
}

void AraratExtensionsContainer::CreateActionForId(
    const ToolbarActionsModel::ActionId& action_id) {
  if (actions_.contains(action_id)) return;
  actions_[action_id] = ExtensionActionViewModel::Create(
      action_id, browser_,
      std::make_unique<ExtensionActionDelegateDesktop>(browser_, this, this));
  icon_observations_[action_id] = actions_[action_id]->RegisterIconUpdateObserver(
      base::BindRepeating(&AraratExtensionsContainer::QueueChanged,
                          notification_weak_.GetWeakPtr()));
  if (shortcuts_active_) actions_[action_id]->RegisterCommand();
}

views::BubbleAnchor AraratExtensionsContainer::GetAnchor() const {
  return anchor_provider_ ? anchor_provider_.Run() : views::BubbleAnchor();
}

}  // namespace ararat
