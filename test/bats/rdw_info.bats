#!/usr/bin/env bats
# test/bats/rdw_info.bats
# 結合テスト: info サブコマンド（InfoService#run、機械可読ワークスペース情報出力）
# 根拠要件: RDC-REQ-F1401〜F1409, RDC-REQ-F1410〜F1411, RDC-REQ-F0972〜F0979

source test/helpers/rdw_helpers.sh

setup() {
  WS=$(rdw_make_workspace)
}

teardown() {
  rm -rf "$WS"
}

# rdw_info_write_compose_with_image()
# awk抽出対象となる redmine サービスの image: 行を含む docker-compose.yml を配置する
rdw_info_write_compose_with_image() {
  local ws="${1:?workspace_path required}"
  local image="${2:?image required}"
  cat > "$ws/docker-compose.yml" <<EOF
services:
  redmine:
    image: ${image}
  db:
    image: postgres:16
EOF
}

# rdw_info_write_manifest()
# verification/manifest.json を配置する（manifest_builder_build_success と同形式）
rdw_info_write_manifest() {
  local ws="${1:?workspace_path required}"
  local digest="${2:?digest required}"
  local timestamp="${3:?timestamp required}"
  cat > "$ws/verification/manifest.json" <<EOF
{
  "status": "passed",
  "target": "redmine:6.1.2",
  "base_image_digest": "${digest}",
  "migrate": "done",
  "check": "done",
  "plugins": [],
  "timestamp": "${timestamp}"
}
EOF
}

# ---- InfoService#run: 基本出力（人間可読） ----

# RDC-REQ-F1401: info はワークスペースを自動解決し既定で人間可読形式で表示する
@test "[RDC-REQ-F1401] info run: 既定では人間可読形式でワークスペース情報を表示する" {
  rdw_full_state_passenger "$WS"
  cd "$WS"
  run rdw info
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Workspace Info"
}

# RDC-REQ-F0972: info は対象製品種別・base_image_tag・bind・relative_url_root・各ステップ完了状況を出力する
@test "[RDC-REQ-F0972] info run: 対象製品種別・base_image_tag・bind・各ステップ完了状況を出力する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "base_image_tag=redmine:6.1.2" \
    "redmine_bind=127.0.0.1:38080" "relative_url_root=/redmine" \
    "init_status=done" "generate_status=done" "import_status=done" \
    "migrate_status=done" "check_status=pending"
  cd "$WS"
  run rdw info
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "base_image: redmine:6.1.2"
  echo "$output" | grep -q "127.0.0.1:38080"
  echo "$output" | grep -q "init"
  echo "$output" | grep -q "done"
  echo "$output" | grep -q "prepare-db"
  echo "$output" | grep -q "check"
  echo "$output" | grep -q "pending"
}

# RDC-REQ-F1402A: info はワークスペースの絶対パスを出力する
@test "[RDC-REQ-F1402A] info run: ワークスペースのディレクトリパス（絶対パス）を出力する" {
  rdw_full_state_passenger "$WS"
  cd "$WS"
  run rdw info
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "$WS"
}

# RDC-REQ-F0972: info は docker-compose.yml から使用イメージ名を出力する
@test "[RDC-REQ-F0972] info run: generate 完了後は使用イメージ名を出力する" {
  rdw_full_state_passenger "$WS"
  rdw_info_write_compose_with_image "$WS" "futuremine/redmine:6.1.2"
  cd "$WS"
  run rdw info
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "futuremine/redmine:6.1.2"
}

# RDC-REQ-F1402: info は generate 未完了で docker-compose.yml が存在しない場合、使用イメージ名を未生成と表現する
@test "[RDC-REQ-F1402] info run: generate 未完了時は使用イメージ名を未生成として表現する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=pending" "import_status=pending" \
    "migrate_status=pending" "check_status=pending"
  cd "$WS"
  run rdw info
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "not generated"
}

# RDC-REQ-F1445, F1448: target_image_tagが空（explicitモード）でも、generateが検出結果でproductを
# 埋めていればproduct:行が単独形式（コロン無し）で表示され、base_image:行に実際のイメージ参照が出る
@test "[RDC-REQ-F1445][RDC-REQ-F1448] info run: explicitモードでproduct行が単独形式・base_image行に実際の参照が表示される" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=new" "image_source=explicit" \
    "image_ref=futuremine/redmica:4.1.3" "product=redmica" "target_image_tag=" \
    "base_image_tag=futuremine/redmica:4.1.3" \
    "redmine_version=4.1.3" \
    "init_status=done" "generate_status=done" "import_status=done" \
    "migrate_status=done" "check_status=pending"
  cd "$WS"
  run rdw info
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^product:    redmica$"
  ! echo "$output" | grep -q "product:.*redmica:"
  echo "$output" | grep -q "^base_image: futuremine/redmica:4.1.3$"
}

