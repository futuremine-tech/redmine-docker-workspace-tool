#!/usr/bin/env bats
# test/bats/rdw_auto.bats
# 結合テスト: auto サブコマンド（AutoService#run、新規生成モード限定のパイプライン一気通貫実行）
# 根拠要件: RDC-REQ-F1415〜F1426, F1415A, F1435（機能要件）、
#           RDC-REQ-F1427〜F1430, F1434, F1436（受け入れ基準のうちauto関連分）、
#           RDC-REQ-F0982〜F0993（テスト要件）
# 設計: develop/docs/1A-DESIGN-F1415-auto-and-json-outputs.md 4節

source test/helpers/rdw_helpers.sh

setup() {
  source lib/rdc/logger.bash
  source lib/rdc/state_store.bash
  source lib/rdc/status_service.bash
  source lib/rdc/auto_service.bash
  WS=$(rdw_make_workspace)
  RDW_AUTO_CALL_LOG="$WS/.auto_call_log"
  export RDC_MOCK_DOCKER_DAEMON_REACHABLE=true
}

teardown() {
  rm -rf "$WS"
}

# rdw_auto_stub_services()
# auto_service_run_pipeline が呼び出す各サービスの _run()・docker compose を上書きし、
# 呼び出し順序・引数を $RDW_AUTO_CALL_LOG へ記録するテスト専用スタブを定義する。
# RDW_AUTO_FAIL_AT に渡したステップ名の呼び出しのみ非ゼロを返す（それ以降は呼ばれない前提を
# 検証できる）。fail_at は意図的に local にしない: 各スタブ関数は auto_service_run_pipeline
# 経由で本関数のスタックフレームが破棄された後に呼ばれるため、bashのネスト関数は
# クロージャではなく呼び出し時点の動的スコープで変数を解決する。local のままだと
# スタブ呼び出し時には fail_at が既に unset になっており常に成功してしまう。
# args: fail_at (optional, one of: init/generate/prepare-db/docker-compose-build/migrate/docker-compose-up/check)
rdw_auto_stub_services() {
  RDW_AUTO_FAIL_AT="${1:-}"
  : > "$RDW_AUTO_CALL_LOG"

  init_service_run() {
    echo "init $*" >> "$RDW_AUTO_CALL_LOG"
    [[ "$RDW_AUTO_FAIL_AT" == "init" ]] && return 1
    return 0
  }
  add_plugin_service_run() {
    echo "add-plugin $*" >> "$RDW_AUTO_CALL_LOG"
    [[ "$RDW_AUTO_FAIL_AT" == "add-plugin" ]] && return 1
    return 0
  }
  generate_service_run() {
    echo "generate $* [DB_PASSWORD=${DB_PASSWORD:-}]" >> "$RDW_AUTO_CALL_LOG"
    [[ "$RDW_AUTO_FAIL_AT" == "generate" ]] && return 1
    return 0
  }
  prepare_db_service_run() {
    echo "prepare-db $*" >> "$RDW_AUTO_CALL_LOG"
    [[ "$RDW_AUTO_FAIL_AT" == "prepare-db" ]] && return 1
    return 0
  }
  migrate_service_run() {
    echo "migrate $*" >> "$RDW_AUTO_CALL_LOG"
    [[ "$RDW_AUTO_FAIL_AT" == "migrate" ]] && return 1
    return 0
  }
  check_service_run() {
    echo "check $*" >> "$RDW_AUTO_CALL_LOG"
    [[ "$RDW_AUTO_FAIL_AT" == "check" ]] && return 1
    return 0
  }
  docker() {
    if [[ "${1:-}" == "compose" && "${2:-}" == "build" ]]; then
      echo "docker-compose-build" >> "$RDW_AUTO_CALL_LOG"
      [[ "$RDW_AUTO_FAIL_AT" == "docker-compose-build" ]] && return 1
      return 0
    elif [[ "${1:-}" == "compose" && "${2:-}" == "up" ]]; then
      echo "docker-compose-up" >> "$RDW_AUTO_CALL_LOG"
      [[ "$RDW_AUTO_FAIL_AT" == "docker-compose-up" ]] && return 1
      return 0
    fi
    return 0
  }
}

