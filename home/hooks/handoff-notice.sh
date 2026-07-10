#!/usr/bin/env bash
# SessionStart フック: /clear 後・新セッション開始時の作業再開を最小トークンで実現する。
#
# 仕組み(progressive disclosure):
#   - 引き継ぎメモ(.claude/handoff.md)が存在する場合、その「存在を知らせる数行」
#     だけをコンテキストに注入する(実測 約110トークン、ファイル存在時のみ)。
#   - 本文はユーザーの依頼が続きの作業だった場合にのみ Read される。
#   - 常駐メモリ(CLAUDE.md への自動追記等)と違い、毎リクエストの固定費にならない。
#
# ついでに、予算ガードが /tmp に残す警告マーカーの古いものを掃除する。
set -u

input=$(cat 2>/dev/null || true)

# 古い警告マーカーの掃除(2日以上前のもの)
find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'claude-budget-*' -mtime +2 -delete 2>/dev/null || true

# 仕様ドリフト検知③: Claude Code 本体の更新を検知したら再監査を促す
# (実行ファイルのフィンガープリント比較。stat のみ、コストゼロ)
cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
bin=$(command -v claude 2>/dev/null || true)
if [ -n "$bin" ]; then
  real=$(readlink -f "$bin" 2>/dev/null || echo "$bin")
  fp=$(stat -c '%s %Y' "$real" 2>/dev/null || stat -f '%z %m' "$real" 2>/dev/null || true)
  vf="$cfg/.claude-code-fingerprint"
  if [ -n "$fp" ]; then
    old=$(cat "$vf" 2>/dev/null || true)
    if [ -z "$old" ]; then
      printf '%s' "$fp" > "$vf" 2>/dev/null || true
    elif [ "$old" != "$fp" ]; then
      printf '%s' "$fp" > "$vf" 2>/dev/null || true
      echo "Claude Code 本体が更新されています。仕様変更でコスト管理設定(フック・監査)の前提が変わっている可能性があります。区切りの良いところで selftest_guard.sh による自己診断と /cost-audit の実行をユーザーに提案してください。"
    fi
  fi
fi

cwd=""
if command -v jq >/dev/null 2>&1 && [ -n "$input" ]; then
  cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
fi
[ -n "$cwd" ] || cwd="$PWD"

handoff="$cwd/.claude/handoff.md"
[ -f "$handoff" ] || exit 0

# 48時間より古いメモは案内しない(陳腐化したメモの誤再開を防ぐ)
if ! find "$handoff" -mtime -2 2>/dev/null | grep -q .; then
  exit 0
fi

# SessionStart フックの stdout はコンテキストに追加される
cat <<'EOF'
前回セッションからの引き継ぎメモが .claude/handoff.md にあります(未完了作業の再開用)。
- ユーザーの依頼がその続きに関係する場合のみ読み込んで再開すること。無関係なタスクなら読み込まない。
- 引き継いだ作業が完了したら .claude/handoff.md を削除すること。
EOF
exit 0
