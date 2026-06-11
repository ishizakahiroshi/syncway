# dev-vps-sync

開発 VPS とローカルの間を `rsync over ssh` で双方向同期する汎用スクリプト集。
特定プロジェクト非依存（接続先・リモート/ローカルパス・除外・SSH 鍵はすべて引数/環境変数で指定）。
スクリプト本体に秘匿情報を一切埋め込まない設計。

## 特徴

- **双方向**: ダウンロード（VPS → ローカル）／アップロード（ローカル → VPS）の両対応。
- **Windows ファースト**: PowerShell 版は WSL の rsync → `rsync.exe` の順で自動フォールバック。bash 版は cwrsync / Docker tar モードに対応。
- **Docker コンテナへ直接同期**: 対象ファイルがコンテナ内部 FS にしか無い構成でも、`--rsync-path="docker exec -i <container> rsync"` を使ってコンテナ内へ push できる。tar 丸ごとコピーと違い、dry-run・差分・削除プレビュー・上書き保護がすべて有効。
- **アップロードの安全装置**: 削除はデフォルト無効。`-Delete` を付けても確認フラグが無ければプレビュー（強制 dry-run）のみで、実削除には明示的な確認が必要。`--update`（上書き保護）で VPS 側の新しいファイルを古いローカルで潰す事故を防ぐ。

## script/

- `sync-from-dev-server.ps1` / `.sh` — ダウンロード（VPS → ローカル）。
- `sync-to-dev-server.ps1` / `.sh` — アップロード（ローカル → VPS）。

## ダウンロード（VPS → ローカル）

PowerShell:

```powershell
.\script\sync-from-dev-server.ps1 `
  -Remote ubuntu@dev.example.com `
  -RemotePath /home/<user>/dev/myproj/ `
  -LocalPath  C:\projects\myproj `
  -Exclude docs/local/,node_modules/ `
  -DryRun
```

bash:

```bash
REMOTE_PATH=/home/<user>/dev/myproj/ LOCAL_PATH=/c/projects/myproj/ \
  ./script/sync-from-dev-server.sh ubuntu@dev.example.com --dry-run
```

## アップロード（ローカル → VPS）

PowerShell:

```powershell
# 追加・更新のみ（安全。リモートの余分なファイルは残す）
.\script\sync-to-dev-server.ps1 `
  -Remote ubuntu@dev.example.com `
  -RemotePath /home/<user>/dev/myproj/ `
  -LocalPath  C:\projects\myproj `
  -SshKey     C:\projects\.ssh\id_ed25519 `
  -Exclude    node_modules/,dist/ `
  -DryRun

# Docker コンテナ内へ push（コンテナに rsync が入っていること）
.\script\sync-to-dev-server.ps1 `
  -Remote ubuntu@dev.example.com `
  -RemotePath /home/<user>/work/myproj/ `
  -LocalPath  C:\projects\myproj `
  -SshKey     C:\projects\.ssh\id_ed25519 `
  -Container  my_container
```

bash:

```bash
REMOTE_PATH=/home/<user>/dev/myproj/ LOCAL_PATH=/c/projects/myproj/ SSH_KEY=/c/projects/.ssh/id_ed25519 \
  ./script/sync-to-dev-server.sh ubuntu@dev.example.com --dry-run
```

### 削除（完全ミラー）の安全な手順

リモートをローカルと完全一致させる（ローカルに無いファイルを VPS から消す）場合は二段階：

```powershell
# 1) まず何が消えるかプレビュー（-Delete 単体は強制 dry-run。実削除しない）
.\script\sync-to-dev-server.ps1 -Remote ... -RemotePath ... -LocalPath ... -Delete

# 2) 消える一覧に納得したら -ConfirmDelete を付けて実行
.\script\sync-to-dev-server.ps1 -Remote ... -RemotePath ... -LocalPath ... -Delete -ConfirmDelete
```

bash は `--delete`（プレビュー）→ `--delete --confirm-delete`（実削除）。

## オプション一覧（アップロード）

| PowerShell | bash | 説明 |
|---|---|---|
| `-Remote` | 第1引数 | SSH ターゲット `user@host`（必須） |
| `-RemotePath` | `REMOTE_PATH` | リモートの宛先ディレクトリ（必須） |
| `-LocalPath` | `LOCAL_PATH` | ローカルの送信元ディレクトリ（必須） |
| `-SshKey` | `SSH_KEY` | SSH 秘密鍵のパス |
| `-Port` | `SSH_PORT` | SSH ポート（既定 22） |
| `-Exclude` | `EXCLUDES` | 追加の除外パターン（`.git/` は常に除外） |
| `-Container` | `--container=` / `CONTAINER` | Docker コンテナ内へ push |
| `-Update` | `--update` | リモートが新しければスキップ（上書き保護） |
| `-Delete` | `--delete` | 完全ミラー（単体ではプレビューのみ） |
| `-ConfirmDelete` | `--confirm-delete` | `-Delete` と併用で実削除 |
| `-IncludeGit` | `--include-git` | `.git/` を除外しない |
| `-DryRun` | `--dry-run` / `-d` | プレビューのみ |

## 注意

接続先の実値（host / 鍵パス / Docker コンテナ名）は各自のローカル設定から渡すこと。
スクリプト自体には秘匿情報を埋め込まない。
