---
name: cost-audit
description: Claude Code 設定のトークン消費・コスト監査。settings.json / CLAUDE.md / .mcp.json / agents / hooks を棚卸しし、コスト観点のチェックリストと照合してレポートと修正案を出す。Use when the user wants to audit, review, migrate, or optimize Claude Code settings, token usage, or costs(設定見直し・コスト削減・トークン使用量の調査・既存設定のマージ時)。
---

# cost-audit — Claude Code 設定のコスト監査

既存の Claude Code 設定をコスト観点で監査し、**重要度・推定インパクト付きのレポート**と**承認後の修正適用**を行う。

原則: **勝手に設定を書き換えない。** フェーズ4のレポートを提示し、ユーザーが選んだ項目だけをフェーズ5で適用する。

## フェーズ1: インベントリ収集

以下を存在するものすべて読み込む(存在しないものはレポートに「なし」と記録):

| 対象 | パス |
|---|---|
| ユーザー設定 | `~/.claude/settings.json` |
| プロジェクト設定 | `.claude/settings.json`, `.claude/settings.local.json` |
| マネージド設定 | `/etc/claude-code/managed-settings.json`(Linux)等 |
| グローバルメモリ | `~/.claude/CLAUDE.md` |
| プロジェクトメモリ | `CLAUDE.md`, `CLAUDE.local.md`, `.claude/CLAUDE.md`(@import 先も辿る) |
| MCP | `.mcp.json`, `~/.claude.json` 内の mcpServers、`claude mcp list` の結果 |
| エージェント | `~/.claude/agents/*.md`, `.claude/agents/*.md` |
| フック | 各 settings.json 内の `hooks`、参照先スクリプト |
| バックアップ | `~/.claude/backup-*/`(install.sh 由来。あれば新旧マージ監査モードで動く) |

環境変数も確認: `env | grep -E 'ANTHROPIC|CLAUDE_CODE|MAX_THINKING|DISABLE_'`
(settings.json の `env` とシェル環境の両方に同じ変数があると、どちらが効いているか分からなくなる — 二重定義は指摘対象)

## フェーズ2: 計測

1. **常時読み込みコンテキストのトークン量**: すべての CLAUDE.md(@import 先含む)に対して
   `bash ~/.claude/skills/cost-audit/scripts/estimate_tokens.sh <files...>` を実行。
2. **MCP のツール定義量**: 接続サーバー数とツール数を数える。ツール定義は**毎リクエストの入力トークン**になる(1サーバーあたり数百〜数千トークン)。
3. **permissions の網羅性**: deny に生成物・ロックファイル・シークレットが含まれているか。

## フェーズ3: チェックリスト照合

[references/checklist.md](references/checklist.md) を読み、全項目を照合する。カテゴリ:

- **A. モデル選択** — メイン/バックグラウンド/サブエージェントのモデル指定
- **B. プロンプトキャッシュ** — キャッシュを壊す設定(動的コンテンツ、キャッシュ無効化変数)
- **C. コンテキスト** — CLAUDE.md 肥大化、MCP 過剰、deny 不足
- **D. thinking / 出力** — 常時 thinking、出力上限
- **E. 可視化・運用** — ステータスライン、テレメトリ

## フェーズ4: レポート

以下の形式で提示する:

```
# コスト監査レポート (YYYY-MM-DD)

## サマリ
- 常時読み込みコンテキスト: 約 N トークン/リクエスト(内訳: ...)
- 検出: Critical X件 / High Y件 / Medium Z件

## 検出事項(重要度順)
### [Critical] <タイトル>
- 現状: <ファイル:該当箇所>
- 問題: <なぜコストになるか。可能なら概算数値>
- 修正案: <具体的な diff または設定値>

## 適用する修正を選んでください
1. ... 2. ... (all / 番号 / none)
```

推定インパクトは誇張しない。数値化できないものは「定性的」と明記する。

## フェーズ5: 適用(承認後のみ)

- 変更前に対象ファイルを `<file>.bak-<timestamp>` として退避
- 選択された修正のみ適用し、適用結果を差分で報告
- settings.json の変更後は JSON として妥当か検証(`jq . <file>`)

## マージ監査モード(バックアップがある場合)

`~/.claude/backup-*/` に旧設定がある場合は、新旧を項目単位で比較し:
- 旧設定にしかない項目 → 「引き継ぐべき」「コスト観点で廃止すべき」に分類して提案
- 衝突する項目 → 両方の値とコスト影響を並べてユーザーに選択させる
