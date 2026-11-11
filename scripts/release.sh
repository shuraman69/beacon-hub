#!/usr/bin/env bash
# Выпуск новой версии: CHANGELOG → VERSION → universal zip → коммит и тег → push → GitHub Release.
#
#   make release              # patch: 0.2.0 → 0.2.1
#   make release BUMP=minor   # 0.2.0 → 0.3.0
#   make release V=1.0.0      # конкретная версия
#
# Текст релиза берётся из CHANGELOG.md: раздел «Не выпущено» превращается в раздел новой версии.
# Если раздел версии уже написан руками, используется он.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="shuraman69/beacon-hub"
BRANCH="main"

command -v gh >/dev/null || { echo "✗ нужен GitHub CLI: brew install gh && gh auth login"; exit 1; }
[[ "$(git rev-parse --abbrev-ref HEAD)" == "$BRANCH" ]] || { echo "✗ релиз выпускается только из ветки $BRANCH"; exit 1; }
# Незакоммиченными могут быть только CHANGELOG.md и VERSION: их коммитит сам скрипт.
dirty="$(git status --porcelain | grep -vE '^.. (CHANGELOG\.md|VERSION)$' || true)"
[[ -z "$dirty" ]] || { echo "✗ есть незакоммиченные изменения:"; echo "$dirty"; exit 1; }

CURRENT="$(cat VERSION)"
if [[ -n "${V:-}" ]]; then
  NEW="$V"
else
  IFS=. read -r MA MI PA <<<"$CURRENT"
  case "${BUMP:-patch}" in
    major) NEW="$((MA + 1)).0.0" ;;
    minor) NEW="$MA.$((MI + 1)).0" ;;
    patch) NEW="$MA.$MI.$((PA + 1))" ;;
    *) echo "✗ BUMP: patch | minor | major"; exit 1 ;;
  esac
fi
[[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "✗ версия должна быть вида 1.2.3"; exit 1; }
TAG="v$NEW"
git fetch --tags -q origin || true
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then echo "✗ тег $TAG уже есть"; exit 1; fi

NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT
python3 - "$NEW" "$REPO" "$NOTES" <<'PY'
import re, sys, datetime
new, repo, notes_path = sys.argv[1:]
path = "CHANGELOG.md"
text = open(path, encoding="utf-8").read()
U = "## [Не выпущено]"
if f"## [{new}]" not in text:
    start = text.index(U) + len(U)
    nxt = text.find("\n## [", start)
    body = text[start:nxt].strip()
    if not body:
        sys.exit("✗ раздел «Не выпущено» в CHANGELOG.md пуст: опиши изменения")
    today = datetime.date.today().isoformat()
    text = text[:start] + f"\n\n## [{new}] — {today}\n\n{body}\n" + text[nxt:]
    text = re.sub(r"^\[Не выпущено\]: .*$",
                  f"[Не выпущено]: https://github.com/{repo}/compare/v{new}...HEAD\n"
                  f"[{new}]: https://github.com/{repo}/releases/tag/v{new}", text, count=1, flags=re.M)
    open(path, "w", encoding="utf-8").write(text)
m = re.search(rf"^## \[{re.escape(new)}\][^\n]*\n(.*?)(?=^## \[|^\[)", text, re.S | re.M)
section = m.group(1).strip() if m else ""
if not section:
    sys.exit(f"✗ в CHANGELOG.md нет описания версии {new}")
install = """

---

### Установка
1. Скачай `BeaconHub-%s.zip`, распакуй и перетащи **Beacon Hub** в «Программы».
2. Сборка не нотаризована, поэтому один раз выполни в терминале:
   ```bash
   xattr -dr com.apple.quarantine "/Applications/Beacon Hub.app"
   ```
3. Запусти. Маяк появится в статус-баре.

Требуется macOS 14+. Работает на Apple Silicon и Intel.""" % new
open(notes_path, "w", encoding="utf-8").write(section + install)
PY

echo "$NEW" > VERSION
echo "▸ сборка $TAG"
./scripts/package.sh >/dev/null
ZIP="dist/BeaconHub-${NEW}.zip"
[[ -f "$ZIP" ]] || { echo "✗ не собрался $ZIP"; exit 1; }

git add CHANGELOG.md VERSION
git diff --cached --quiet || git commit -q -m "Release $TAG"
git tag -a "$TAG" -m "Beacon Hub $NEW"
git push -q origin "$BRANCH"
git push -q origin "$TAG"
gh release create "$TAG" "$ZIP" --repo "$REPO" --title "Beacon Hub $NEW" --notes-file "$NOTES"
echo "✓ https://github.com/$REPO/releases/tag/$TAG"
