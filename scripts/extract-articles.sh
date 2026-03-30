#!/usr/bin/env bash
#
# extract-articles.sh
# ====================
# kanoyakijien リポジトリから記事を抽出して別ディレクトリにコピー
#
# 使い方:
#   ./extract-articles.sh <コピー先ディレクトリ>
#   ./extract-articles.sh --json <コピー先ディレクトリ>
#   ./extract-articles.sh --dry-run <コピー先ディレクトリ>
#
# リポジトリ外から使う場合（git clone して抽出）:
#   KANOYA_REPO=https://github.com/marron1984/kanoyakijien.git \
#   ./extract-articles.sh /path/to/dest
#

set -euo pipefail

# ─── 設定 ───
REMOTE_REPO="${KANOYA_REPO:-https://github.com/marron1984/kanoyakijien.git}"
BRANCH="claude/nara-luxury-travel-article-lutUZ"

# ─── 引数パース ───
FMT="md"
DRY=false
DEST=""

for arg in "$@"; do
  case "$arg" in
    --json)    FMT="json" ;;
    --dry-run) DRY=true ;;
    --help|-h)
      sed -n '2,/^$/s/^#//p' "$0"
      exit 0 ;;
    *) DEST="$arg" ;;
  esac
done

[[ -n "$DEST" ]] || { echo "エラー: コピー先を指定 → $0 --help"; exit 1; }

# ─── ソース特定 ───
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)/articles"

if [[ ! -d "$SRC" ]]; then
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  echo "📥 クローン中..."
  git clone -b "$BRANCH" --depth 1 "$REMOTE_REPO" "$TMP/repo" 2>&1 | tail -1
  SRC="$TMP/repo/articles"
fi

[[ -d "$SRC" ]] || { echo "エラー: articles/ が見つかりません"; exit 1; }

COUNT=$(ls "$SRC"/*.md 2>/dev/null | wc -l)
echo "📂 $COUNT 記事を検出 ($SRC)"

# ─── slug 取得ヘルパー ───
get_meta() { grep -m1 "^$1:" "$2" | sed "s/^$1:[[:space:]]*//;s/^\"\(.*\)\"$/\1/"; }

# ─── dry-run ───
if $DRY; then
  echo ""
  echo "ファイル一覧 (slug.${FMT}):"
  for f in "$SRC"/*.md; do
    slug=$(get_meta slug "$f")
    title=$(get_meta title "$f")
    printf "  %-50s  %s\n" "${slug}.${FMT}" "$title"
  done
  echo ""
  echo "合計 $COUNT 記事 → $DEST/"
  exit 0
fi

# ─── コピー実行 ───
mkdir -p "$DEST"

if [[ "$FMT" == "md" ]]; then
  # Markdown: slug をファイル名にしてコピー
  for f in "$SRC"/*.md; do
    slug=$(get_meta slug "$f")
    cp "$f" "$DEST/${slug}.md"
  done
  echo "✅ $COUNT 記事を Markdown でコピー → $DEST/"

elif [[ "$FMT" == "json" ]]; then
  # JSON: frontmatter + body を JSON に変換
  python3 - "$SRC" "$DEST" <<'PYEOF'
import sys, os, json, re, glob

src, dest = sys.argv[1], sys.argv[2]
os.makedirs(dest, exist_ok=True)
count = 0

for filepath in sorted(glob.glob(os.path.join(src, "*.md"))):
    with open(filepath, "r") as f:
        raw = f.read()

    # --- frontmatter --- body を分離
    parts = raw.split("---", 2)
    if len(parts) < 3:
        continue
    fm_text, body = parts[1].strip(), parts[2].strip()

    # 簡易 YAML → dict
    meta = {}
    cur_list = None
    for line in fm_text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        # リスト項目
        if stripped.startswith("- ") and cur_list is not None:
            val = stripped[2:].strip().strip('"')
            meta[cur_list].append(val)
            continue
        # キー: 値
        m = re.match(r'^(\w+):\s*(.*)', stripped)
        if m:
            key, val = m.group(1), m.group(2).strip().strip('"')
            cur_list = None
            if val.startswith("[") and val.endswith("]"):
                # インライン配列
                meta[key] = [v.strip().strip('"') for v in val[1:-1].split(",") if v.strip()]
            elif val == "":
                meta[key] = []
                cur_list = key
            else:
                # 数値変換
                try:
                    meta[key] = int(val)
                except ValueError:
                    meta[key] = val

    slug = meta.get("slug", os.path.basename(filepath).replace(".md", ""))
    meta["body_markdown"] = body

    out_path = os.path.join(dest, f"{slug}.json")
    with open(out_path, "w") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)
    count += 1

print(f"✅ {count} 記事を JSON でコピー → {dest}/")
PYEOF
fi
