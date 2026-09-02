#!/usr/bin/env bash
# lib/rdc/version_detector.bash
# Redmine/RedMica の実バージョンをソースツリーから検出する Domain モジュール
# 根拠要件: RDC-REQ-F1413, RDC-REQ-F1444

# version_detector_detect_product_from_root()
# root配下のファイル存在から製品種別を検出する。`product`が未確定・信頼できない場合
# （generateのexplicitモード等）の判定手段として使う。
# args: root_dir
# stdout: redmine または redmica
version_detector_detect_product_from_root() {
  local root="${1:?root required}"
  if [[ -f "$root/lib/redmica/version.rb" ]] || [[ -f "$root/redmica.gemspec" ]]; then
    echo "redmica"
  else
    echo "redmine"
  fi
}

# version_detector_detect_from_root()
# root配下のVERSIONファイルまたはversion.rbから実バージョンを検出する
# args: product(redmine|redmica), root_dir
# stdout: バージョン文字列（検出不能時は "unknown"）
version_detector_detect_from_root() {
  local product="${1:?product required}"
  local root="${2:?root required}"
  local version="unknown"

  if [[ -f "$root/VERSION" ]]; then
    version=$(cat "$root/VERSION" | tr -d '[:space:]')
  elif [[ "$product" == "redmica" && -f "$root/lib/redmica/version.rb" ]]; then
    version=$(grep -E "^\s*(MAJOR|MINOR|TINY)\s*=" "$root/lib/redmica/version.rb" 2>/dev/null | \
      awk '{print $NF}' | tr -d ',' | paste -sd '.' || echo "unknown")
  elif [[ -f "$root/lib/redmine/version.rb" ]]; then
    version=$(grep -E "^\s*(MAJOR|MINOR|TINY)\s*=" "$root/lib/redmine/version.rb" 2>/dev/null | \
      awk '{print $NF}' | tr -d ',' | paste -sd '.' || echo "unknown")
  fi

  echo "$version"
}
