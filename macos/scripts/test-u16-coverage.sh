#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"

jq -n '
  [["item","old","body"],["window","root","body"]] as $before |
  ["item","item",({id:"item",lifecycle:"Open",membership:{parent:"today-default"},kind:{Tab:{url:"chrome://newtab/"}}}|tojson)] as $item |
  ["last_selected","item","123"] as $selected |
  ["window","window",({id:"window",shown_space:"default",selected:"item"}|tojson)] as $window |
  [
  {check:"incognito",case:"incognito-private",compositor:"c1",requested_direction:"default",check_flags:[],ok:true,exit:0,process_exit:0,build_id:"fixture",off_the_record:true,off_the_record_navigation:true,native_private_new_tab:true,private_command_close:true,private_new_incognito_window:true,location_search_noop:true,rows_unchanged:true,rows_before:[["item","old","body"]],rows_after:[["item","old","body"]],stock_browsers:0},
  {check:"incognito",case:"incognito-regular-window",compositor:"c1",requested_direction:"default",check_flags:["--ararat-incognito-window-check"],ok:true,exit:0,process_exit:0,build_id:"fixture",regular_window_rows:true,child_window_id:"window",child_item_id:"item",private_live:"private",child_live:"child",private_state_unchanged:true,child_live_mapping_cleared:true,rows_before:$before,rows_during:($before+[$item,$selected,$window]),rows_after:($before+[$item,$selected]),stock_browsers:0}
]' | jq -f "$script_dir/u16-coverage.jq" | jq -e '
  ([.coverage[] | select(.case == "incognito-private" or .case == "incognito-regular-window") | .status] == ["passed", "passed"]) and
  ([.coverage[] | select(.case == "c2-incognito-private" or .case == "c2-incognito-regular-window") | .status] == ["missing", "missing"])' >/dev/null

jq -n '[{check:"incognito",case:"incognito-private",compositor:"c1",requested_direction:"default",check_flags:[],ok:true,exit:0,process_exit:0,build_id:"fixture",off_the_record:true,off_the_record_navigation:true,native_private_new_tab:true,private_command_close:true,private_new_incognito_window:true,location_search_noop:true,rows_unchanged:true,rows_before:[],rows_after:[["item","leak","body"]],stock_browsers:0}]' |
  jq -f "$script_dir/u16-coverage.jq" | jq -e '.coverage[] | select(.case == "incognito-private") | .status == "failed"' >/dev/null