# ---- AutoService: Usage (RDC-REQ-F1426) ----

# RDC-REQ-F1426: auto --help は役割・受け付けるオプション一覧・新規生成モード限定である旨を表示する
@test "[RDC-REQ-F1426] auto --help: Usage を表示する" {
  run auto_service_run --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Usage:"
  echo "$output" | grep -q -- "--fresh-db"
  echo "$output" | grep -q -- "--import-from"
  echo "$output" | grep -qi "new-generation"
}

# ---- AutoService#run: 静的検証 (RDC-REQ-F1435, F1415A, F1416, F1436, F0991, F0992, F0993) ----

# RDC-REQ-F1415A, F0991: プロダクト・イメージ選択オプション未指定は init を呼ばず失敗する
@test "[RDC-REQ-F1415A][RDC-REQ-F0991] auto: プロダクト選択オプション未指定は init を含めどのサブコマンドも呼ばず失敗する" {
  rdw_auto_stub_services
  cd "$WS"
  run auto_service_run --target "$WS" --fresh-db
  [ "$status" -ne 0 ]
  [ ! -s "$RDW_AUTO_CALL_LOG" ]
}

# RDC-REQ-F1415A, F0991: プロダクト・イメージ選択オプションを2個以上指定した場合も同様に失敗する
@test "[RDC-REQ-F1415A][RDC-REQ-F0991] auto: プロダクト選択オプションを2個指定した場合はどのサブコマンドも呼ばず失敗する" {
  rdw_auto_stub_services
  cd "$WS"
  run auto_service_run --target "$WS" --redmine 6.1.2 --redmica 2.7.0 --fresh-db
  [ "$status" -ne 0 ]
  [ ! -s "$RDW_AUTO_CALL_LOG" ]
}

# RDC-REQ-F1416, F0992: DB準備経路オプション未指定は失敗する
@test "[RDC-REQ-F1416][RDC-REQ-F0992] auto: DB準備経路オプション未指定はどのサブコマンドも呼ばず失敗する" {
  rdw_auto_stub_services
  cd "$WS"
  run auto_service_run --target "$WS" --redmine 6.1.2
  [ "$status" -ne 0 ]
  [ ! -s "$RDW_AUTO_CALL_LOG" ]
}

# RDC-REQ-F1416, F0992: DB準備経路オプションを2個指定した場合も失敗する
@test "[RDC-REQ-F1416][RDC-REQ-F0992] auto: DB準備経路オプションを2個指定した場合はどのサブコマンドも呼ばず失敗する" {
  rdw_auto_stub_services
  cd "$WS"
  run auto_service_run --target "$WS" --redmine 6.1.2 --fresh-db --import-from "$WS/dump.sql"
  [ "$status" -ne 0 ]
  [ ! -s "$RDW_AUTO_CALL_LOG" ]
}

# RDC-REQ-F1436, F0993: --import-from に存在しないパスを指定した場合、init を含めどのサブコマンドも呼ばず失敗する
@test "[RDC-REQ-F1436][RDC-REQ-F0993] auto: --import-from に存在しないパスを指定した場合はどのサブコマンドも呼ばず失敗する" {
  rdw_auto_stub_services
  cd "$WS"
  run auto_service_run --target "$WS" --redmine 6.1.2 --import-from "$WS/does-not-exist.sql"
  [ "$status" -ne 0 ]
  [ ! -s "$RDW_AUTO_CALL_LOG" ]
}

# ---- AutoService#run: Docker疎通確認 (RDC-REQ-F1425, F0987) ----

