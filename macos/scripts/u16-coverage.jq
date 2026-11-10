def spec($name; $check; $screen; $direction; $flags; $case):
  {name: $name, check: $check, screen: $screen, direction: $direction, flags: ($flags | sort), case: $case};
def matching($s):
  [.[] | select(.check == $s.check and (.screen // "") == $s.screen and
    .compositor == $s.compositor and
    .requested_direction == $s.direction and ((.check_flags // []) | sort) == $s.flags and
    ($s.case == "" or .case == $s.case))];
def valid_pages($expected; $count):
  type == "array" and length == $count and
  all(.[]; (.profile as $p | (.item | type) == "string" and (.item | length) > 0 and
    .item == $expected[$p // ""]) and (.live | type) == "string" and (.live | length) > 0 and
    .active == true and .presented == true);
def multi_pages($expected; $defaults; $count):
  ($expected | type) == "object" and ($expected["Profile 1"] | type) == "string" and ($expected["Profile 1"] | length) > 0 and
  ($defaults | type) == "array" and all($defaults[]; type == "string" and length > 0) and
  type == "array" and length == $count and
  all(.[]; (.item | type) == "string" and (.item | length) > 0 and (.live | type) == "string" and (.live | length) > 0 and .active == true and .presented == true and
    (if .profile == "Default" then .item as $item | ($defaults | index($item)) != null
     elif .profile == "Profile 1" then .item == $expected["Profile 1"] else false end)) and
  ([.[].item] | unique | length) == $count and ([.[].live] | unique | length) == $count;
def multi_cancel_ok($n; $quit):
  .dialogs == $n and .closing == false and (if $quit then .trying_to_quit == false else .close_cancelled == $n end) and
  .selected_matches_active == true and .child_unchanged == true and .workspace_rows_unchanged == true;
def split_cancel_rows($s):
  if (($s.flags | index("--ararat-empty-close-check")) != null or
      ($s.flags | any(startswith("--ararat-selection-supersede=")))) then
    .profile_reconciled == true
  else .rows_unchanged == true end;
def contains_window($id):
  type == "array" and any(.[]; type == "array" and .[0] == "window" and .[1] == $id);
def presentation_ok($mode; $live):
  type == "object" and ($live | type) == "string" and ($live | length) > 0 and
  .compositor == $mode and .live == $live and .target == true and .host == true and
  .visible == true and .presented == true and
  (if $mode == "c2" then .window == true and .bounds == true else true end);
def coherent_attachments($mode):
  all(.. | objects | select(has("attachment")); . as $page |
    ($page.attachment | presentation_ok($mode; $page.live)));
def c2_pages:
  type == "array" and length > 0 and all(.[]; .attachment as $a |
    $a.compositor == "c2" and $a.live == .live and $a.target == true and $a.host == true and $a.window == true and
    $a.visible == true and $a.bounds == true and $a.presented == true);
def valid_records:
  type == "array" and length > 0 and
  all(.[]; type == "array" and length == 3 and all(.[]; type == "string")) and
  (map(.[0:2]) | length == (unique | length));
def regular_window_rows:
  . as $r | ["item", $r.child_item_id] as $item | ["last_selected", $r.child_item_id] as $selected |
  ["window", $r.child_window_id] as $window | [$item, $selected, $window] as $new |
  ($r.rows_before | valid_records) and ($r.rows_during | valid_records) and ($r.rows_after | valid_records) and
  ([$r.rows_before[] | .[0:2]] | all(.[]; . as $key | ($new | index([$key])) == null)) and
  ([$r.rows_during[] | select(.[0:2] as $key | ($new | index([$key])) == null)] | sort) == ($r.rows_before | sort) and
  ([$r.rows_after[] | select(.[0:2] as $key | ($new | index([$key])) == null)] | sort) == ($r.rows_before | sort) and
  ([$r.rows_during[] | .[0:2] as $key | select(($new | index([$key])) != null) | $key] | sort) == ($new | sort) and
  ([$r.rows_after[] | .[0:2] as $key | select(($new | index([$key])) != null) | $key] | sort) == ([$item, $selected] | sort) and
  ([$r.rows_during[] | select(.[0:2] == $item or .[0:2] == $selected)] | sort) ==
    ([$r.rows_after[] | select(.[0:2] == $item or .[0:2] == $selected)] | sort) and
  ([$r.rows_during[] | select(.[0:2] == $item) | .[2] | fromjson][0] |
    .id == $r.child_item_id and .lifecycle == "Open" and .membership.parent == "today-default" and
    (.kind.Tab.url | type == "string" and (. == "" or startswith("chrome://newtab/")))) and
  ([$r.rows_during[] | select(.[0:2] == $window) | .[2] | fromjson][0] |
    .id == $r.child_window_id and .shown_space == "default" and .selected == $r.child_item_id);
def state_ok($s):
  .ok == true and .exit == 0 and .process_exit == 0 and .compositor == $s.compositor and
  coherent_attachments($s.compositor) and
  ((.build_id | type) == "string" and (.build_id | length) > 0) and
  (if $s.check == "keyboard" then .observed_direction == (if $s.direction == "rtl" then "rtl" else "ltr" end) else true end) and
  (if $s.screen == "" then true else .screen_session_unlocked_throughout == true end) and
  (if $s.case == "keyboard-main" then
     . as $r |
     ["page_ime", "reload", "new_tab_panel", "location_focus", "location_navigated", "today_committed",
      "pinned_saved", "back", "find_previous", "protocol_requested", "extension_command", "extension_action",
      "devtools", "forced_search", "default_space_cross_profile", "suggestion_space_cross_profile", "archive_restore",
      "profile_shortcuts", "inactive_reassignment", "two_window_shortcuts", "two_window_teardown", "inactive_profile_teardown",
      "profile_reload", "stale_profile_rejected", "stale_search_rejected", "closed_host_rejected", "invalid_targets",
      "stale_suggestion_actions", "core_menu_collision", "command_suggestions", "suggestion_panel_commands",
      "suggestion_space_commands", "suggestion_close_tab", "folder_and_move_suggestions", "tab_suggestion", "duplicate", "close",
      "fullscreen_new", "fullscreen_location", "fullscreen_find_dismissed", "fullscreen_page_escape", "fullscreen_close",
      "find_pasteboard", "find_zero", "find_visibility", "find_reopen_navigation", "find_devtools_geometry", "find_resized_geometry",
      "find_tab_guard", "find_background_result", "find_delayed_background", "find_replace_guard", "find_pending_teardown",
      "find_host_teardown", "find_profile_guard"] as $required |
     $r.case_ok == true and $r.u16_complete == false and $r.stock_browsers == 0 and
     all($required[]; $r[.] == true) and
     (if $s.screen == "keyboard" then
        ["command_ime", "find_ime_escape", "devtools_find", "fullscreen_command_marked_escape", "fullscreen_find_marked_escape",
         "core_menu_shortcut", "core_menu_library", "core_menu_reset_width", "core_menu_pin", "core_menu_space", "core_menu_settings",
         "extension_reserved_priority", "own_field_noncommand"] as $screen_required |
        all($screen_required[]; $r[.] == true) and
        $r.chooser_bubble.rtl == ($s.direction == "rtl") and $r.restore_bubble.rtl == ($s.direction == "rtl") and
        (($r.chooser_screenshot | type) == "string" and ($r.chooser_screenshot | length) > 0) and
        (($r.restore_screenshot | type) == "string" and ($r.restore_screenshot | length) > 0)
      else
        ["beforeunload_cancel", "viewless_anchor_empty", "hidden_settings", "shared_settings", "settings_edit_target",
         "settings_space_edit", "hidden_window_safe"] as $hidden_required |
        all($hidden_required[]; $r[.] == true) and $r.anchor_geometry.rtl == ($s.direction == "rtl")
      end)
   elif $s.case == "incognito-private" then
     .off_the_record == true and .off_the_record_navigation == true and .native_private_new_tab == true and
     .private_command_close == true and .private_new_incognito_window == true and .location_search_noop == true and
     .rows_unchanged == true and (.rows_before | type == "array" and length > 0) and .rows_before == .rows_after and .stock_browsers == 0
   elif $s.case == "incognito-regular-window" then
     .regular_window_rows == true and .stock_browsers == 0 and
     (.child_window_id | type == "string" and length > 0) and (.child_item_id | type == "string" and length > 0) and
     (.private_live | type == "string" and length > 0) and (.child_live | type == "string" and length > 0) and
     .private_live != .child_live and .private_state_unchanged == true and .child_live_mapping_cleared == true and
     regular_window_rows
   elif $s.case == "space-command-matrix" then
     .u16_complete == false and .space_matrix_suggestion == [range(1;10)] and
     (if $s.screen == "keyboard" then .space_matrix_menu == [range(1;10)] else .space_matrix_menu == [] end) and
     .indexed_commands == ["new_tab", "edit_url", "toggle_sidebar", "toggle_sidebar", "toggle_library", "toggle_library", "reset_sidebar_width", "pin_tab", "pin_tab", "settings", "close_tab"]
   elif $s.case == "cross-window-reverse" then
     ($s.flags | map(select(startswith("--ararat-cross-window-reverse-check="))) | .[0] | split("=")[1]) as $boundary |
     . as $r | $r.u16_complete == false and $r.dispatch_boundary == $boundary and $r.cross_window_reverse == true and $r.rows_unchanged == true and
     ($r.page_presentation | presentation_ok($s.compositor; $r.expected_page_live))
   elif ($s.flags | index("--ararat-page-only-menu-check")) then .page_only_save == true and .rows_unchanged == true
   elif ($s.flags | index("--ararat-quit-suggestion-check")) then
     . as $r | $r.quit_suggestion == true and $r.after_stay.trying_to_quit == false and
     $r.after_stay.browsers == 2 and $r.after_stay.host_alive == true and $r.after_stay.rows_unchanged == true and
     $r.after_stay.prompt_page == true and $r.after_stay.selected_matches_active == true and
     $r.after_stay.hidden_profile_shown == true and $r.after_stay.window_written_after_cancel == true and
     $r.after_stay.rows_unchanged_during_switch == true and ($r.dialog_pages | valid_pages($r.expected_dialog_items; 2)) and
     all($r.dialog_pages[]; .profile == "Profile 1") and $r.dialog_pages[0].live == $r.dialog_pages[1].live and
     $r.rows_unchanged == true and $r.dialog_seen == 2 and $r.closing == [true,false,true] and
     $r.will_shut_down == true and $r.stock_browsers == 0 and $r.selection_confirm_race == true
   elif ($s.flags | index("--ararat-multiple-quit-check")) then
     . as $r | $r.expected_dialog_items as $expected | $r.expected_default_items as $defaults |
     ($defaults | type) == "array" and ($defaults | unique | length) == 2 and
     ($r.multiple_first_cancel | multi_cancel_ok(1; true)) and ($r.multiple_second_cancel | multi_cancel_ok(2; true)) and
     ($r.multiple_first_cancel.dialog_pages | multi_pages($expected; $defaults; 1)) and
     ($r.multiple_second_cancel.dialog_pages | multi_pages($expected; $defaults; 2)) and
     ($r.multiple_final_pages | multi_pages($expected; $defaults; 3)) and
     $r.multiple_first_cancel.dialog_pages == $r.multiple_final_pages[0:1] and
     $r.multiple_second_cancel.dialog_pages == $r.multiple_final_pages[0:2] and
     $r.rows_unchanged == true and $r.dialog_seen == 3 and $r.closing == [true,false,true,false,true] and
     ($r.root_window_id | type) == "string" and ($r.root_window_id | length) > 0 and
     ($r.child_window_id | type) == "string" and ($r.child_window_id | length) > 0 and $r.root_window_id != $r.child_window_id and
     ($r.rows_after | contains_window($r.root_window_id)) and ($r.rows_after | contains_window($r.child_window_id)) and
     $r.will_shut_down == true and $r.stock_browsers == 0
   elif ($s.flags | any(startswith("--ararat-cross-window-selection-check"))) then .cross_window_selection == true
   elif ($s.flags | any(startswith("--ararat-selection-supersede="))) then .selection_supersession == true
   elif ($s.flags | any(startswith("--ararat-committed-switch-race="))) then .committed_switch_race == true
   elif ($s.flags | any(startswith("--ararat-selection-race="))) then
     (if $s.check == "profiles" then .cancel_run else .after_stay end) as $cancel |
     $cancel.selection_race_settled == true and $cancel.selection_race_activated == false and
     $cancel.selection_race_failed == false and .selection_confirm_race == true
   elif ($s.flags | index("--ararat-multiple-close-check")) then
     . as $r | $r.expected_dialog_items as $expected | $r.expected_default_items as $defaults |
     ($defaults | type) == "array" and ($defaults | unique | length) == 2 and
     ($r.multiple_first_cancel | multi_cancel_ok(1; false)) and ($r.multiple_second_cancel | multi_cancel_ok(2; false)) and
     ($r.multiple_first_cancel.dialog_pages | multi_pages($expected; $defaults; 1)) and
     ($r.multiple_second_cancel.dialog_pages | multi_pages($expected; $defaults; 2)) and
     ($r.multiple_final.dialog_pages | multi_pages($expected; $defaults; 3)) and
     $r.multiple_first_cancel.dialog_pages == $r.multiple_final.dialog_pages[0:1] and
     $r.multiple_second_cancel.dialog_pages == $r.multiple_final.dialog_pages[0:2] and
     $r.multiple_child_unchanged == true and $r.multiple_rows_unchanged == true and
     $r.multiple_root_removed == true and $r.multiple_child_kept == true and
     ($r.root_window_id | type) == "string" and ($r.root_window_id | length) > 0 and
     ($r.child_window_id | type) == "string" and ($r.child_window_id | length) > 0 and $r.root_window_id != $r.child_window_id and
     ($r.multiple_rows_before | contains_window($r.root_window_id)) and ($r.multiple_rows_before | contains_window($r.child_window_id)) and
     (($r.multiple_rows_after | contains_window($r.root_window_id)) | not) and ($r.multiple_rows_after | contains_window($r.child_window_id)) and
     $r.multiple_final.dialogs == 3 and $r.multiple_final.close_cancelled == 2 and $r.multiple_final.closed == true
   elif ($s.name == "close-split" or $s.name == "close-empty") then
     . as $r | $r.expected_dialog_items as $expected |
     $r.split_panel_selected == true and $r.cancel_run.dialogs == 2 and $r.cancel_run.close_cancelled == 1 and
     $r.cancel_run.closed == false and $r.cancel_run.closing == false and $r.cancel_run.host_open == true and
     ($r.cancel_run | split_cancel_rows($s)) and $r.cancel_run.split_cancel_restored == true and
     ($r.cancel_run.dialog_pages | valid_pages($expected; 2)) and
     ($r.cancel_run.dialog_pages | map(.profile) | sort) == ["Default", "Profile 1"] and
     ($r.cancel_run.dialog_pages | map(.item) | unique | length) == 2 and
     ($r.cancel_run.dialog_pages | map(.live) | unique | length) == 2 and
     $r.close_run.dialogs == 2 and $r.close_run.close_cancelled == 1 and $r.close_run.closed == true and
     $r.close_run.browsers == 0 and $r.close_run.dialog_pages == $r.cancel_run.dialog_pages and
     $r.rows_unchanged_after_close == true and $r.window_removed == true and $r.widget_closed == true and
     $r.selection_confirm_race == true and $r.stock_browsers == 0
   elif ($s.name | startswith("quit-") and (contains("split") or contains("empty"))) then
     . as $r | $r.expected_dialog_items as $expected |
     (if $s.name == "quit-empty-same-profile" then "Default" else "Profile 1" end) as $profile |
     $r.after_stay.trying_to_quit == false and $r.after_stay.browsers == 2 and $r.after_stay.host_alive == true and
     $r.after_stay.rows_unchanged == true and $r.after_stay.rows_unchanged_during_switch == true and
     $r.after_stay.split_cancel_restored == true and $r.after_stay.prompt_page == true and
     $r.after_stay.selected_matches_active == true and ($r.dialog_pages | valid_pages($expected; 2)) and
     all($r.dialog_pages[]; .profile == $profile) and
     $r.dialog_pages[0].item == $r.dialog_pages[1].item and $r.dialog_pages[0].live == $r.dialog_pages[1].live and
     $r.rows_unchanged == true and $r.dialog_seen == 2 and $r.closing == [true,false,true] and
     $r.will_shut_down == true and $r.stock_browsers == 0 and $r.selection_confirm_race == true
   else true end) and
  (if ($s.flags | index("--ararat-split-close-check")) then
     . as $r |
     if $s.check == "profiles" then
       $r.split_panel_selected == true and $r.cancel_run.dialogs == 2 and $r.cancel_run.close_cancelled == 1 and
       $r.cancel_run.closed == false and $r.cancel_run.closing == false and $r.cancel_run.host_open == true and
       ($r.cancel_run | split_cancel_rows($s)) and $r.cancel_run.split_cancel_restored == true and
       ($r.cancel_run.dialog_pages | valid_pages($r.expected_dialog_items; 2)) and
       ($r.cancel_run.dialog_pages | map(.profile) | sort) == ["Default", "Profile 1"] and
       ($r.cancel_run.dialog_pages | map(.item) | unique | length) == 2 and
       ($r.cancel_run.dialog_pages | map(.live) | unique | length) == 2 and
       $r.close_run.dialogs == 2 and $r.close_run.close_cancelled == 1 and $r.close_run.closed == true and
       $r.close_run.browsers == 0 and $r.close_run.dialog_pages == $r.cancel_run.dialog_pages and
       $r.rows_unchanged_after_close == true and $r.window_removed == true and $r.widget_closed == true and
       $r.selection_confirm_race == true and $r.stock_browsers == 0
     else
       $r.after_stay.trying_to_quit == false and $r.after_stay.browsers == 2 and $r.after_stay.host_alive == true and
       $r.after_stay.rows_unchanged == true and $r.after_stay.rows_unchanged_during_switch == true and
       $r.after_stay.split_cancel_restored == true and $r.after_stay.prompt_page == true and $r.after_stay.selected_matches_active == true and
       ($r.dialog_pages | valid_pages($r.expected_dialog_items; 2)) and
       $r.dialog_pages[0].item == $r.dialog_pages[1].item and $r.dialog_pages[0].live == $r.dialog_pages[1].live and
       $r.rows_unchanged == true and $r.dialog_seen == 2 and $r.closing == [true,false,true] and
       $r.will_shut_down == true and $r.stock_browsers == 0 and $r.selection_confirm_race == true
     end
   else true end) and
  (if $s.compositor != "c2" then true
   elif $s.case == "keyboard-main" then
     .c2_page_attachment == true and .c2_find_attachment == true and .c2_find_resized_attachment == true and
     (if $s.screen == "keyboard" then .c2_page_input_hit == true and .c2_find_stacking_input == true else true end)
   elif $s.case == "space-command-matrix" then
     .c2_matrix_attachment == true and (if $s.screen == "keyboard" then .c2_matrix_input_hit == true else true end)
   elif ($s.flags | index("--ararat-split-close-check")) then
     (if $s.check == "profiles" then (.cancel_run.dialog_pages | c2_pages) and (.close_run.dialog_pages | c2_pages)
      else (.dialog_pages | c2_pages) end)
   elif ($s.flags | index("--ararat-multiple-quit-check")) then
     (.multiple_first_cancel.dialog_pages | c2_pages) and (.multiple_second_cancel.dialog_pages | c2_pages) and (.multiple_final_pages | c2_pages)
   elif ($s.flags | index("--ararat-multiple-close-check")) and $s.case != "cross-window-reverse" then
     (.multiple_first_cancel.dialog_pages | c2_pages) and (.multiple_second_cancel.dialog_pages | c2_pages) and (.multiple_final.dialog_pages | c2_pages)
   elif ($s.flags | index("--ararat-quit-suggestion-check")) then (.dialog_pages | c2_pages)
   else true end);
. as $runs | [
  spec("keyboard-hidden-default"; "keyboard"; ""; "default"; ["--ararat-keyboard-main-scope"]; "keyboard-main"),
  spec("keyboard-hidden-rtl"; "keyboard"; ""; "rtl"; ["--ararat-keyboard-main-scope"]; "keyboard-main"),
  spec("keyboard-screen-default"; "keyboard"; "keyboard"; "default"; ["--ararat-keyboard-main-scope"]; "keyboard-main"),
  spec("keyboard-screen-rtl"; "keyboard"; "keyboard"; "rtl"; ["--ararat-keyboard-main-scope"]; "keyboard-main"),
  spec("matrix-hidden-default"; "keyboard"; ""; "default"; ["--ararat-space-matrix-check"]; "space-command-matrix"),
  spec("matrix-hidden-rtl"; "keyboard"; ""; "rtl"; ["--ararat-space-matrix-check"]; "space-command-matrix"),
  spec("matrix-screen-default"; "keyboard"; "keyboard"; "default"; ["--ararat-space-matrix-check"]; "space-command-matrix"),
  spec("matrix-screen-rtl"; "keyboard"; "keyboard"; "rtl"; ["--ararat-space-matrix-check"]; "space-command-matrix"),
  spec("incognito-private"; "incognito"; ""; "default"; []; "incognito-private"),
  spec("incognito-regular-window"; "incognito"; ""; "default"; ["--ararat-incognito-window-check"]; "incognito-regular-window"),
  spec("page-only-otr"; "profiles"; "profiles"; "default"; ["--ararat-page-only-menu-check"]; ""),
  spec("page-only-popup"; "links"; "links"; "default"; ["--ararat-page-only-menu-check"]; ""),
  spec("page-only-extension-popup"; "extensions"; "extensions"; "default"; ["--ararat-page-only-menu-check"]; ""),
  spec("quit-suggestion"; "quit-cancel"; ""; "default"; ["--ararat-quit-suggestion-check"]; ""),
  spec("quit-multiple"; "quit-cancel"; ""; "default"; ["--ararat-multiple-quit-check"]; ""),
  spec("close-multiple"; "profiles"; ""; "default"; ["--ararat-multiple-close-check"]; ""),
  spec("close-split"; "profiles"; ""; "default"; ["--ararat-split-close-check"]; "close-split"),
  spec("close-empty"; "profiles"; ""; "default"; ["--ararat-split-close-check", "--ararat-empty-close-check"]; "close-empty"),
  spec("quit-split"; "quit-cancel"; ""; "default"; ["--ararat-split-close-check"]; "quit-split"),
  spec("quit-empty-other-profile"; "quit-cancel"; ""; "default"; ["--ararat-split-close-check", "--ararat-empty-close-check"]; "quit-empty-other-profile"),
  spec("quit-empty-same-profile"; "quit-cancel"; ""; "default"; ["--ararat-split-close-check", "--ararat-same-profile-empty-quit-check"]; "quit-empty-same-profile"),
  (("registered", "resolved") as $boundary |
    spec("supersede-" + $boundary; "profiles"; ""; "default"; ["--ararat-split-close-check", "--ararat-selection-supersede=" + $boundary]; ""),
    spec("close-selection-" + $boundary; "profiles"; ""; "default"; ["--ararat-split-close-check", "--ararat-selection-race=" + $boundary]; ""),
    spec("quit-selection-" + $boundary; "quit-cancel"; ""; "default"; ["--ararat-split-close-check", "--ararat-selection-race=" + $boundary]; ""),
    spec("cross-window-" + $boundary; "profiles"; ""; "default"; ["--ararat-multiple-close-check", "--ararat-cross-window-selection-check=" + $boundary]; ""),
    spec("cross-window-reverse-" + $boundary; "profiles"; ""; "default"; ["--ararat-multiple-close-check", "--ararat-cross-window-reverse-check=" + $boundary]; "cross-window-reverse")),
  (("space", "tab") as $kind |
    spec("committed-close-" + $kind; "profiles"; ""; "default"; ["--ararat-split-close-check", "--ararat-committed-switch-race=" + $kind]; ""))
] | (map(. + {compositor:"c1"}) + map(select(.name | startswith("page-only-") | not) | . + {compositor:"c2"})) as $specs |
[ $specs[] as $s | ($runs | matching($s)) as $matches |
  {case: (if $s.compositor == "c2" then "c2-" + $s.name else $s.name end), compositor: $s.compositor, status: (if ($matches | length) == 0 then "missing"
                           elif ($matches | length) != 1 then "duplicate"
                           elif (try ($matches[0] | state_ok($s)) catch false) then "passed"
                           else "failed" end),
   local_case_ok: (if ($matches | length) == 1 and ($matches[0] | has("case_ok")) then $matches[0].case_ok else null end),
   build_id: (if ($matches | length) == 1 then ($matches[0].build_id // null) else null end)} ] as $coverage |
[$coverage[] | select(.status == "passed") | .build_id] | unique as $build_ids |
{coverage: $coverage, build_ids: $build_ids,
 listed_scratch_checks_passed: (all($coverage[]; .status == "passed") and ($build_ids | length) == 1),
 u16_complete: false,
 unproven: ["C2 shared-compositor hierarchy, stacking, geometry and input", "real renderer Find replies across destruction", "real Japanese input method and screen-session validity", "real chooser/restore reach and placement", "design-owned engine/screen regressions and review"]}
