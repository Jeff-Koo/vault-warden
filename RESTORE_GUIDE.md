# Vaultwarden 災難還原標準作業程序 (SOP)

本文件用於在**全新伺服器**、**全新網路環境**或極端災難（舊伺服器損毀）情況下，如何從 Cloudflare R2 雲端儲存桶中完整還原 Vaultwarden 密碼庫系統。

---

## 🛠 💡 災難發生時的自我檢查清單

在開始還原前，請確保你手邊已準備好以下「救命包」資料：

1. [ ] **網域管理權限：** Cloudflare 帳戶密碼（需要修改 DNS 解析）。
2. [ ] **核心環境檔案 `.env`：**（**極度重要**，必須內含以下四個關鍵變數）：
    * [ ] `AWS_ACCESS_KEY_ID`（雲端 R2/COS 的存取金鑰 ID）
    * [ ] `AWS_SECRET_ACCESS_KEY`（雲端 R2/COS 的秘密存取金鑰）
    * [ ] `RESTIC_REPOSITORY`（備份儲存桶的 S3 網址）
    * [ ] `RESTIC_PASSWORD`（Restic 的加密解密密碼）
    * [ ] `POSTGRES_PASSWORD`（PostgreSQL 資料庫密碼）
        * [ ] `POSTGRES_USER`（PostgreSQL 資料庫用戶名，建議保留）
        * [ ] `POSTGRES_DB`（PostgreSQL 資料庫名，建議保留）
3. [ ] **Docker 部署檔：** `compose.yaml`（建議一同放入救命包備用）。
4. [ ] **自動化還原檔：** `restore.sh` 腳本。
5. [ ] **反向代理設定：** 原本的 Nginx / Caddy / Traefik / HAProxy 的 HTTPS 憑證設定。

---

## 🚀 還原步驟說明

### 步驟 1：建置新伺服器環境

在新伺服器（Ubuntu/Debian）上，安裝必備的 Docker、Docker Compose 以及 Restic 還原工具。

1. 安裝 Docker
```bash
# 1.1. 把 Docker 的 GPG 金鑰下載到 /etc/apt/keyrings
sudo apt-get update
sudo apt-get install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# 1.2. 在 /etc/apt/sources.list.d/ 建立一個 docker.list 軟體源清單
echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# 1.3. 安裝 Docker 
sudo apt-get update
sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y

# 1.4. 把目前的 Linux 使用者加入 docker 群組，以後執行 docker ps 就不需要在前面加 sudo。
sudo usermod -aG docker ${USER}
su - ${USER}
```

2. 安裝 Restic 備份工具
```
sudo apt install restic -y
```

### 步驟 2：切換新網路 DNS 解析

由於更換了新伺服器與網路，你的外網 IP（Public IP）一定改變了。

1. 查詢新伺服器的外網公網 IP。
2. 登入 **Cloudflare 後台**。
3. 找到你的網域 DNS 設定，將 Vaultwarden 對應的 `A 紀錄`（例如：`vault.yourdomain.com`）指向**新的公網 IP**。

---

### 步驟 3：配置還原工作目錄

在新伺服器上建立與原本一模一樣的專案路徑，並將你的離線「救命包」檔案放進去。

```bash
# 1. 建立專案目錄
mkdir -p /home/ubuntu/vaultwarden
cd /home/ubuntu/vaultwarden

# 2. 將包含 AWS_ACCESS_KEY_ID 與加密密碼的 .env 檔案、restore.sh 放進此目錄
# 3. 賦予還原腳本執行權限
chmod +x restore.sh

```

> ⚠️ **安全檢查：** `restore.sh` 執行時會透過 `source .env` 自動將 `AWS_ACCESS_KEY_ID` 與 `AWS_SECRET_ACCESS_KEY` 導出為環境變數。請務必確保 `.env` 的權限為安全等級（例如 `chmod 600 .env`），防止其他無權限的系統使用者讀取你的雲端金鑰。

---

### 步驟 4：執行一鍵還原腳本

在 `/home/ubuntu/vaultwarden` 目錄下直接執行還原腳本：

```bash
bash ./restore.sh

```

**此腳本將自動執行以下動作：**

1. 連線至 R2/COS 儲存桶，拉取最新的資料快照。
2. 將 `./vw-data` 和資料庫備份檔 `vw-pgdb.dump` 直接解包到本機。
3. 自動下載並啟動 `compose.yaml` 定義的 Docker 容器。
4. 清空初始化資料庫，並將 `vw-pgdb.dump` 的完整內容（使用者、密碼、組織）匯入 PostgreSQL 容器內。
5. 清除暫存檔並重啟 Vaultwarden 載入最新資料。

---

### 步驟 5：重建 HTTPS 反向代理 (關鍵步驟)

Vaultwarden 必須在 **HTTPS 增強安全環境**下才能運作，否則瀏覽器會禁用加密元件導致無法登入。

1. 啟動你原本使用的反向代理服務（如 Nginx、Caddy 或 HAProxy）。
2. 為你的網域（`vault.yourdomain.com`）重新向 Let's Encrypt 申請 SSL 憑證。
3. 確保外部的 `443` 加密流量能正確導向本機的 Vaultwarden 容器埠口。

---

## 🎉 還原驗證

完成上述步驟後，請使用電腦瀏覽器或手機 App 存取你的網域。

* 頁面應能順利載入 HTTPS 安全連線。
* 輸入你原本的**主密碼 (Master Password)**，此時應能成功登入並看見所有密碼資料。
* 檢查後台管理面板（Admin Panel），確認使用者清單皆已正常還原。
