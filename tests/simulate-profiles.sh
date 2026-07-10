#!/usr/bin/env bash
# 実用タスクプロファイルのシミュレーション
#
# 現実的なセッション3種のトランスクリプトを合成し、フックパイプラインに通して
# 「10ターン ≒ $1」目標に対する実測(推定)コストとガードの振る舞いを検証する。
#
#   A. 軽微な修正タスク(本設定の最適化が効いた状態)
#      キャッシュが効き、探索は絞られ、出力は簡潔 → 目標内で完走することを検証
#   B. 探索の多い調査タスク: explore 委譲あり vs なし の比較
#      委譲(Haiku・コンテキスト隔離)の削減率を定量化
#   C. アンチパターン(キャッシュ崩壊+巨大ファイル読み込み)
#      ペースガード → 上限ブロック+グレースレーンが正しく作動することを検証
#
# 単価モデルはガードと同一(sonnet 3/15, haiku 1/5, cache書込1.25x, 読出0.1x)。
# 使い方: bash tests/simulate-profiles.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/home/hooks/session-budget-guard.sh"

SB="$(mktemp -d)"
cleanup() { rm -rf "$SB"; rm -f "${TMPDIR:-/tmp}"/claude-budget-*-sim* 2>/dev/null; }
trap cleanup EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
ng() { FAIL=$((FAIL+1)); printf '  NG  %s\n' "$1"; }

user_line()  { printf '{"uuid":"u%s","type":"user","message":{"role":"user","content":"p%s"}}\n' "$1" "$1"; }
usage_line() { # id model in cc cr out
  printf '{"uuid":"a%s","type":"assistant","message":{"id":"m%s","model":"%s","usage":{"input_tokens":%d,"cache_creation_input_tokens":%d,"cache_read_input_tokens":%d,"output_tokens":%d}}}\n' \
    "$1" "$1" "$2" "$3" "$4" "$5" "$6"
}
guard_in() { # event session tool fpath transcript
  printf '{"hook_event_name":"%s","transcript_path":"%s","session_id":"%s","tool_name":"%s","tool_input":{"file_path":"%s"}}' "$1" "$5" "$2" "$3" "$4"
}
state_cost() { awk -v r="$(awk '{print $2}' "${TMPDIR:-/tmp}/claude-budget-state-$1" 2>/dev/null || echo 0)" 'BEGIN{printf "%.3f", r/1000000}'; }

echo "======================================================================"
echo " プロファイル A: 軽微な修正タスク(10ターン・最適化が効いた状態)"
echo "  想定: 安定した CLAUDE.md/ツール構成でキャッシュヒット、探索は Grep で"
echo "  絞り込み、出力は変更箇所のみ。新規入力2k+キャッシュ書込2.5k+読出15k〜、出力1.5k/ターン"
echo "======================================================================"
TR="$SB/a.jsonl"; SID=sim-a
: > "$TR"
blocked=0
for i in $(seq 1 10); do
  user_line "$i" >> "$TR"
  usage_line "$i" claude-sonnet-5 2000 2500 $((15000 + 2500 * i)) 1500 >> "$TR"
  guard_in PreToolUse $SID Read x "$TR" | bash "$GUARD" >/dev/null 2>&1 || blocked=$((blocked + 1))
done
costA=$(state_cost $SID)
echo "  10ターン実測(推定): \$${costA} / 目標 \$1.00 / ガード介入 ${blocked}回"
awk -v c="$costA" 'BEGIN{exit !(c <= 1.0)}' && ok "目標内で完走 (\$${costA} ≤ \$1.00)" || ng "目標超過 (\$${costA})"
[ "$blocked" -eq 0 ] && ok "正常作業への誤介入なし" || ng "誤介入 ${blocked}回"

echo ""
echo "======================================================================"
echo " プロファイル B: 探索の多い調査タスク(6ターン・計90kトークン相当の読み込み)"
echo "======================================================================"
# B-1: explore 委譲あり — 読み込みは Haiku サブエージェント側の文脈で消費され、
#      メイン文脈は小さいまま(読み込み30k×3回は haiku の入力として計上)
TR="$SB/b1.jsonl"; SID=sim-b1
: > "$TR"
for i in $(seq 1 6); do
  user_line "$i" >> "$TR"
  usage_line "$i" claude-sonnet-5 1500 2000 12000 1000 >> "$TR"
