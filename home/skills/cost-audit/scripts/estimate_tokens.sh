#!/usr/bin/env bash
# ファイルのトークン量を粗く見積る(監査用の目安。正確な計測は count_tokens API)。
# ヒューリスティック: ASCII ≈ 4文字/トークン、マルチバイト文字(日本語等) ≈ 1文字/トークン。
# UTF-8 前提: chars = wc -m, bytes = wc -c、日本語は概ね3バイト/文字なので
#   mb_chars ≈ (bytes - chars) / 2, ascii_chars = chars - mb_chars
set -euo pipefail

# wc -m がマルチバイトを正しく数えられるよう UTF-8 ロケールを強制する
if locale -a 2>/dev/null | grep -qi '^C\.utf-\?8$'; then
  export LC_ALL=C.UTF-8
elif locale -a 2>/dev/null | grep -qi '^en_US\.utf-\?8$'; then
  export LC_ALL=en_US.UTF-8
fi

if [ $# -eq 0 ]; then
  echo "usage: estimate_tokens.sh <file>..." >&2
  exit 1
fi

total=0
printf '%-50s %10s %10s %10s\n' "FILE" "CHARS" "MB_CHARS" "~TOKENS"
for f in "$@"; do
  if [ ! -f "$f" ]; then
    printf '%-50s %s\n' "$f" "(not found)"
    continue
  fi
  chars=$(wc -m < "$f")
  bytes=$(wc -c < "$f")
  mb=$(( (bytes - chars) / 2 ))
  [ "$mb" -lt 0 ] && mb=0
  ascii=$(( chars - mb ))
  tokens=$(( ascii / 4 + mb ))
  total=$(( total + tokens ))
  printf '%-50s %10d %10d %10d\n' "$f" "$chars" "$mb" "$tokens"
done
printf '%-50s %10s %10s %10d\n' "TOTAL" "" "" "$total"
echo ""
echo "注: このTOTALはキャッシュヒット時でも毎リクエスト約0.1倍で課金される固定費。"
echo "    合計 2,000 トークン以下を推奨、5,000 超はダイエット対象。"
