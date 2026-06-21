# Vaultwarden + PostgreSQL 自動化雲端備份專案

本專案是一個生產等級的自動化備份方案，專門用於將 **Vaultwarden**（含 PostgreSQL 資料庫及附件檔案）透過 **Restic** 增量加密備份至雲端物件儲存（如 Cloudflare R2 或 Tencent COS）。

---

## 📂 專案目錄結構

建議的伺服器生產環境目錄配置如下：

```text
/home/ubuntu/vaultwarden/
├── compose.yaml          # Docker 容器編排檔案 (Vaultwarden & PostgreSQL)
├── .env                  # 敏感憑證與密碼環境設定檔 (不入版控)
├── backup.sh             # [自動化] 排程備份腳本
├── restore.sh            # [自動化] 災難還原腳本
├── RESTORE_GUIDE.md      # 災難還原標準作業程序 (SOP)
└── README.md             # 本說明文件

```

---

## 🛠️ 環境變數配置 (`.env`)

在執行任何腳本前，請務必在專案根目錄建立 `.env` 檔案，並填入以下完整變數：

```env
# --- Restic 雲端儲存體驗證 (相容 S3 協定) ---
AWS_ACCESS_KEY_ID="你的雲端儲存體AccessKey"
AWS_SECRET_ACCESS_KEY="你的雲端儲存體SecretKey"
RESTIC_REPOSITORY="s3:https://<你的儲存桶URL>"
RESTIC_PASSWORD="解密Restic備份的唯一主密碼"

# --- PostgreSQL 資料庫設定 ---
POSTGRES_USER="postgres"
POSTGRES_PASSWORD="資料庫超級管理員密碼"
POSTGRES_DB="postgres"


### --- Vault Configuration ---
### Domain for the Vaultwarden instance
VW_DOMAIN=

### Admin Panel Password (Argon2id Hash)
### Generate with `docker run --rm -it vaultwarden/server /vaultwarden hash`
VW_ADMIN_TOKEN='$argon2id$v=19$m=65540...'

### Set to 'true' for initial account setup
### After registering an account, it is recommended to set this to 'false'
VW_SIGNUPS_ALLOWED=true
```

---

## 🚀 核心腳本說明

### 1. 備份腳本 (`backup.sh`)

本腳本設計用於 Cron 排程自動化，具備以下安全機制：

* **記憶體流式備份：** 使用 `pg_dump -F c` 將資料庫打包，並進行零位元組（0-byte）失敗安全檢查。
* **資料去重與加密：** Restic 會自動將 `./vw-data` 附件夾與資料庫 dump 進行切塊、去重並加密上傳。
* **自動清理（Retention）：** 保持 `7天日備份`、`4週週備份`、`6個月月備份`，並自動執行 `prune` 釋放雲端空間。
* **完整性校驗：** 每次備份結束自動隨機抽查 `10%` 的雲端資料塊進行健康檢查。

**手動執行測試：**

```bash
chmod +x backup.sh
./backup.sh

```

### 2. 還原腳本 (`restore.sh`)

當主機遭遇不可逆之損毀時使用，核心還原邏輯：

1. 自動連線雲端儲存體，根據主機標籤（`--host`）抓取最新一筆快照。
2. 完整還原檔案結構至系統根目錄（`/`）。
3. 自動建立、拉取並啟動 Docker 容器。
4. **防衝突清理：** 進入 `vault-db` 容器內部執行 `DROP SCHEMA public CASCADE`，清空初始化殘留資料。
5. 使用流式輸入（Standard Input）將 `vw-pgdb.dump` 還原至資料庫。

**手動執行還原：**

```bash
chmod +x restore.sh
./restore.sh

```

*詳細的極端災難復原步驟，請參閱本專案中的 [RESTORE_GUIDE.md](./RESTORE_GUIDE.md)。*

---

## ⏰ Cron 自動化排程設定

為了達成無人值守的每日自動備份，請將腳本掛載至系統 Linux Cron 中。

1. 輸入指令開啟編輯器（請使用執行 Docker 的系統用戶，例如 `ubuntu`）：
```bash
crontab -e

```


2. 在檔案的絕對底部，貼上以下排程定義（**設定為每天凌晨 2:00 自動執行**，並將所有日誌與錯誤輸出至 `backup.log`）：
```text
0 2 * * * /bin/bash /home/ubuntu/vaultwarden/backup.sh >> /home/ubuntu/vaultwarden/backup.log 2>&1

```


3. **日誌審查：**
若需確認自動備份是否正常運作，可隨時查看日誌檔案：
```bash
cat /home/ubuntu/vaultwarden/backup.log

```



---

## ⚠️ 重要維護注意事項

1. **「救命包」離線備份：**
因為 `compose.yaml`、`.env` 和 `restore.sh` 是啟動還原的先決條件。**強烈建議**將這三個檔案單獨加密壓縮，備份在你的手機、隨身碟或另一台安全的個人電腦中。
2. **HTTPS 反向代理限制：**
Vaultwarden 在還原後，**強制需要 HTTPS 環境**（由外部反向代理如 Nginx/Caddy/HAProxy 提供）才能解鎖瀏覽器的 Web Crypto API。若在 `http://` 狀態下嘗試登入，會引發瀏覽器拒絕加解密而登入失敗。
