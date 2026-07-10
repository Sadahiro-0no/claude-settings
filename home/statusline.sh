#!/usr/bin/env bash
# ステータスライン: モデル / セッションコスト / 変更行数 を常時表示してコストを可視化する。
# Claude Code から JSON が stdin で渡される。jq が無い環境ではモデル名のみ表示。
set -u
input=$(cat)

if ! command -v jq >/dev/null 2>&1; then
  printf '[claude] jq未導入のためコスト表示不可'
  exit 0
fi

model=$(printf '%s' "$input" | jq -r '.model.display_name // .model.id // "?"')
cost=$(printf '%s' "$input" | jq -r '.cost.total_cost_usd // empty')
added=$(printf '%s' "$input" | jq -r '.cost.total_lines_added // empty')
removed=$(printf '%s' "$input" | jq -r '.cost.total_lines_removed // empty')

out="[$model]"
if [ -n "$cost" ]; then
  out="$out \$$(printf '%.4f' "$cost")"
fi
if [ -n "$added" ] || [ -n "$removed" ]; then
  out="$out +${added:-0}/-${removed:-0}"
fi
printf '%s' "$out"