regular_fixture=$(jq -n '
  [["item","old","body"],["window","root","body"]] as $before |
  ["item","item",({id:"item",lifecycle:"Open",membership:{parent:"today-default"},kind:{Tab:{url:"chrome://newtab/"}}}|tojson)] as $item |
  ["last_selected","item","123"] as $selected |
  ["window","window",({id:"window",shown_space:"default",selected:"item"}|tojson)] as $window |
  {check:"incognito",case:"incognito-regular-window",requested_direction:"default",check_flags:["--ararat-incognito-window-check"],ok:true,exit:0,process_exit:0,build_id:"fixture",regular_window_rows:true,child_window_id:"window",child_item_id:"item",private_live:"private",child_live:"child",private_state_unchanged:true,child_live_mapping_cleared:true,rows_before:$before,rows_during:($before+[$item,$selected,$window]),rows_after:($before+[$item,$selected]),stock_browsers:0}')
for compositor in c1 c2; do
  scope=incognito-regular-window
  if [[ "$compositor" == c2 ]]; then scope=c2-incognito-regular-window; fi
  printf '%s\n' "$regular_fixture" | jq --arg c "$compositor" '[.compositor=$c]' | jq -f "$script_dir/u16-coverage.jq" |
    jq -e --arg scope "$scope" '.coverage[] | select(.case == $scope) | .status == "passed"' >/dev/null
  for mutation in 'del(.rows_before)' 'del(.rows_during)' 'del(.rows_after)' \
    '.rows_during[0][2]="changed"' '.rows_after += [["item","private","leak"]]' \
    '.rows_during += [.rows_during[0]]' '.rows_after += [["window","window","retained"]]' \
    '.rows_after |= map(select(.[0] != "last_selected"))' '.rows_after[2][2]="changed"' \
    '.rows_during[2][2]="{}"' '.child_live_mapping_cleared=false' '.private_state_unchanged=false'; do
    printf '%s\n' "$regular_fixture" | jq --arg c "$compositor" "[.compositor=\$c | $mutation]" | jq -f "$script_dir/u16-coverage.jq" |
      jq -e --arg scope "$scope" '.coverage[] | select(.case == $scope) | .status == "failed"' >/dev/null
  done
  for name in incognito-private incognito-regular-window; do
    scope="$name"
    if [[ "$compositor" == c2 ]]; then scope="c2-$name"; fi
    for failure in timeout early startup watchdog; do
      jq -n --arg c "$compositor" --arg name "$name" --arg failure "$failure" \
        '[{check:"incognito",case:$name,compositor:$c,requested_direction:"default",check_flags:(if $name == "incognito-private" then [] else ["--ararat-incognito-window-check"] end),ok:false,exit:1,process_exit:1,build_id:"fixture",error:$failure}]' |
        jq -f "$script_dir/u16-coverage.jq" | jq -e --arg scope "$scope" '.coverage[] | select(.case == $scope) | .status == "failed"' >/dev/null
    done
  done
done

for direction in rtl ltr missing; do
  jq -n --arg direction "$direction" '[{check:"keyboard",case:"space-command-matrix",u16_complete:false,observed_direction:(if $direction == "missing" then null else $direction end),compositor:"c1",requested_direction:"rtl",check_flags:["--ararat-space-matrix-check"],ok:true,exit:0,process_exit:0,build_id:"fixture",space_matrix_suggestion:[range(1;10)],space_matrix_menu:[],indexed_commands:["new_tab","edit_url","toggle_sidebar","toggle_sidebar","toggle_library","toggle_library","reset_sidebar_width","pin_tab","pin_tab","settings","close_tab"]}]' |
    jq -f "$script_dir/u16-coverage.jq" | jq -e --arg direction "$direction" '
      (.coverage | map(select(.case == "matrix-hidden-rtl"))[0].status) == (if $direction == "rtl" then "passed" else "failed" end)' >/dev/null
done

jq -n '[
  {check:"keyboard",case:"space-command-matrix",u16_complete:false,observed_direction:"ltr",compositor:"c1",requested_direction:"default",check_flags:["--ararat-space-matrix-check"],ok:true,exit:0,process_exit:0,build_id:"fixture",space_matrix_suggestion:[range(1;10)],space_matrix_menu:[],indexed_commands:["new_tab","edit_url","toggle_sidebar","toggle_sidebar","toggle_library","toggle_library","reset_sidebar_width","pin_tab","pin_tab","settings","close_tab"]},
  {check:"profiles",case:"cross-window-reverse",u16_complete:false,dispatch_boundary:"resolved",compositor:"c1",requested_direction:"default",check_flags:["--ararat-multiple-close-check","--ararat-cross-window-reverse-check=resolved"],ok:true,exit:0,process_exit:0,build_id:"fixture",cross_window_reverse:true,expected_page_live:"live",page_presentation:{compositor:"c1",live:"live",target:true,host:true,visible:true,presented:true},rows_unchanged:true}
]' | jq -f "$script_dir/u16-coverage.jq" | jq -e '
  (.coverage | map(select(.status == "passed") | .case) | sort) == ["cross-window-reverse-resolved","matrix-hidden-default"] and
  .listed_scratch_checks_passed == false and .u16_complete == false' >/dev/null

jq -n '[{check:"keyboard",case:"space-command-matrix",u16_complete:false,observed_direction:"ltr",compositor:"c2",requested_direction:"default",check_flags:["--ararat-space-matrix-check"],ok:true,exit:0,process_exit:0,build_id:"fixture",c2_matrix_attachment:true,space_matrix_suggestion:[range(1;10)],space_matrix_menu:[],indexed_commands:["new_tab","edit_url","toggle_sidebar","toggle_sidebar","toggle_library","toggle_library","reset_sidebar_width","pin_tab","pin_tab","settings","close_tab"]}]' |
  jq -f "$script_dir/u16-coverage.jq" | jq -e '
    (.coverage | map(select(.case == "c2-matrix-hidden-default"))[0].status) == "passed" and
    (.coverage | map(select(.case == "matrix-hidden-default"))[0].status) == "missing" and .u16_complete == false' >/dev/null