# RDC-REQ-F1445: presetモード（target_image_tagが非空）でもproduct:行は常に単独形式で表示する
@test "[RDC-REQ-F1445] info run: presetモードでもproduct:行は常に単独形式で表示する" {
  rdw_full_state_passenger "$WS"
  cd "$WS"
  run rdw info
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^product:    redmine$"
  ! echo "$output" | grep -q "product:.*redmine:"
  echo "$output" | grep -q "^base_image: redmine:6.1.2$"
}

# ---- InfoService#run: JSON出力 ----

# RDC-REQ-F0973: info --json の出力が有効なJSON形式である
@test "[RDC-REQ-F0973] info --json: 出力が有効なJSON形式である" {
  rdw_full_state_passenger "$WS"
  cd "$WS"
  run rdw info --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import json,sys; json.load(sys.stdin)"
}

# RDC-REQ-F1410: info --json は主要フィールドを含むJSONを標準出力へ出力する
@test "[RDC-REQ-F1410] info --json: 対象製品種別・base_image_tag・使用イメージ名・bind・relative_url_root・パス・ステップ・稼働状態を含む" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "base_image_tag=redmine:6.1.2" \
    "redmine_bind=127.0.0.1:38080" "relative_url_root=/redmine" \
    "init_status=done" "generate_status=done" "import_status=done" \
    "migrate_status=done" "check_status=pending"
  rdw_info_write_compose_with_image "$WS" "futuremine/redmine:6.1.2"
  cd "$WS"
  RDC_MOCK_REDMINE_RUNNING=false run rdw info --json
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"workspace_path":'
  echo "$output" | grep -q '"mode": "passenger"'
  echo "$output" | grep -q '"product": "redmine"'
  echo "$output" | grep -q '"base_image_tag": "redmine:6.1.2"'
  echo "$output" | grep -q '"image": "futuremine/redmine:6.1.2"'
  echo "$output" | grep -q '"redmine_bind": "127.0.0.1:38080"'
  echo "$output" | grep -q '"relative_url_root": "/redmine"'
  echo "$output" | grep -q '"steps":'
  echo "$output" | grep -q '"prepare-db": "done"'
  echo "$output" | grep -q '"runtime":'
}

# RDC-REQ-F1448: info --json は、generateが検出結果で埋めたproductをそのまま出力する
# （explicit時にproductが空のままにならない）
@test "[RDC-REQ-F1448] info --json: generateが検出結果で埋めたproductをそのまま出力する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=new" "image_source=explicit" \
    "image_ref=futuremine/redmica:4.1.3" "product=redmica" "target_image_tag=" \
    "base_image_tag=futuremine/redmica:4.1.3" \
    "redmine_version=4.1.3" \
    "init_status=done" "generate_status=done" "import_status=done" \
    "migrate_status=done" "check_status=pending"
  cd "$WS"
  RDC_MOCK_REDMINE_RUNNING=false run rdw info --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['product'] == 'redmica'; assert d['base_image_tag'] == 'futuremine/redmica:4.1.3'"
}

# RDC-REQ-F1455: info の人間可読・--json出力にtarget_image_tagが含まれずbase_image_tagが含まれる
@test "[RDC-REQ-F1455] info: 人間可読・--json出力にtarget_image_tagが含まれずbase_image_tagが含まれる" {
  rdw_full_state_passenger "$WS"
  cd "$WS"
  run rdw info
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qi "target_image_tag"

  run rdw info --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'target_image_tag' not in d; assert d['base_image_tag'] == 'redmine:6.1.2'"
}

# RDC-REQ-F1403是正: info --json の verification オブジェクトは base_image_digest というキーで出力する（image_digest ではない）
@test "[RDC-REQ-F1403] info --json: verification オブジェクトは base_image_digest というキーで出力する" {
  rdw_full_state_passenger "$WS"
  rdw_info_write_manifest "$WS" "sha256:abcd1234" "2026-08-17T02:00:00Z"
  cd "$WS"
  run rdw info --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['verification']['base_image_digest'] == 'sha256:abcd1234'; assert 'image_digest' not in d['verification']"
}

