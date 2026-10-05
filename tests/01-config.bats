#!/usr/bin/env bats

load 'test_helper/common'

setup() {
  load_wt
  setup_config
}

teardown() {
  teardown_config
}

# --- load_config ---

@test "load_config: loads key=value from config file into env" {
  echo "WT_FEATURE_PREFIX=ticket/" > "$WT_CONFIG_FILE"
  load_config
  assert_equal "$WT_FEATURE_PREFIX" "ticket/"
}

@test "load_config: does nothing when config file does not exist" {
  rm -f "$WT_CONFIG_FILE"
  run load_config
  assert_success
}

# --- save_config_value ---

@test "save_config_value: writes a new key to config file" {
  save_config_value "WT_LIST_LIMIT" "50"
  run grep -x 'WT_LIST_LIMIT="50"' "$WT_CONFIG_FILE"
  assert_success
}

@test "save_config_value: updates an existing key without duplicating it" {
  echo "WT_LIST_LIMIT=20" > "$WT_CONFIG_FILE"
  save_config_value "WT_LIST_LIMIT" "99"
  local count
  count=$(grep -c "^WT_LIST_LIMIT=" "$WT_CONFIG_FILE")
  assert_equal "$count" "1"
  run grep -x 'WT_LIST_LIMIT="99"' "$WT_CONFIG_FILE"
  assert_success
}

@test "save_config_value: handles value with pipe character" {
  save_config_value "WT_FEATURE_PREFIX" "feat|fix/"
  run grep -xF 'WT_FEATURE_PREFIX="feat|fix/"' "$WT_CONFIG_FILE"
  assert_success
}

@test "save_config_value: handles value with ampersand" {
  save_config_value "WT_FEATURE_PREFIX" "feat&fix/"
  run grep -xF 'WT_FEATURE_PREFIX="feat&fix/"' "$WT_CONFIG_FILE"
  assert_success
}

# --- get_config_value ---

@test "get_config_value: returns value for existing key" {
  echo "WT_LIST_LIMIT=42" > "$WT_CONFIG_FILE"
  run get_config_value "WT_LIST_LIMIT" "20"
  assert_output "42"
}

@test "get_config_value: returns default when key is absent" {
  run get_config_value "WT_MISSING_KEY" "fallback"
  assert_output "fallback"
}