# A top-level relabel alone must not establish a C2 page observation.
jq -n '[{check:"profiles",case:"cross-window-reverse",u16_complete:false,dispatch_boundary:"resolved",compositor:"c2",requested_direction:"default",check_flags:["--ararat-multiple-close-check","--ararat-cross-window-reverse-check=resolved"],ok:true,exit:0,process_exit:0,build_id:"fixture",cross_window_reverse:true,rows_unchanged:true}]' |
  jq -f "$script_dir/u16-coverage.jq" | jq -e '.coverage[] | select(.case == "c2-cross-window-reverse-resolved") | .status == "failed"' >/dev/null
jq -n '[{check:"profiles",case:"cross-window-reverse",u16_complete:false,dispatch_boundary:"resolved",compositor:"c2",requested_direction:"default",check_flags:["--ararat-multiple-close-check","--ararat-cross-window-reverse-check=resolved"],ok:true,exit:0,process_exit:0,build_id:"fixture",cross_window_reverse:true,rows_unchanged:true,expected_page_live:"live",page_presentation:{compositor:"c2",live:"live",target:true,host:true,window:true,visible:true,bounds:true,presented:true}}]' |
  jq -f "$script_dir/u16-coverage.jq" | jq -e '.coverage[] | select(.case == "c2-cross-window-reverse-resolved") | .status == "passed"' >/dev/null
for field in compositor live target host window visible bounds presented; do
  jq -n --arg field "$field" '[{check:"profiles",case:"cross-window-reverse",u16_complete:false,dispatch_boundary:"resolved",compositor:"c2",requested_direction:"default",check_flags:["--ararat-multiple-close-check","--ararat-cross-window-reverse-check=resolved"],ok:true,exit:0,process_exit:0,build_id:"fixture",cross_window_reverse:true,rows_unchanged:true,expected_page_live:"live",page_presentation:{compositor:"c2",live:"live",target:true,host:true,window:true,visible:true,bounds:true,presented:true}} | del(.page_presentation[$field])]' |
    jq -f "$script_dir/u16-coverage.jq" | jq -e '.coverage[] | select(.case == "c2-cross-window-reverse-resolved") | .status == "failed"' >/dev/null
done

jq -n '[
  {check:"keyboard",case:"space-command-matrix",u16_complete:false,observed_direction:"ltr",compositor:"c1",requested_direction:"default",check_flags:["--ararat-space-matrix-check"],ok:true,exit:0,process_exit:0,build_id:"fixture",space_matrix_suggestion:[1,2,3],space_matrix_menu:[],indexed_commands:[]},
  {check:"profiles",case:"cross-window-reverse",u16_complete:false,dispatch_boundary:"resolved",compositor:"c1",requested_direction:"default",check_flags:["--ararat-multiple-close-check","--ararat-cross-window-reverse-check=resolved"],ok:true,exit:0,process_exit:0,build_id:"fixture",cross_window_reverse:true,expected_page_live:"live",page_presentation:{compositor:"c1",live:"live",target:true,host:true,visible:true,presented:true},rows_unchanged:false},
  {check:"keyboard",case:"keyboard-main",compositor:"c1",requested_direction:"default",check_flags:["--ararat-keyboard-main-scope"],ok:false,exit:1,case_ok:false}
]' | jq -f "$script_dir/u16-coverage.jq" | jq -e '
  (.coverage | map(select(.status == "failed") | .case) | sort) == ["cross-window-reverse-resolved","keyboard-hidden-default","matrix-hidden-default"] and
  (.coverage | map(select(.case == "keyboard-hidden-default"))[0].local_case_ok) == false and
  .listed_scratch_checks_passed == false and .u16_complete == false' >/dev/null

jq -n '[{check:"profiles",case:"cross-window-reverse",u16_complete:false,dispatch_boundary:"resolved",compositor:"c1",requested_direction:"default",check_flags:["--ararat-multiple-close-check","--ararat-cross-window-reverse-check=resolved"],ok:true,exit:0,cross_window_reverse:true,expected_page_live:"live",page_presentation:{compositor:"c1",live:"live",target:true,host:true,visible:true,presented:true},rows_unchanged:true}] | . + .' |
  jq -f "$script_dir/u16-coverage.jq" | jq -e '
    (.coverage | map(select(.case == "cross-window-reverse-resolved"))[0].status) == "duplicate" and
    ([.coverage[].case] | length) == ([.coverage[].case] | unique | length) and .u16_complete == false' >/dev/null