# ---- InfoService#run: 実バージョン出力 (RDC-REQ-F1413, F1414, F1415) ----

# RDC-REQ-F1414: redmine_version が .rdc_state にある場合は target_image_tag ではなくその値を出力する
@test "[RDC-REQ-F1414] info run: redmine_version が保存されている場合はタグではなく実バージョンを出力する（人間可読）" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=new" "product=redmine" \
    "target_image_tag=latest" "redmine_version=7.0.4" "init_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=done" \
    "check_status=pending"
  cd "$WS"
  run rdw info
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "version:.*7.0.4"
}

# RDC-REQ-F1414: info --json も同様に redmine_version を優先して出力する
@test "[RDC-REQ-F1414] info --json: redmine_version が保存されている場合はタグではなく実バージョンを出力する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=new" "product=redmine" \
    "target_image_tag=latest" "redmine_version=7.0.4" "init_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=done" \
    "check_status=pending"
  cd "$WS"
  RDC_MOCK_REDMINE_RUNNING=false run rdw info --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['redmine_version'] == '7.0.4'"
}

# RDC-REQ-F1414: redmine_version が未保存（本機能実装前に generate 済み・Passenger等）の場合は target_image_tag へフォールバックする
@test "[RDC-REQ-F1414] info run: redmine_version が未保存の場合は target_image_tag へフォールバックする" {
  rdw_full_state_passenger "$WS"
  cd "$WS"
  run rdw info
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "version:.*6.1.2"
}

# RDC-REQ-F1414: redmine_version=unknown（検出失敗）の場合も target_image_tag へフォールバックする
@test "[RDC-REQ-F1414] info run: redmine_version=unknown の場合も target_image_tag へフォールバックする" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=new" "product=redmine" \
    "target_image_tag=7.0.0" "redmine_version=unknown" "init_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=done" \
    "check_status=pending"
  cd "$WS"
  run rdw info
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "version:.*7.0.0"
}

# RDC-REQ-F1415: redmine_version の出力は Docker デーモン疎通不可時でも .rdc_state の値をそのまま出力する（Docker非依存）
@test "[RDC-REQ-F1415] info run: Docker 疎通不可時でも redmine_version は .rdc_state の値をそのまま出力する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=new" "product=redmine" \
    "target_image_tag=latest" "redmine_version=7.0.4" "init_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=done" \
    "check_status=pending"
  cd "$WS"
  RDC_MOCK_DOCKER_DAEMON_REACHABLE=false run rdw info
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "version:.*7.0.4"
}

# ---- InfoService#run: verification 要約 (RDC-REQ-F1403) ----

# RDC-REQ-F0974: check 完了時は verification manifest の要約（検証日時・image digest）を出力する
@test "[RDC-REQ-F0974] info run: check 完了時は検証日時と image digest を出力する" {
  rdw_full_state_passenger "$WS"
  rdw_info_write_manifest "$WS" "sha256:abcd1234" "2026-08-17T02:00:00Z"
  cd "$WS"
  run rdw info
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "sha256:abcd1234"
  echo "$output" | grep -q "2026-08-17T02:00:00Z"
}

# RDC-REQ-F1403是正: check 完了時の人間可読出力は base_image_digest というラベルで表示する（image_digest ではない）
@test "[RDC-REQ-F1403] info run: verification 要約は base_image_digest というラベルで表示する" {
  rdw_full_state_passenger "$WS"
  rdw_info_write_manifest "$WS" "sha256:abcd1234" "2026-08-17T02:00:00Z"
  cd "$WS"
  run rdw info
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "base_image_digest:"
  ! echo "$output" | grep -qE "^\s*image_digest:"
}

# RDC-REQ-F0974: check 未完了時はその旨を表現する
@test "[RDC-REQ-F0974] info run: check 未完了時は未完了である旨を表現する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=done" \
    "migrate_status=done" "check_status=pending"
  cd "$WS"
  run rdw info
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "check not completed\|未完了"
}

# ---- InfoService#run: コンテナ稼働状態 (RDC-REQ-F1404) ----

# RDC-REQ-F0975: コンテナ実行中の場合、稼働状態「実行中」と起動日時を出力する
@test "[RDC-REQ-F0975] info run: コンテナ実行中の場合は稼働状態と起動日時を出力する" {
  rdw_full_state_passenger "$WS"
  cd "$WS"
  RDC_MOCK_CONTAINER_STARTED_AT="2026-08-17T02:05:11Z" run rdw info
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "running\|実行中"
  echo "$output" | grep -q "2026-08-17T02:05:11Z"
}