# RDC-REQ-F1425, F0987: Docker デーモンに疎通できない場合、内部処理を一切行わずエラー終了する
@test "[RDC-REQ-F1425][RDC-REQ-F0987] auto: Docker 疎通不可の場合は内部処理を一切行わずエラー終了する" {
  rdw_auto_stub_services
  cd "$WS"
  RDC_MOCK_DOCKER_DAEMON_REACHABLE=false run auto_service_run --target "$WS" --redmine 6.1.2 --fresh-db
  [ "$status" -ne 0 ]
  [ ! -s "$RDW_AUTO_CALL_LOG" ]
}

# ---- AutoService: 多重実行検知 (RDC-REQ-F1424, F0985) — PIDロックファイル ----

# RDC-REQ-F1424: 生存中のPIDを記録したロックファイルが既に存在する場合、ロック取得は失敗する
@test "[RDC-REQ-F1424] auto_service_acquire_lock: 生存中の別プロセスのPIDのロックが既にある場合は取得失敗する" {
  ( sleep 30 ) & local other_pid=$!
  echo "$other_pid" > "$WS/.rdc_auto.lock"
  run auto_service_acquire_lock "$WS"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "already in progress"
  kill "$other_pid" 2>/dev/null || true
  wait "$other_pid" 2>/dev/null || true
}

# RDC-REQ-F1424: プロセスが既に終了しているPIDのロックファイルは自動的に上書きして取得できる
@test "[RDC-REQ-F1424] auto_service_acquire_lock: 死んだPIDのロックは自動的に上書きして取得できる" {
  ( exit 0 ) & local dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true
  echo "$dead_pid" > "$WS/.rdc_auto.lock"
  run auto_service_acquire_lock "$WS"
  [ "$status" -eq 0 ]
  [ "$(cat "$WS/.rdc_auto.lock")" = "$$" ]
}

# RDC-REQ-F1424: ロックファイルが存在しない場合は取得でき、自身のPIDを記録する
@test "[RDC-REQ-F1424] auto_service_acquire_lock: ロック未存在時は取得でき自身のPIDを記録する" {
  run auto_service_acquire_lock "$WS"
  [ "$status" -eq 0 ]
  [ "$(cat "$WS/.rdc_auto.lock")" = "$$" ]
}

# RDC-REQ-F1424: ロック解放後はロックファイルが残らない
@test "[RDC-REQ-F1424] auto_service_release_lock: 解放後はロックファイルが削除される" {
  auto_service_acquire_lock "$WS"
  run auto_service_release_lock "$WS"
  [ "$status" -eq 0 ]
  [ ! -f "$WS/.rdc_auto.lock" ]
}

# RDC-REQ-F1424, F0985: 同一ワークスペースへ多重実行した場合、後から実行された auto が失敗する
@test "[RDC-REQ-F1424][RDC-REQ-F0985] auto: 同一ワークスペースへの多重実行は後続の実行を失敗させる" {
  rdw_auto_stub_services
  ( sleep 30 ) & local other_pid=$!
  echo "$other_pid" > "$WS/.rdc_auto.lock"
  cd "$WS"
  run auto_service_run --target "$WS" --redmine 6.1.2 --fresh-db
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "already in progress"
  [ ! -s "$RDW_AUTO_CALL_LOG" ]
  kill "$other_pid" 2>/dev/null || true
  wait "$other_pid" 2>/dev/null || true
}

# ---- AutoService#run: パイプライン実行 (RDC-REQ-F1415, F1421, F1427, F0982) ----

# RDC-REQ-F1415, F1427, F0982: 新規生成モード入力で init〜check までが順に自動実行される
@test "[RDC-REQ-F1415][RDC-REQ-F1427][RDC-REQ-F0982] auto: init〜check までが正しい順序で自動実行される" {
  rdw_auto_stub_services
  cd "$WS"
  run auto_service_run --target "$WS" --redmine 6.1.2 --fresh-db
  [ "$status" -eq 0 ]
  local expected="init
generate
prepare-db
docker-compose-build
migrate
docker-compose-up
check"
  local actual
  actual=$(cut -d' ' -f1 "$RDW_AUTO_CALL_LOG")
  [ "$actual" = "$expected" ]
}

