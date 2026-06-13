# Syncway

[English README](README.md)

リモートサーバー（SSH で繋がる相手なら何でも）とローカルマシンの間を `rsync over ssh` で双方向同期する、汎用スクリプト集です。スクリプト本体に秘匿情報を一切埋め込みません。

<p align="center">
  <img src="assets/how-it-works.svg" alt="Syncway: ローカル→リモートのアップロードとリモート→ローカルのダウンロードを rsync/ssh で双方向に。Docker コンテナ同期と削除ガードに対応" width="860">
</p>

ここで言う「リモートサーバー」とは SSH で到達できるもの全般を指します — VPS、専用/物理サーバー、Raspberry Pi、社内 LAN の別マシン、あるいはそれらの上で動く Docker コンテナ。特定プロジェクトに非依存です。接続先・リモート/ローカルパス・除外・SSH 鍵・ポート・Docker コンテナはすべて引数または環境変数で渡します。秘匿情報がリポジトリに残らないので、公開しても安全で、プロジェクトをまたいで使い回せます。

## 特徴

- **双方向** — ダウンロード（リモート → ローカル）／アップロード（ローカル → リモート）。
- **Windows ファースト** — PowerShell 版はネイティブ `rsync.exe`（cwrsync 等）を使い、WSL を自動起動しません（裏で勝手に立ち上がらない）。WSL を使いたい時だけ `-UseWsl` でオプトイン。bash 版は cwrsync（Scoop）を自動検出し `/cygdrive` 形式へパス変換。
- **Docker コンテナへ直接同期** — 対象ファイルがコンテナ内部 FS にしか無くても、`--rsync-path="docker exec -i <name> rsync"` でコンテナの中へ直接 push / pull できます。`tar` 丸ごとコピーと違い、dry-run・差分・削除プレビュー・上書き保護がすべて有効なまま。
- **対称な削除ガード** — 削除は**両方向ともデフォルト無効**。`--delete` / `-Delete` 単体ではプレビュー（強制 dry-run）のみ。実削除には `--confirm-delete` / `-ConfirmDelete` の明示が必要です。
- **スクリプトに秘密を持たない** — host・鍵パス・ポート・コンテナ名はローカル設定から渡し、リポジトリには入れません。

## スクリプト

| スクリプト | 方向 |
|---|---|
| `script/sync-from-dev-server.ps1` / `.sh` | ダウンロード（リモート → ローカル） |
| `script/sync-to-dev-server.ps1` / `.sh`   | アップロード（ローカル → リモート） |

## クイックスタート

何かを変更する前に、必ず `-DryRun` / `--dry-run` でプレビューしてください。

### ダウンロード（リモート → ローカル）

PowerShell:

```powershell
.\script\sync-from-dev-server.ps1 `
  -Remote     ubuntu@dev.example.com `
  -RemotePath /home/<user>/dev/myproj/ `
  -LocalPath  C:\projects\myproj `
  -Exclude    node_modules/,docs/local/ `
  -DryRun
```

bash:

```bash
REMOTE_PATH=/home/<user>/dev/myproj/ LOCAL_PATH=/c/projects/myproj/ \
  ./script/sync-from-dev-server.sh ubuntu@dev.example.com --dry-run
```

### アップロード（ローカル → リモート）

PowerShell:

```powershell
.\script\sync-to-dev-server.ps1 `
  -Remote     ubuntu@dev.example.com `
  -RemotePath /home/<user>/dev/myproj/ `
  -LocalPath  C:\projects\myproj `
  -SshKey     C:\projects\.ssh\id_ed25519 `
  -Exclude    node_modules/,dist/ `
  -DryRun
```

bash:

```bash
REMOTE_PATH=/home/<user>/dev/myproj/ LOCAL_PATH=/c/projects/myproj/ SSH_KEY=/c/projects/.ssh/id_ed25519 \
  ./script/sync-to-dev-server.sh ubuntu@dev.example.com --dry-run
```

## 削除（完全ミラー）の安全な手順

デフォルトではどちらの方向も削除しません（宛先の余分なファイルはそのまま残します）。宛先を送信元と完全一致させる（送信元に無いファイルを宛先から消す）場合は、二段階で行います。

```powershell
# 1) 何が消えるかプレビュー（-Delete 単体は強制 dry-run。何も変更しない）
.\script\sync-to-dev-server.ps1 -Remote ... -RemotePath ... -LocalPath ... -Delete