jq -n '[{check:"profiles",screen:"profiles",compositor:"c1",requested_direction:"default",check_flags:["--ararat-page-only-menu-check"],ok:true,exit:0,process_exit:0,build_id:"fixture",page_only_save:true,rows_unchanged:true}]' |
  jq -f "$script_dir/u16-coverage.jq" | jq -e '
    (.coverage | map(select(.case == "page-only-otr"))[0].status) == "failed" and .u16_complete == false' >/dev/null

jq -n '[{check:"profiles",screen:"profiles",compositor:"c1",requested_direction:"default",check_flags:["--ararat-page-only-menu-check"],ok:true,exit:0,process_exit:0,build_id:"fixture",screen_session_unlocked_throughout:true,page_only_save:true,rows_unchanged:true}]' |
  jq -f "$script_dir/u16-coverage.jq" | jq -e '
    (.coverage | map(select(.case == "page-only-otr"))[0].status) == "passed" and .listed_scratch_checks_passed == false and .u16_complete == false' >/dev/null

jq -n '[{check:"keyboard",case:"keyboard-main",compositor:"c1",requested_direction:"default",check_flags:["--ararat-keyboard-main-scope"],ok:true,exit:0,process_exit:0,build_id:"fixture",case_ok:true,u16_complete:false,stock_browsers:0}]' |
  jq -f "$script_dir/u16-coverage.jq" | jq -e '
    (.coverage | map(select(.case == "keyboard-hidden-default"))[0].status) == "failed" and .u16_complete == false' >/dev/null

jq -n '
  ["page_ime","reload","new_tab_panel","location_focus","location_navigated","today_committed","pinned_saved","back","find_previous","protocol_requested","extension_command","extension_action","devtools","forced_search","default_space_cross_profile","suggestion_space_cross_profile","archive_restore","profile_shortcuts","inactive_reassignment","two_window_shortcuts","two_window_teardown","inactive_profile_teardown","profile_reload","stale_profile_rejected","stale_search_rejected","closed_host_rejected","invalid_targets","stale_suggestion_actions","core_menu_collision","command_suggestions","suggestion_panel_commands","suggestion_space_commands","suggestion_close_tab","folder_and_move_suggestions","tab_suggestion","duplicate","close","fullscreen_new","fullscreen_location","fullscreen_find_dismissed","fullscreen_page_escape","fullscreen_close","find_pasteboard","find_zero","find_visibility","find_reopen_navigation","find_devtools_geometry","find_resized_geometry","find_tab_guard","find_background_result","find_delayed_background","find_replace_guard","find_pending_teardown","find_host_teardown","find_profile_guard","beforeunload_cancel","viewless_anchor_empty","hidden_settings","shared_settings","settings_edit_target","settings_space_edit","hidden_window_safe"] as $keys |
  [reduce $keys[] as $key ({check:"keyboard",case:"keyboard-main",compositor:"c1",requested_direction:"default",observed_direction:"ltr",check_flags:["--ararat-keyboard-main-scope"],ok:true,exit:0,process_exit:0,build_id:"fixture",case_ok:true,u16_complete:false,stock_browsers:0,anchor_geometry:{rtl:false}}; .[$key] = true)]' |
  jq -f "$script_dir/u16-coverage.jq" | jq -e '
    (.coverage | map(select(.case == "keyboard-hidden-default"))[0].status) == "passed" and .listed_scratch_checks_passed == false and .u16_complete == false' >/dev/null