# RDC-REQ-F0986: --relative-url-root・--bind-port・--lang の各オプションを対応する内部サブコマンドへ引き継ぐ
@test "[RDC-REQ-F0986] auto: --relative-url-root・--bind-port・--lang を対応する内部サブコマンドへ引き継ぐ" {
  rdw_auto_stub_services
  cd "$WS"
  run auto_service_run --target "$WS" --redmine 6.1.2 --fresh-db \
    --relative-url-root /redmine --bind-port 39090 --lang en
  [ "$status" -eq 0 ]
  grep -q "^generate .*--relative-url-root /redmine" "$RDW_AUTO_CALL_LOG"
  grep -q "^generate .*--bind-port 39090" "$RDW_AUTO_CALL_LOG"
  grep -q "^migrate .*--lang en" "$RDW_AUTO_CALL_LOG"
}

# RDC-REQ-F0986: --redmica・--import-from を対応する内部サブコマンドへ引き継ぐ
@test "[RDC-REQ-F0986] auto: --redmica・--import-from を対応する内部サブコマンドへ引き継ぐ" {
  rdw_auto_stub_services
  local dump="$WS/dump.sql"
  : > "$dump"
  cd "$WS"
  run auto_service_run --target "$WS" --redmica 2.7.0 --import-from "$dump"
  [ "$status" -eq 0 ]
  grep -q "^init .*--redmica 2.7.0" "$RDW_AUTO_CALL_LOG"
  grep -q "^prepare-db .*--import-from $dump" "$RDW_AUTO_CALL_LOG"
}

# RDC-REQ-F0986: --base-image を init へ引き継ぐ
@test "[RDC-REQ-F0986] auto: --base-image を init へ引き継ぐ" {
  rdw_auto_stub_services
  cd "$WS"
  run auto_service_run --target "$WS" --base-image futuremine/redmine:7.0.0 --fresh-db
  [ "$status" -eq 0 ]
  grep -q "^init .*--base-image futuremine/redmine:7.0.0" "$RDW_AUTO_CALL_LOG"
}

# RDC-REQ-F1415A, F0983: Passenger入力モード専用オプションを渡しても init へ引き継がれない（新規生成モード限定）
@test "[RDC-REQ-F1415A][RDC-REQ-F0983] auto: Passenger専用オプションを渡しても init へは引き継がれない" {
  rdw_auto_stub_services
  cd "$WS"
  run auto_service_run --target "$WS" --redmine 6.1.2 --fresh-db \
    --mode passenger --redmine-root /var/lib/redmine
  [ "$status" -eq 0 ]
  ! grep -q -- "--mode" "$RDW_AUTO_CALL_LOG"
  ! grep -q -- "--redmine-root" "$RDW_AUTO_CALL_LOG"
}

# ---- AutoService#run: 失敗時の安全停止 (RDC-REQ-F1422, F1423, F0984) ----

# RDC-REQ-F1422, F1423, F0984: init が失敗した場合、後続ステップは実行されず失敗理由が示される
@test "[RDC-REQ-F1422][RDC-REQ-F1423][RDC-REQ-F0984] auto: init 失敗時は後続ステップを実行せず失敗を明示する" {
  rdw_auto_stub_services "init"
  cd "$WS"
  run auto_service_run --target "$WS" --redmine 6.1.2 --fresh-db
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "init"
  [ "$(wc -l < "$RDW_AUTO_CALL_LOG")" -eq 1 ]
  grep -q "^init " "$RDW_AUTO_CALL_LOG"
}

