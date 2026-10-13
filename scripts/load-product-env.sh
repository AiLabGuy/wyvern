#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Wyvern Contributors
# SPDX-License-Identifier: MIT
# shellcheck shell=bash

# Source this file after ROOT is set, or let it infer ROOT from this script.
#   . "$ROOT/scripts/load-product-env.sh"

if [[ -z "${ROOT:-}" ]]; then
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
PRODUCT_ENV="${ROOT}/config/product.env"
if [[ ! -f "$PRODUCT_ENV" ]]; then
  echo "missing ${PRODUCT_ENV}" >&2
  if [[ -n "${BASH_SOURCE[1]:-}" ]]; then
    return 1
  fi
  exit 1
fi
set -a
# shellcheck disable=SC1090
. "$PRODUCT_ENV"
set +a
: "${PRODUCT_NAME:?}"
: "${DISPLAY_NAME:?}"
: "${BUNDLE_NAME:?}"
: "${BUNDLE_ID:?}"
: "${VERSION:?}"
: "${EXECUTABLE_NAME:?}"
: "${APP_BUNDLE:?}"
: "${DMG_BASENAME:?}"
: "${SWIFT_PRODUCT:?}"
: "${SCREENSHOTS_ZIP:?}"
: "${DMG_ZIP:?}"
: "${ARTIFACT_NAME:?}"
: "${UPDATE_FEED_URL:=}"
: "${UPDATE_PUBLIC_KEY:=}"
: "${UPDATE_DEV_SOURCE:=}"
: "${BUILD_NUMBER:=1}"
: "${WYVERN_GIT_COMMIT:=}"

generate_info_plist() {
  local dest="$1"
  local template="${ROOT}/Resources/Info.plist.in"
  if [[ ! -f "$template" ]]; then
    echo "missing ${template}" >&2
    return 1
  fi
  sed -e "s|@PRODUCT_NAME@|${PRODUCT_NAME}|g" \
      -e "s|@DISPLAY_NAME@|${DISPLAY_NAME}|g" \
      -e "s|@BUNDLE_NAME@|${BUNDLE_NAME}|g" \
      -e "s|@BUNDLE_ID@|${BUNDLE_ID}|g" \
      -e "s|@VERSION@|${VERSION}|g" \
      -e "s|@BUILD_NUMBER@|${BUILD_NUMBER}|g" \
      -e "s|@EXECUTABLE_NAME@|${EXECUTABLE_NAME}|g" \
      -e "s|@WYVERN_GIT_COMMIT@|${WYVERN_GIT_COMMIT}|g" \
      -e "s|@UPDATE_FEED_URL@|${UPDATE_FEED_URL}|g" \
      -e "s|@UPDATE_PUBLIC_KEY@|${UPDATE_PUBLIC_KEY}|g" \
      -e "s|@UPDATE_DEV_SOURCE@|${UPDATE_DEV_SOURCE}|g" \
      -e "s|@DMG_BASENAME@|${DMG_BASENAME}|g" \
      "$template" > "$dest"
}