for direction in rtl ltr missing; do
  jq -n --arg direction "$direction" '
    ["page_ime","reload","new_tab_panel","location_focus","location_navigated","today_committed","pinned_saved","back","find_previous","protocol_requested","extension_command","extension_action","devtools","forced_search","default_space_cross_profile","suggestion_space_cross_profile","archive_restore","profile_shortcuts","inactive_reassignment","two_window_shortcuts","two_window_teardown","inactive_profile_teardown","profile_reload","stale_profile_rejected","stale_search_rejected","closed_host_rejected","invalid_targets","stale_suggestion_actions","core_menu_collision","command_suggestions","suggestion_panel_commands","suggestion_space_commands","suggestion_close_tab","folder_and_move_suggestions","tab_suggestion","duplicate","close","fullscreen_new","fullscreen_location","fullscreen_find_dismissed","fullscreen_page_escape","fullscreen_close","find_pasteboard","find_zero","find_visibility","find_reopen_navigation","find_devtools_geometry","find_resized_geometry","find_tab_guard","find_background_result","find_delayed_background","find_replace_guard","find_pending_teardown","find_host_teardown","find_profile_guard","command_ime","find_ime_escape","devtools_find","fullscreen_command_marked_escape","fullscreen_find_marked_escape","core_menu_shortcut","core_menu_library","core_menu_reset_width","core_menu_pin","core_menu_space","core_menu_settings","extension_reserved_priority","own_field_noncommand"] as $keys |
    [reduce $keys[] as $key ({check:"keyboard",screen:"keyboard",case:"keyboard-main",compositor:"c1",requested_direction:"rtl",observed_direction:(if $direction == "missing" then null else $direction end),check_flags:["--ararat-keyboard-main-scope"],ok:true,exit:0,process_exit:0,build_id:"fixture",screen_session_unlocked_throughout:true,case_ok:true,u16_complete:false,stock_browsers:0,chooser_bubble:{rtl:true},restore_bubble:{rtl:true},chooser_screenshot:"chooser",restore_screenshot:"restore"}; .[$key] = true)]' |
    jq -f "$script_dir/u16-coverage.jq" | jq -e --arg direction "$direction" '
      (.coverage | map(select(.case == "keyboard-screen-rtl"))[0].status) == (if $direction == "rtl" then "passed" else "failed" end)' >/dev/null
done

jq -n '[{check:"profiles",case:"cross-window-reverse",u16_complete:false,dispatch_boundary:"resolved",compositor:"c1",requested_direction:"default",check_flags:["--ararat-multiple-close-check","--ararat-cross-window-reverse-check=resolved"],ok:true,exit:0,process_exit:1,build_id:"fixture",cross_window_reverse:true,expected_page_live:"live",page_presentation:{compositor:"c1",live:"live",target:true,host:true,visible:true,presented:true},rows_unchanged:true}]' |
  jq -f "$script_dir/u16-coverage.jq" | jq -e '
    (.coverage | map(select(.case == "cross-window-reverse-resolved"))[0].status) == "failed" and .u16_complete == false' >/dev/null

jq -n '[
  {check:"profiles",case:"cross-window-reverse",u16_complete:false,dispatch_boundary:"resolved",compositor:"c1",requested_direction:"default",check_flags:["--ararat-multiple-close-check","--ararat-cross-window-reverse-check=resolved"],ok:true,exit:0,process_exit:0,build_id:"one",cross_window_reverse:true,expected_page_live:"live",page_presentation:{compositor:"c1",live:"live",target:true,host:true,visible:true,presented:true},rows_unchanged:true},
  {check:"profiles",case:"cross-window-reverse",u16_complete:false,dispatch_boundary:"registered",compositor:"c1",requested_direction:"default",check_flags:["--ararat-multiple-close-check","--ararat-cross-window-reverse-check=registered"],ok:true,exit:0,process_exit:0,build_id:"two",cross_window_reverse:true,expected_page_live:"live",page_presentation:{compositor:"c1",live:"live",target:true,host:true,visible:true,presented:true},rows_unchanged:true}
]' | jq -f "$script_dir/u16-coverage.jq" | jq -e '
  .build_ids == ["one","two"] and .listed_scratch_checks_passed == false and .u16_complete == false' >/dev/null

# The review's unrelated-case counterexample must not become a pass.
jq -n '[{check:"profiles",case:"unrelated",compositor:"c1",requested_direction:"default",check_flags:["--ararat-split-close-check"],ok:true,exit:0,process_exit:0,build_id:"fixture"}]' |
  jq -f "$script_dir/u16-coverage.jq" | jq -e '.coverage[] | select(.case == "close-split") | .status != "passed"' >/dev/null