# RDC-REQ-F1422, F1423, F0984: prepare-db が失敗した場合、migrate 以降は実行されず失敗理由が示される
@test "[RDC-REQ-F1422][RDC-REQ-F1423][RDC-REQ-F0984] auto: prepare-db 失敗時は migrate 以降を実行せず失敗を明示する" {
  rdw_auto_stub_services "prepare-db"
  cd "$WS"
  run auto_service_run --target "$WS" --redmine 6.1.2 --fresh-db
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "prepare-db"
  local actual
  actual=$(cut -d' ' -f1 "$RDW_AUTO_CALL_LOG")
  [ "$actual" = "init
generate
prepare-db" ]
}

# RDC-REQ-F1422, F1423, F0984: docker compose build が失敗した場合、migrate 以降は実行されない
@test "[RDC-REQ-F1422][RDC-REQ-F1423][RDC-REQ-F0984] auto: docker compose build 失敗時は migrate 以降を実行しない" {
  rdw_auto_stub_services "docker-compose-build"
  cd "$WS"
  run auto_service_run --target "$WS" --redmine 6.1.2 --fresh-db
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "build"
  ! grep -q "^migrate" "$RDW_AUTO_CALL_LOG"
  ! grep -q "^check" "$RDW_AUTO_CALL_LOG"
}

# RDC-REQ-F1422, F1423, F0984: check が失敗した場合も失敗として扱い理由を明示する
@test "[RDC-REQ-F1422][RDC-REQ-F1423][RDC-REQ-F0984] auto: check 失敗時も失敗として扱い理由を明示する" {
  rdw_auto_stub_services "check"
  cd "$WS"
  run auto_service_run --target "$WS" --redmine 6.1.2 --fresh-db
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "check"
}

# RDC-REQ-F1424: auto 実行完了後（成功・失敗いずれも）はロックファイルが残らない
@test "[RDC-REQ-F1424] auto: 成功時はロックファイルが残らない" {
  rdw_auto_stub_services
  cd "$WS"
  run auto_service_run --target "$WS" --redmine 6.1.2 --fresh-db
  [ "$status" -eq 0 ]
  [ ! -f "$WS/.rdc_auto.lock" ]
}

@test "[RDC-REQ-F1424] auto: 失敗時もロックファイルが残らない" {
  rdw_auto_stub_services "init"
  cd "$WS"
  run auto_service_run --target "$WS" --redmine 6.1.2 --fresh-db
  [ "$status" -ne 0 ]
  [ ! -f "$WS/.rdc_auto.lock" ]
}

# ---- AutoService: DB_PASSWORDの非対話自動生成 (design_log 2026-08-28エントリ参照) ----
# autoはgenerateを呼ぶ際、常にランダム生成したDB_PASSWORDを渡す。generate_service_run自体は
# 無改修（既存の「環境変数DB_PASSWORDがあれば対話入力より優先する」という既存の優先順位
# （rdw_generate.bats「.env 不在時は環境変数 DB_PASSWORDを使う」で検証済み）にそのまま乗る。

# auto_service_generate_random_password: 非空の文字列を返す
@test "[RDC-DESIGN] auto_service_generate_random_password: 非空の文字列を返す" {
  run auto_service_generate_random_password
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# auto_service_generate_random_password: 呼び出すたびに異なる値を返す（ランダム性）
@test "[RDC-DESIGN] auto_service_generate_random_password: 呼び出すたびに異なる値を返す" {
  local p1 p2
  p1=$(auto_service_generate_random_password)
  p2=$(auto_service_generate_random_password)
  [ "$p1" != "$p2" ]
}

# auto: generate呼び出し時に非空のDB_PASSWORDを渡し、対話入力を必要としない
@test "[RDC-DESIGN] auto: generate呼び出し時にランダム生成したDB_PASSWORDを渡す" {
  rdw_auto_stub_services
  cd "$WS"
  run auto_service_run --target "$WS" --redmine 6.1.2 --fresh-db
  [ "$status" -eq 0 ]
  ! grep -q "DB_PASSWORD=\]" "$RDW_AUTO_CALL_LOG"
  grep -q "DB_PASSWORD=" "$RDW_AUTO_CALL_LOG"
}

# ---- 自己ロックによるauto自身のデッドロック (実機で発覚、design_log 2026-08-28エントリ参照) ----
# autoは自身のPIDでロックを取得したうえで、同一プロセス内でinit_service_run等を直接
# 関数呼び出しする。state_store_check_auto_lock() が「記録されたPID」と「自分自身の$$」を
# 区別しないと、autoの内部呼び出しがautoのロックを"他プロセスの実行中"と誤検知して
# 自己ブロックしてしまう（bin/redmine-docker-workspace auto --target ... を実機で実行し
# 「'auto' is currently running...」で即失敗する形で発覚）。

# state_store_check_auto_lock: 自プロセス自身（$$）が記録したロックは「ロックなし」扱いにする
@test "[RDC-REQ-F1424] state_store_check_auto_lock: 自プロセス自身のロックは自己ブロックしない" {
  echo "$$" > "$WS/.rdc_auto.lock"
  run state_store_check_auto_lock "$WS"
  [ "$status" -eq 0 ]
}

# state_store_check_auto_lock: 他の生存中プロセスのロックは引き続きブロックする（回帰確認）
@test "[RDC-REQ-F1424] state_store_check_auto_lock: 他プロセスの生存中ロックは引き続きブロックする" {
  ( sleep 30 ) & local other_pid=$!
  echo "$other_pid" > "$WS/.rdc_auto.lock"
  run state_store_check_auto_lock "$WS"
  [ "$status" -ne 0 ]
  [ "$output" = "$other_pid" ]
  kill "$other_pid" 2>/dev/null || true
  wait "$other_pid" 2>/dev/null || true
}

# auto: 自身が取得したロック保持中でも、内部で直接呼び出す実際の init_service_run が
# 自己ブロックしない（スタブではなく実処理での再現テスト。ユーザー報告の再現ケース）
@test "[RDC-DESIGN] auto: 自身のロック保持中でも実際のinitが自己ブロックしない（実処理での再現テスト）" {
  export RDC_ALLOW_MOCK=1
  cd "$WS"
  auto_service_acquire_lock "$WS"
  run init_service_run --target "$WS" --redmine 6.1.2
  auto_service_release_lock "$WS"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qi "currently running"
}

# ---- AutoService: --add-plugin (RDC-REQ-F1437, F1437A, F1438, F1439, F1440, F0994〜F0997) ----
# 設計: develop/docs/1A-DESIGN-F1415-auto-and-json-outputs.md 6A節

# auto_service_split_plugin_spec: #を含む場合、git_urlとrefに分割する
@test "[RDC-REQ-F1437A][RDC-REQ-F0997] auto_service_split_plugin_spec: #ref付きの場合、1行目git_url・2行目refを返す" {
  run auto_service_split_plugin_spec "https://github.com/x/y.git#v1.0.0"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | sed -n '1p')" = "https://github.com/x/y.git" ]
  [ "$(echo "$output" | sed -n '2p')" = "v1.0.0" ]
}

# auto_service_split_plugin_spec: #を含まない場合、1行目git_url・2行目は空
@test "[RDC-REQ-F1437A][RDC-REQ-F0997] auto_service_split_plugin_spec: #無しの場合、1行目git_url・2行目は空になる" {
  run auto_service_split_plugin_spec "https://github.com/x/y.git"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | sed -n '1p')" = "https://github.com/x/y.git" ]
  [ "$(echo "$output" | sed -n '2p')" = "" ]
}