# RDC-REQ-F1404: コンテナ停止中の場合は稼働状態「停止中」を出力する
@test "[RDC-REQ-F1404] info run: コンテナ停止中の場合は稼働状態を停止中として出力する" {
  rdw_full_state_passenger "$WS"
  cd "$WS"
  RDC_MOCK_REDMINE_RUNNING=false run rdw info
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "stopped\|停止中"
}

# RDC-REQ-F0976: Docker デーモン疎通不可のとき、稼働状態を「不明」として出力し他の情報は通常通り出力したうえで正常終了する
@test "[RDC-REQ-F0976] info run: Docker 疎通不可時は稼働状態を不明として出力し正常終了する" {
  rdw_full_state_passenger "$WS"
  cd "$WS"
  RDC_MOCK_DOCKER_DAEMON_REACHABLE=false run rdw info
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "unknown\|不明"
  echo "$output" | grep -q "Workspace Info"
  echo "$output" | grep -q "redmine:6.1.2"
}

# RDC-REQ-F0001: info は Docker 操作必須サブコマンド群の対象外であり、疎通不可でも即エラー終了しない
@test "[RDC-REQ-F0001] info run: Docker 疎通不可でも他の即エラー終了群とは異なり正常終了する" {
  rdw_full_state_passenger "$WS"
  cd "$WS"
  RDC_MOCK_DOCKER_DAEMON_REACHABLE=false run rdw info
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "接続できません"
}

# ---- InfoService#run: 未初期化・破損時のエラー (RDC-REQ-F1405, F1411) ----

# RDC-REQ-F0977: .rdc_state が存在しない場合は失敗終了し init を案内する
@test "[RDC-REQ-F0977] info run: .rdc_state が存在しない場合は失敗終了し init を案内する" {
  cd "$WS"
  run rdw info
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "not initialized\|初期化されていません"
  echo "$output" | grep -qv "Unknown subcommand"
}

# RDC-REQ-F0977: クリーン済みワークスペースでは失敗終了する
@test "[RDC-REQ-F0977] info run: クリーン済みワークスペースでは失敗終了する" {
  rdw_init_state "$WS" "clean_status=done"
  cd "$WS"
  run rdw info
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "not initialized\|初期化されていません"
  echo "$output" | grep -qv "Unknown subcommand"
}

# RDC-REQ-F1411: 未初期化ワークスペースで info --json を実行した場合、エラー内容を含むJSONが出力され非ゼロ終了する
@test "[RDC-REQ-F1411] info --json: 未初期化ワークスペースではエラーJSONを出力し非ゼロ終了する" {
  cd "$WS"
  run rdw info --json
  [ "$status" -ne 0 ]
  echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'error' in d"
}

# ---- InfoService#run: 読み取り専用・機密情報除外 (RDC-REQ-F0978, F0979) ----

# RDC-REQ-F0978: info 実行後も .rdc_state およびワークスペース配下の生成物を変更しない
@test "[RDC-REQ-F0978] info run: 実行後も .rdc_state が変更されない（読み取り専用）" {
  rdw_full_state_passenger "$WS"
  before=$(cat "$WS/.rdc_state")
  cd "$WS"
  run rdw info
  [ "$status" -eq 0 ]
  after=$(cat "$WS/.rdc_state")
  [ "$before" = "$after" ]
}

# RDC-REQ-F0979: info の出力にDB接続パスワードやsecret key等の機密情報が含まれない
@test "[RDC-REQ-F0979] info run: 出力にDB接続パスワードやsecret key等の機密情報が含まれない" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" "generate_status=pending" \
    "import_status=pending" "migrate_status=pending" "check_status=pending" \
    "db_password=super-secret-password" "secret_key_base=super-secret-key-base"
  cd "$WS"
  run rdw info
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qi "super-secret-password"
  ! echo "$output" | grep -qi "super-secret-key-base"
}

# ---- InfoService: Usage (RDC-REQ-F1408, F1409) ----

# RDC-REQ-F1408, F1409: info --help は役割・--jsonオプション・出力情報カテゴリの概要を表示する
@test "[RDC-REQ-F1408][RDC-REQ-F1409] info --help: Usage を表示する" {
  cd "$WS"
  run rdw info --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Usage:"
  echo "$output" | grep -q -- "--json"
}