# 2) "deleting ..." の一覧に納得したら適用
.\script\sync-to-dev-server.ps1 -Remote ... -RemotePath ... -LocalPath ... -Delete -ConfirmDelete
```

bash は `--delete`（プレビュー）→ `--delete --confirm-delete`（適用）。ダウンロード側も同じ作法で、こちらは**ローカル**ファイルが削除対象になります。アップロード側には `-Update` / `--update` もあり、リモートのほうが新しいファイルはスキップするので、古いローカルでサーバー側の変更を潰す事故を防げます。

## Docker コンテナへの同期

対象ファイルがコンテナ内部 FS にしか無い場合は、rsync をそのコンテナへ向けます。コンテナ側に `rsync` がインストールされている必要があり、`RemotePath` は**コンテナ内のパス**として解釈されます。

```powershell
# コンテナへアップロード
.\script\sync-to-dev-server.ps1 `
  -Remote     ubuntu@dev.example.com `
  -RemotePath /home/<user>/work/myproj/ `
  -LocalPath  C:\projects\myproj `
  -SshKey     C:\projects\.ssh\id_ed25519 `
  -Container  my_container
```

```bash
# コンテナからダウンロード
REMOTE_PATH=/app/ LOCAL_PATH=/c/projects/app/ \
  ./script/sync-from-dev-server.sh ubuntu@dev.example.com --container=my_container --dry-run
```

## AI エージェントにセットアップを任せる

AI コーディングエージェント（Claude Code / Codex / Cursor など）を使っているなら、同期の設定自体を任せられます。リポジトリを clone し、**Syncway フォルダの中で**エージェントを開いて、下のプロンプトを貼ってください。

```text
このリポジトリの Syncway を使って、私のプロジェクトをリモートサーバーと同期する設定をして。

1. 次を私に聞いて: SSH ターゲット (user@host)、リモートパス、ローカルパス、
   （非標準なら）SSH 鍵パスとポート、ファイルが Docker コンテナ内にあるか。
2. 私の意図から方向を決めて（サーバーから取得＝ダウンロード、
   サーバーへ送る＝アップロード）。
3. 必ず最初に dry-run を実行して、使う「source -> destination」と何が変わるかを
   正確に見せて。
4. 削除プレビューを私が明示的に承認するまで、--confirm-delete / -ConfirmDelete は
   絶対に付けないで。デフォルトは追加のみ（削除なし）の同期にして。
5. 私が自分で再実行できるように、最終的なコマンドを返して。

安全第一: 必ず dry-run 先行、私の明示確認なしに削除しない、host・鍵パス・
コンテナ名をコミット対象ファイルに絶対に書かないこと。
```

> **dry-run は自分の目で確認すること。** エージェントはリモートパスや方向を
> 取り違えることがあります。本実行の前に、dry-run 出力の
> `source -> destination` 行を必ず自分で確かめてください。

## オプション一覧（アップロード）

| PowerShell | bash | 説明 |
|---|---|---|
| `-Remote` | 第1引数 | SSH ターゲット `user@host`（必須） |
| `-RemotePath` | `REMOTE_PATH` | リモートの宛先ディレクトリ（必須） |
| `-LocalPath` | `LOCAL_PATH` | ローカルの送信元ディレクトリ（必須） |
| `-SshKey` | `SSH_KEY` | SSH 秘密鍵のパス |
| `-Port` | `SSH_PORT` | SSH ポート（既定 22） |
| `-Exclude` | `EXCLUDES` | 追加の除外パターン（`.git/` は常に除外） |
| `-Container` | `--container=` / `CONTAINER` | Docker コンテナへ同期 |
| `-Update` | `--update` | リモートが新しければスキップ（上書き保護） |
| `-Delete` | `--delete` | 完全ミラー（単体ではプレビューのみ） |
| `-ConfirmDelete` | `--confirm-delete` | `-Delete` と併用で実削除 |
| `-IncludeGit` | `--include-git` | `.git/` を除外しない |
| `-UseWsl` | なし（bash 版は WSL を使わない） | WSL の rsync を使う（既定はネイティブ `rsync.exe` のみ・`SYNCWAY_USE_WSL=1` でも可） |
| `-DryRun` | `--dry-run` / `-d` | プレビューのみ |

ダウンロード側も同じオプション体系です（`-Update` はアップロード専用なので除く）。ダウンロードでの `-Delete` はローカルファイルに作用します。

## 注意

- 接続先の実値（host / 鍵パス / コンテナ名）は各自のローカル設定から渡してください。リポジトリには入れないこと。
- 末尾スラッシュは rsync の意味論に従います。スクリプトが送信元/宛先を正規化するので `myproj` と `myproj/` は同じ挙動になります。
- `docs/local/` と `.claude/` は、ローカル限定の運用メモ・設定用に gitignore 済みです。

## ライセンス

MIT License. [LICENSE](LICENSE) を参照。