fixture=$(jq -n '
  {Default:"a", "Profile 1":"b"} as $expected |
  [{profile:"Default",item:"a",live:"la",active:true,presented:true},
   {profile:"Profile 1",item:"b",live:"lb",active:true,presented:true}] as $pages |
  {check:"profiles",case:"close-split",compositor:"c1",requested_direction:"default",check_flags:["--ararat-split-close-check"],ok:true,exit:0,process_exit:0,build_id:"fixture",
   expected_dialog_items:$expected,split_panel_preserved:true,selection_confirm_race:true,stock_browsers:0,
   rows_unchanged_after_close:true,window_removed:true,widget_closed:true,
   cancel_run:{dialogs:2,close_cancelled:1,closed:false,closing:false,host_open:true,rows_unchanged:true,split_cancel_restored:true,dialog_pages:$pages},
   close_run:{dialogs:2,close_cancelled:1,closed:true,browsers:0,dialog_pages:$pages}}')
printf '%s\n' "$fixture" | jq '[.]' | jq -f "$script_dir/u16-coverage.jq" |
  jq -e '.coverage[] | select(.case == "close-split") | .status == "passed"' >/dev/null
printf '%s\n' "$fixture" | jq '[.cancel_run.dialog_pages |= map(.attachment={compositor:"c1",live:.live,target:true,host:true,visible:true,presented:true}) | .close_run.dialog_pages=.cancel_run.dialog_pages]' | jq -f "$script_dir/u16-coverage.jq" |
  jq -e '.coverage[] | select(.case == "close-split") | .status == "passed"' >/dev/null
printf '%s\n' "$fixture" | jq '[.cancel_run.dialog_pages |= map(.attachment={compositor:"c2",live:.live,target:true,host:true,window:true,visible:true,bounds:true,presented:true}) | .close_run.dialog_pages=.cancel_run.dialog_pages]' | jq -f "$script_dir/u16-coverage.jq" |
  jq -e '.coverage[] | select(.case == "close-split") | .status == "failed"' >/dev/null
printf '%s\n' "$fixture" | jq '[.cancel_run.dialog_pages |= map(.live="same-live") | .close_run.dialog_pages |= map(.live="same-live")]' | jq -f "$script_dir/u16-coverage.jq" |
  jq -e '.coverage[] | select(.case == "close-split") | .status != "passed"' >/dev/null
for path in '.split_panel_preserved' '.cancel_run.dialogs' '.cancel_run.close_cancelled' '.cancel_run.closed' '.cancel_run.closing' '.cancel_run.host_open' '.cancel_run.rows_unchanged' '.cancel_run.split_cancel_restored' '.cancel_run.dialog_pages[0].item' '.cancel_run.dialog_pages[0].live' '.cancel_run.dialog_pages[0].active' '.cancel_run.dialog_pages[0].presented' '.close_run.dialogs' '.close_run.close_cancelled' '.close_run.closed' '.close_run.browsers' '.close_run.dialog_pages' '.rows_unchanged_after_close' '.window_removed' '.widget_closed' '.selection_confirm_race' '.stock_browsers'; do
  printf '%s\n' "$fixture" | jq "[del($path)]" | jq -f "$script_dir/u16-coverage.jq" |
    jq -e '.coverage[] | select(.case == "close-split") | .status != "passed"' >/dev/null
done

multi_fixture=$(jq -n '
  {"Default":"a","Profile 1":"b"} as $expected |
  [{profile:"Default",item:"a",live:"la",active:true,presented:true},
   {profile:"Default",item:"c",live:"lc",active:true,presented:true},
   {profile:"Profile 1",item:"b",live:"lb",active:true,presented:true}] as $pages |
  {check:"profiles",compositor:"c1",requested_direction:"default",check_flags:["--ararat-multiple-close-check"],ok:true,exit:0,process_exit:0,build_id:"fixture",
   expected_dialog_items:$expected,expected_default_items:["a","c"],multiple_child_unchanged:true,multiple_rows_unchanged:true,multiple_root_removed:true,multiple_child_kept:true,
   root_window_id:"root",child_window_id:"child",multiple_rows_before:[["window","root"],["window","child"]],multiple_rows_after:[["window","child"]],
   multiple_first_cancel:{dialogs:1,close_cancelled:1,closing:false,selected_matches_active:true,child_unchanged:true,workspace_rows_unchanged:true,dialog_pages:$pages[0:1]},
   multiple_second_cancel:{dialogs:2,close_cancelled:2,closing:false,selected_matches_active:true,child_unchanged:true,workspace_rows_unchanged:true,dialog_pages:$pages[0:2]},
   multiple_final:{dialogs:3,close_cancelled:2,closed:true,dialog_pages:$pages}}')
printf '%s\n' "$multi_fixture" | jq '[.]' | jq -f "$script_dir/u16-coverage.jq" |
  jq -e '.coverage[] | select(.case == "close-multiple") | .status == "passed"' >/dev/null
printf '%s\n' "$multi_fixture" | jq '[.expected_dialog_items["Profile 1"]="" | .multiple_final.dialog_pages[2].item=""]' | jq -f "$script_dir/u16-coverage.jq" |
  jq -e '.coverage[] | select(.case == "close-multiple") | .status != "passed"' >/dev/null
printf '%s\n' "$multi_fixture" | jq '[.expected_default_items[0]=0 | .multiple_first_cancel.dialog_pages[0].item=0 | .multiple_second_cancel.dialog_pages[0].item=0 | .multiple_final.dialog_pages[0].item=0]' | jq -f "$script_dir/u16-coverage.jq" |
  jq -e '.coverage[] | select(.case == "close-multiple") | .status != "passed"' >/dev/null
for path in '.root_window_id' '.child_window_id' '.multiple_rows_before' '.multiple_rows_after'; do
  printf '%s\n' "$multi_fixture" | jq "[del($path)]" | jq -f "$script_dir/u16-coverage.jq" |
    jq -e '.coverage[] | select(.case == "close-multiple") | .status != "passed"' >/dev/null
done
for path in '.expected_default_items' '.expected_dialog_items["Profile 1"]' '.multiple_first_cancel.dialogs' '.multiple_first_cancel.close_cancelled' '.multiple_first_cancel.closing' '.multiple_first_cancel.selected_matches_active' '.multiple_first_cancel.child_unchanged' '.multiple_first_cancel.workspace_rows_unchanged' '.multiple_first_cancel.dialog_pages[0].item' '.multiple_second_cancel.dialogs' '.multiple_second_cancel.close_cancelled' '.multiple_second_cancel.closing' '.multiple_second_cancel.selected_matches_active' '.multiple_second_cancel.child_unchanged' '.multiple_second_cancel.workspace_rows_unchanged' '.multiple_second_cancel.dialog_pages[1].presented' '.multiple_final.dialog_pages[2].live' '.multiple_final.dialog_pages[2].active' '.multiple_child_unchanged' '.multiple_rows_unchanged' '.multiple_root_removed' '.multiple_child_kept' '.multiple_final.dialogs' '.multiple_final.close_cancelled' '.multiple_final.closed'; do
  printf '%s\n' "$multi_fixture" | jq "[del($path)]" | jq -f "$script_dir/u16-coverage.jq" |
    jq -e '.coverage[] | select(.case == "close-multiple") | .status != "passed"' >/dev/null
done

multi_quit=$(printf '%s\n' "$multi_fixture" | jq '.check="quit-cancel" | .check_flags=["--ararat-multiple-quit-check"] | .multiple_first_cancel.trying_to_quit=false | .multiple_second_cancel.trying_to_quit=false | .multiple_final_pages=.multiple_final.dialog_pages | .rows_after=.multiple_rows_before | .rows_unchanged=true | .dialog_seen=3 | .closing=[true,false,true,false,true] | .will_shut_down=true | .stock_browsers=0')
printf '%s\n' "$multi_quit" | jq '[.]' | jq -f "$script_dir/u16-coverage.jq" |
  jq -e '.coverage[] | select(.case == "quit-multiple") | .status == "passed"' >/dev/null
for path in '.root_window_id' '.child_window_id' '.rows_after'; do
  printf '%s\n' "$multi_quit" | jq "[del($path)]" | jq -f "$script_dir/u16-coverage.jq" |
    jq -e '.coverage[] | select(.case == "quit-multiple") | .status != "passed"' >/dev/null
done
for path in '.multiple_first_cancel.dialogs' '.multiple_first_cancel.trying_to_quit' '.multiple_first_cancel.closing' '.multiple_first_cancel.selected_matches_active' '.multiple_first_cancel.child_unchanged' '.multiple_first_cancel.workspace_rows_unchanged' '.multiple_first_cancel.dialog_pages[0].item' '.multiple_second_cancel.dialogs' '.multiple_second_cancel.trying_to_quit' '.multiple_second_cancel.closing' '.multiple_second_cancel.selected_matches_active' '.multiple_second_cancel.child_unchanged' '.multiple_second_cancel.workspace_rows_unchanged' '.multiple_second_cancel.dialog_pages[1].presented' '.multiple_final_pages[2].live' '.multiple_final_pages[2].active' '.rows_unchanged' '.dialog_seen' '.closing' '.will_shut_down' '.stock_browsers'; do
  printf '%s\n' "$multi_quit" | jq "[del($path)]" | jq -f "$script_dir/u16-coverage.jq" |
    jq -e '.coverage[] | select(.case == "quit-multiple") | .status != "passed"' >/dev/null
done
printf '%s\n' "$fixture" | jq '[.compositor="c2"]' | jq -f "$script_dir/u16-coverage.jq" |
  jq -e '.coverage[] | select(.case == "close-split") | .status != "passed"' >/dev/null
printf '%s\n' "$fixture" | jq '[.compositor="c2" | .cancel_run.dialog_pages |= map(.attachment={compositor:"c2",live:.live,target:true,host:true,window:true,visible:true,bounds:true,presented:true}) | .close_run.dialog_pages=.cancel_run.dialog_pages]' | jq -f "$script_dir/u16-coverage.jq" |
  jq -e '(.coverage | map(select(.case == "c2-close-split"))[0].status) == "passed" and (.coverage | map(select(.case == "close-split"))[0].status) == "missing"' >/dev/null
printf '%s\n' "$fixture" | jq '[.compositor="c2" | .cancel_run.dialog_pages |= map(.attachment={compositor:"c2",live:.live,target:true,host:true,window:true,visible:true,bounds:false,presented:true}) | .close_run.dialog_pages=.cancel_run.dialog_pages]' | jq -f "$script_dir/u16-coverage.jq" |
  jq -e '.coverage[] | select(.case == "c2-close-split") | .status != "passed"' >/dev/null
printf '%s\n' "$fixture" | jq '[.case="close-empty" | .check_flags += ["--ararat-empty-close-check"]]' | jq -f "$script_dir/u16-coverage.jq" |
  jq -e '.coverage[] | select(.case == "close-empty") | .status == "passed"' >/dev/null

quit_fixture=$(jq -n '
  {"Default":"a","Profile 1":"b"} as $expected |
  {profile:"Profile 1",item:"b",live:"lb",active:true,presented:true} as $page |
  {check:"quit-cancel",case:"quit-split",compositor:"c1",requested_direction:"default",check_flags:["--ararat-split-close-check"],ok:true,exit:0,process_exit:0,build_id:"fixture",
   expected_dialog_items:$expected,dialog_pages:[$page,$page],selection_confirm_race:true,rows_unchanged:true,dialog_seen:2,closing:[true,false,true],will_shut_down:true,stock_browsers:0,
   after_stay:{trying_to_quit:false,browsers:2,host_alive:true,rows_unchanged:true,rows_unchanged_during_switch:true,split_cancel_restored:true,prompt_page:true,selected_matches_active:true}}')
printf '%s\n' "$quit_fixture" | jq '[.]' | jq -f "$script_dir/u16-coverage.jq" |
  jq -e '.coverage[] | select(.case == "quit-split") | .status == "passed"' >/dev/null
for path in '.after_stay.trying_to_quit' '.after_stay.browsers' '.after_stay.host_alive' '.after_stay.rows_unchanged' '.after_stay.rows_unchanged_during_switch' '.after_stay.split_cancel_restored' '.after_stay.prompt_page' '.after_stay.selected_matches_active' '.dialog_pages[0].profile' '.dialog_pages[0].item' '.dialog_pages[0].live' '.dialog_pages[0].active' '.dialog_pages[0].presented' '.dialog_pages[1].live' '.rows_unchanged' '.dialog_seen' '.closing' '.will_shut_down' '.stock_browsers' '.selection_confirm_race'; do
  printf '%s\n' "$quit_fixture" | jq "[del($path)]" | jq -f "$script_dir/u16-coverage.jq" |
    jq -e '.coverage[] | select(.case == "quit-split") | .status != "passed"' >/dev/null
done
printf '%s\n' "$quit_fixture" | jq '[.case="quit-empty-other-profile" | .check_flags += ["--ararat-empty-close-check"]]' | jq -f "$script_dir/u16-coverage.jq" |
  jq -e '.coverage[] | select(.case == "quit-empty-other-profile") | .status == "passed"' >/dev/null
printf '%s\n' "$quit_fixture" | jq '[.case="quit-empty-same-profile" | .check_flags += ["--ararat-same-profile-empty-quit-check"] | .dialog_pages |= map(.profile="Default" | .item="a" | .live="la")]' | jq -f "$script_dir/u16-coverage.jq" |
  jq -e '.coverage[] | select(.case == "quit-empty-same-profile") | .status == "passed"' >/dev/null