# RDC-REQ-F1437, F0994: --add-plugin を1つ指定した場合、init後・generate前にadd-pluginが呼ばれる
@test "[RDC-REQ-F1437][RDC-REQ-F0994] auto: --add-plugin 指定時、initの後・generateの前にadd-pluginが呼ばれる" {
  rdw_auto_stub_services
  cd "$WS"
  run auto_service_run --target "$WS" --redmine 6.1.2 --fresh-db \
    --add-plugin https://example.com/plugin-a.git
  [ "$status" -eq 0 ]
  local actual
  actual=$(cut -d' ' -f1 "$RDW_AUTO_CALL_LOG")
  [ "$actual" = "init
add-plugin
generate
prepare-db
docker-compose-build
migrate
docker-compose-up
check" ]
  grep -q "^add-plugin https://example.com/plugin-a.git$" "$RDW_AUTO_CALL_LOG"
}

# RDC-REQ-F1437, F0995: --add-plugin を複数回指定した場合、指定順にすべて追加される
@test "[RDC-REQ-F1437][RDC-REQ-F0995] auto: --add-plugin を複数回指定した場合、指定順にすべて追加される" {
  rdw_auto_stub_services
  cd "$WS"
  run auto_service_run --target "$WS" --redmine 6.1.2 --fresh-db \
    --add-plugin https://example.com/plugin-a.git \
    --add-plugin https://example.com/plugin-b.git
  [ "$status" -eq 0 ]
  local actual
  actual=$(grep "^add-plugin" "$RDW_AUTO_CALL_LOG")
  [ "$actual" = "add-plugin https://example.com/plugin-a.git
add-plugin https://example.com/plugin-b.git" ]
}

# RDC-REQ-F1439, F0996: --add-plugin の実行が失敗した場合、generate以降は実行されない
@test "[RDC-REQ-F1439][RDC-REQ-F0996] auto: --add-plugin 失敗時は generate 以降を実行しない" {
  rdw_auto_stub_services "add-plugin"
  cd "$WS"
  run auto_service_run --target "$WS" --redmine 6.1.2 --fresh-db \
    --add-plugin https://example.com/plugin-a.git
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "add-plugin"
  ! grep -q "^generate" "$RDW_AUTO_CALL_LOG"
}

# RDC-REQ-F1437A, F0997: --add-plugin に URL#ref 形式を指定した場合、add-plugin へ --ref として引き継がれる
@test "[RDC-REQ-F1437A][RDC-REQ-F0997] auto: --add-plugin の URL#ref は add-plugin へ --ref として引き継がれる" {
  rdw_auto_stub_services
  cd "$WS"
  run auto_service_run --target "$WS" --redmine 6.1.2 --fresh-db \
    --add-plugin https://example.com/plugin-a.git#v1.0.0
  [ "$status" -eq 0 ]
  grep -q "^add-plugin https://example.com/plugin-a.git --ref v1.0.0$" "$RDW_AUTO_CALL_LOG"
}

# RDC-REQ-F1438: add-plugin専用オプション(--name/--force)はauto側から引き継がない
@test "[RDC-REQ-F1438] auto: --add-plugin は git_url/ref 以外(--name等)を add-plugin へ引き継がない" {
  rdw_auto_stub_services
  cd "$WS"
  run auto_service_run --target "$WS" --redmine 6.1.2 --fresh-db \
    --add-plugin https://example.com/plugin-a.git
  [ "$status" -eq 0 ]
  ! grep -q -- "--name" "$RDW_AUTO_CALL_LOG"
  ! grep -q -- "--force" "$RDW_AUTO_CALL_LOG"
}

# RDC-REQ-F1437: --add-plugin 未指定時は add-plugin が一切呼ばれない（既存動作に影響しない）
@test "[RDC-REQ-F1437] auto: --add-plugin 未指定時は add-plugin が呼ばれない" {
  rdw_auto_stub_services
  cd "$WS"
  run auto_service_run --target "$WS" --redmine 6.1.2 --fresh-db
  [ "$status" -eq 0 ]
  ! grep -q "^add-plugin" "$RDW_AUTO_CALL_LOG"
}
