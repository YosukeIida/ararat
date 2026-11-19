#!/bin/bash

sign_bundle() {
  local app="$1"
  local fw_root fw_ver sparkle_root sparkle_ver dylib helper helper_app ent service
  fw_root="$app/Contents/Frameworks/Chromium Framework.framework"
  fw_ver="$fw_root/Versions/Current"
  sparkle_root="$app/Contents/Frameworks/Sparkle.framework"
  sparkle_ver="$sparkle_root/Versions/Current"
  [[ -d "$fw_ver/Helpers" && -f "$sparkle_ver/Autoupdate" && -d "$sparkle_ver/Updater.app" ]] ||
    die "missing Chromium or Sparkle components in $app"

  # Inside out: the framework's dylibs, the bare helper executables, the helper
  # apps, the framework, the app. Helpers that load nothing but their share of
  # the framework's code carry no entitlements; the renderer and GPU helpers
  # carry allow-jit (Aperitif variants ride the same entitlements as the engine's
  # own signing model).
  for dylib in "$fw_ver"/Libraries/*.dylib; do
    [[ -f "$dylib" ]] || continue
    sign "$dylib"
  done
  for helper in "$fw_ver"/Helpers/*; do
    [[ -f "$helper" ]] || continue
    [[ "$(file -b "$helper")" == *Mach-O* ]] || continue
    sign "$helper"
  done
  for helper_app in "$fw_ver"/Helpers/*.app; do
    case "$(basename -- "$helper_app")" in
      *"Helper (Renderer).app"|*"Helper (Aperitif Renderer).app") ent=helper-renderer-entitlements ;;
      *"Helper (GPU).app"|*"Helper (Aperitif GPU).app") ent=helper-gpu-entitlements ;;
      *) ent="" ;;
    esac
    sign "$helper_app" "$ent"
  done
  sign "$fw_root" ""

  for service in "$sparkle_ver"/XPCServices/*.xpc; do
    [[ -d "$service" ]] || continue
    sign "$service"
  done
  sign "$sparkle_ver/Autoupdate"
  sign "$sparkle_ver/Updater.app"
  sign "$sparkle_root"
  sign "$app" app-entitlements

  codesign --verify --deep --strict "$app"
}