done
for j in 1 2 3; do
  usage_line "h$j" claude-haiku-4-5 30000 0 0 2000 >> "$TR"
done
guard_in PreToolUse $SID Read x "$TR" | bash "$GUARD" >/dev/null 2>&1
costB1=$(state_cost $SID)

# B-2: 委譲なし — 90k がメイン(Sonnet)の文脈に載り、以降のターンでも再送され続ける
TR="$SB/b2.jsonl"; SID=sim-b2
: > "$TR"
cr=12000
for i in $(seq 1 6); do
  user_line "$i" >> "$TR"
  cc=0; [ "$i" -le 3 ] && cc=30000   # 前半3ターンで30kずつ読み込み(キャッシュ書込)
  usage_line "$i" claude-sonnet-5 1500 "$cc" "$cr" 1000 >> "$TR"
  cr=$((cr + cc))                     # 読んだ内容は以降の全ターンの入力に残留
done
guard_in PreToolUse $SID Read x "$TR" | bash "$GUARD" >/dev/null 2>&1
costB2=$(state_cost $SID)

save=$(awk -v a="$costB1" -v b="$costB2" 'BEGIN{printf "%.0f", (1 - a / b) * 100}')
echo "  委譲あり: \$${costB1} / 委譲なし: \$${costB2} → 削減率 ${save}%"
awk -v a="$costB1" -v b="$costB2" 'BEGIN{exit !(a < b * 0.7)}' \
  && ok "explore 委譲で 30% 以上の削減を確認 (${save}%)" || ng "委譲の削減効果が想定未満 (${save}%)"
awk -v a="$costB1" 'BEGIN{exit !(a * 10 / 6 <= 1.0)}' \
  && ok "委譲ありは10ターン換算でも目標内 (\$$(awk -v a="$costB1" 'BEGIN{printf "%.2f", a*10/6}'))" \
  || ng "委譲ありでも10ターン換算が目標超過"

echo ""
echo "======================================================================"
echo " プロファイル C: アンチパターン(キャッシュ崩壊 + 巨大ファイル読み込み)"
echo "  想定: 動的注入でキャッシュ全滅(毎ターン60kフル単価入力)+ 長大出力"
echo "======================================================================"
TR="$SB/c.jsonl"; SID=sim-c
: > "$TR"
pace_warned=0
for i in $(seq 1 5); do
  user_line "$i" >> "$TR"
  usage_line "$i" claude-sonnet-5 60000 0 0 3000 >> "$TR"
  guard_in PreToolUse $SID Read x "$TR" | bash "$GUARD" >/dev/null 2>&1 || pace_warned=$((pace_warned + 1))
done
costC=$(state_cost $SID)
echo "  5ターン実測: \$${costC}(10ターン換算 \$$(awk -v c="$costC" 'BEGIN{printf "%.2f", c*2}'))"
[ "$pace_warned" -ge 1 ] && ok "ペースガードが逸脱を検知・介入 (${pace_warned}回)" || ng "ペースガード未発火"
# さらに暴走 → 上限($5)超過
user_line 6 >> "$TR"
usage_line 6 claude-sonnet-5 60000 0 0 300000 >> "$TR"
guard_in PreToolUse $SID Bash "" "$TR" | bash "$GUARD" >/dev/null 2>&1; e1=$?
guard_in PreToolUse $SID Write /x/.claude/handoff.md "$TR" | bash "$GUARD" >/dev/null 2>&1; e2=$?
[ "$e1" = "2" ] && ok "上限超過で強制ブロック" || ng "上限ブロック失敗 (exit=$e1)"
[ "$e2" = "0" ] && ok "ブロック中も引き継ぎ保存は可能(グレースレーン)" || ng "グレースレーン失敗 (exit=$e2)"

echo ""
echo "======================================================================"
echo " サマリ"
echo "======================================================================"
printf '  %-42s %10s %s\n' "プロファイル" "10T換算" "判定"
printf '  %-42s %10s %s\n' "A: 軽微な修正(最適化あり)" "\$${costA}" "目標内・無干渉"
printf '  %-42s %10s %s\n' "B: 調査+explore委譲" "\$$(awk -v a="$costB1" 'BEGIN{printf "%.2f", a*10/6}')" "目標内(委譲なし比 -${save}%)"
printf '  %-42s %10s %s\n' "C: アンチパターン" "\$$(awk -v c="$costC" 'BEGIN{printf "%.2f", c*2}')" "ガードが検知・遮断"
echo ""
echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
