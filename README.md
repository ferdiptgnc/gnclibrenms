# LibreNMS Docker Installer — Debian 13

Repo: https://github.com/ferdiptgnc/gnclibrenms

Installer satu file untuk memasang **LibreNMS berbasis Docker** di PC/VM yang baru diinstall **Debian 13 (trixie)**. Bisa interaktif (dialog) atau tanpa dialog untuk deploy massal.

## Yang diinstall

- Docker Engine + Docker Compose dari repo resmi Docker. Kalau repo itu gagal, installer memakai paket Docker dari repo Debian.
- LibreNMS, MariaDB 10.11, Redis 7.2, dan dispatcher (poller).
- Opsional: syslog receiver (514), SNMP trap receiver (162), email alert via msmtpd, serta snmpd agar PC ini ikut dimonitor.
- Opsional: IP statis. Mendukung ifupdown (default Debian), NetworkManager, dan systemd-networkd.
- Lain-lain: hostname, zona waktu dan NTP, rotasi log Docker, user admin LibreNMS, dan community SNMP default.

## Cara pakai

Login sebagai **root** (`su -`). Debian minimal biasanya sudah punya `wget` tapi belum punya `curl`.

```bash
# Interaktif (dialog)
wget -qO- https://raw.githubusercontent.com/ferdiptgnc/gnclibrenms/main/install-librenms.sh | bash

# atau download dulu, lalu jalankan
wget https://raw.githubusercontent.com/ferdiptgnc/gnclibrenms/main/install-librenms.sh
bash install-librenms.sh
```

Setelah selesai, buka `http://IP-PC` (atau `http://IP-PC:PORT` kalau port bukan 80). Ringkasan instalasi tersimpan di `/opt/librenms/INSTALL-INFO.txt` dan log-nya di `/var/log/librenms-install.log`.

## Isian dialog & default

| Isian | Default | Keterangan |
|---|---|---|
| Hostname | `librenms` | |
| Konfigurasi IP | biarkan | atau IP statis: interface, IP/CIDR, gateway, DNS (`8.8.8.8 1.1.1.1`) |
| Port Web | `80` | dicek bentrok dengan aplikasi lain |
| Domain publik | *(kosong)* | isi bila diakses via Cloudflare Tunnel / reverse proxy, mis. `https://nms.klien.com` |
| Trusted proxy | `127.0.0.1,172.16.0.0/12,10.0.0.0/8,192.168.0.0/16` | IP/CIDR reverse proxy yang dipercaya; persempit ke IP cloudflared bila diketahui |
| Zona waktu | `Asia/Jakarta` | pilihan WIB/WITA/WIT/UTC atau ketik manual |
| Username admin | `admin` | |
| Password admin | *(kosong = generate acak)* | minimal 8 karakter |
| Email admin | `admin@localhost` | dipakai juga sebagai sysContact |
| Password database | generate otomatis | |
| SNMP community | `public` | **disarankan diganti** |
| Komponen tambahan | syslog ✓, trap ✓, monitor PC ini ✓, SMTP ✗, sysName duplikat ✓, branding GNC ✓, Grafana + SLA ✓, backup konfigurasi ✓ | sysName duplikat perlu untuk banyak switch dengan hostname default (mis. Ruijie `ruijie`) |
| Lokasi (sysLocation) | `Kantor Klien` | |
| Target ping SLA | gateway lokal, `1.1.1.1`, `8.8.8.8` | ditambah gateway ISP bila tahu |
| Interval speedtest | `4h` | `1h` / `2h` / `4h` / `6h` / `off` |
| Port Grafana | `3000` | URL publik Grafana (Cloudflare) opsional |
| User SSH perangkat | `oxidized` | untuk backup konfigurasi; kosongkan untuk melewati |
| Folder instalasi | `/opt/librenms` | |
| PHP memory limit | `256M` | |

## Deploy massal (tanpa dialog)

Untuk banyak PC, siapkan satu file config per klien (lihat `client.conf.example`), lalu jalankan:

```bash
wget https://raw.githubusercontent.com/ferdiptgnc/gnclibrenms/main/install-librenms.sh
bash install-librenms.sh --unattended --config client-a.conf
```

Variabel juga bisa diberikan langsung lewat environment:

```bash
wget -qO- https://raw.githubusercontent.com/ferdiptgnc/gnclibrenms/main/install-librenms.sh \
  | LNMS_ADMIN_PASS='PasswordKuat123' LNMS_SNMP_COMMUNITY='komunitasRahasia' bash -s -- --unattended
```

Kalau `LNMS_ADMIN_PASS` dikosongkan, password akan di-generate lalu ditampilkan di akhir dan disimpan di `INSTALL-INFO.txt`.

## Pengelolaan setelah instalasi: `gnclibre`

Installer memasang perintah **`gnclibre`**. Login sebagai root, lalu ketik:

```bash
gnclibre
```

Menu yang tersedia:

| Menu | Isi |
|---|---|
| Status & informasi | status container, Web UI, jumlah user/device, isi `INSTALL-INFO.txt` |
| Akun admin / user | daftar user, ganti password, ganti username, tambah user (admin / read-only / user) |
| Akses web | ubah URL publik (Cloudflare), trusted proxy, port web |
| SNMP & device | daftar device, tambah device, ubah community default, izinkan sysName duplikat |
| Email alert | atur SMTP (Gmail, dll); service msmtpd ditambahkan otomatis bila belum ada |
| Zona waktu | WIB / WITA / WIT / lainnya |
| Layanan | restart, stop/start, lihat log, `validate.php`, update ke image terbaru (DB dibackup dulu) |
| Backup & restore | backup database, backup lengkap (DB + grafik RRD + config), restore database |
| Branding | terapkan logo/favicon/judul/pesan login GNC, ubah judul & pesan, pakai logo sendiri (PNG), kembalikan tampilan asli |
| Modul analisis | backup konfigurasi (Oxidized), Grafana + SLA ISP: aktifkan/ubah, backup & speedtest manual, cek data, reset password Grafana, nonaktifkan |

Perintah langsung tanpa menu (bisa dipakai di script):

```bash
gnclibre status           # ringkasan status
gnclibre passwd admin     # ganti password user admin
gnclibre backup           # backup database ke /opt/librenms/backups
gnclibre update           # backup DB, lalu update LibreNMS
gnclibre restart          # restart semua container
gnclibre logs [service]   # ikuti log (default: librenms)
gnclibre validate         # jalankan validate.php
gnclibre branding         # terapkan branding GNC
gnclibre branding reset   # kembalikan tampilan asli LibreNMS
gnclibre module analytics # aktifkan Grafana + SLA ISP
gnclibre module oxidized  # aktifkan backup konfigurasi (GNC_OXI_USER=.. GNC_OXI_PASS=..)
gnclibre backup-config    # backup konfigurasi semua device sekarang
gnclibre speedtest        # speedtest sekarang
gnclibre self-update      # perbarui gnclibre dari repo ini
```

Semua perubahan dicatat di `/var/log/gnclibre.log`.

**Memasang `gnclibre` di server yang sudah terinstall sebelumnya** (installer versi lama atau instalasi manual):

```bash
wget -qO /usr/local/bin/gnclibre https://raw.githubusercontent.com/ferdiptgnc/gnclibrenms/main/gnclibre
chmod +x /usr/local/bin/gnclibre
gnclibre
```

Folder instalasi dideteksi otomatis dari container Docker. Kalau tidak terdeteksi, isi `LNMS_INSTALL_DIR=/path/folder` di `/etc/gnclibre.conf`.

## Branding GNC

Secara default installer memasang identitas GNC di Web UI:

| Bagian | Isi |
|---|---|
| Logo navbar & halaman login | logo Galura Nexa Core (kartu putih, terbaca di tema terang/gelap) |
| Favicon tab browser | ikon jaringan GNC |
| Judul tab browser | `Devices \| GNC NMS` (bisa diganti) |
| Pesan halaman login | "Sistem monitoring jaringan Galura Nexa Core. Akses hanya untuk pengguna yang berwenang." |

File logo ada di `/opt/librenms/branding/` dan di-mount ke container lewat `compose.override.yml`, jadi logo tetap ada setelah update atau recreate container. File override ini otomatis dimuat saat `docker compose` dijalankan di folder instalasi.

Server lama cukup menjalankan `gnclibre self-update`, lalu `gnclibre branding`. Logo milik klien bisa dipasang lewat menu `gnclibre` → Branding → Pakai logo sendiri.

## Modul analisis (Tahap 1)

Dua modul tambahan, dipasang otomatis oleh installer atau lewat `gnclibre` → **10 Modul analisis**.

### Grafana + SLA ISP

Komponennya: InfluxDB 2.7 (penyimpanan 90 hari), Telegraf, dan Grafana. Setelah aktif, Grafana bisa dibuka di `http://IP-PC:3000` (user `admin`). Ada tiga dashboard di folder **GNC**:

| Dashboard | Isi |
|---|---|
| **GNC - Ringkasan Jaringan** | jumlah device up/down, alert aktif, port ber-error, daftar device (klik untuk membuka LibreNMS) |
| **GNC - Kualitas ISP (SLA)** | latency, packet loss, jitter per target ping setiap menit, serta speedtest download/upload berkala |
| **GNC - Trafik WAN** | trafik semua port berlabel `Transit:`, persentil-95, volume, dan error WAN, ditambah grafik port pilihan |

Data trafik WAN berasal dari LibreNMS, yang otomatis mengirim metrik ke InfluxDB. Port WAN ditandai dengan deskripsi interface `Transit: NamaISP {100Mbps}`.

Untuk akses lewat Cloudflare Tunnel, buat hostname terpisah (misalnya `grafana.klien.gnclab.online`) yang diarahkan ke `http://IP-PC:3000`, lalu isi URL publiknya di dialog atau di menu.

Setiap speedtest memakai bandwidth ratusan MB pada link cepat, jadi pilih intervalnya dengan wajar (default 4 jam).

### Backup konfigurasi (Oxidized)

Konfigurasi setiap device di LibreNMS dibackup otomatis setiap 24 jam lewat SSH. Riwayat dan diff-nya bisa dilihat di LibreNMS → device → tab **Config**. Secret (password, community) dibuang dari hasil backup.

Siapkan user SSH khusus di perangkat:

```
# MikroTik
/user add name=oxidized group=read password=PASSWORD
# Ruijie (butuh privilege 15 agar show running-config bisa dibaca)
username oxidized privilege 15 password PASSWORD
line vty 0 4
 login local
```

Kalau Ruijie memakai kredensial berbeda, isi lewat `gnclibre` → Modul analisis → Backup konfigurasi.

### Kebutuhan sumber daya

Dengan kedua modul aktif: RAM minimal **4 GB** (8 GB disarankan) dan disk kosong **20 GB**. Image tambahan berukuran ±1,5 GB.

## Akses lewat Cloudflare Tunnel

Kalau domain publik diisi, installer akan:
- Mengisi `APP_TRUSTED_PROXIES` di env container dan di `.env` LibreNMS. Sejak LibreNMS 26.5, header `X-Forwarded-*` tidak lagi dipercaya secara default. Tanpa setting ini, halaman HTTPS memuat URL `http://` dan browser memblokirnya dengan error *Mixed Content*, sehingga tabel device kosong.
- Mengisi `base_url`/`LIBRENMS_BASE_URL` dengan domain tersebut, supaya link di email alert benar.
- Mensimulasikan request dari Cloudflare untuk memastikan tidak ada URL `http://` yang tersisa.

Di dashboard Cloudflare Tunnel, arahkan *service* untuk hostname-nya ke `http://IP-PC:80`, bukan `https://`.

## Catatan

- Jika IP statis diubah lewat SSH, sesi SSH akan terputus di akhir instalasi. Pada ifupdown (default Debian), IP baru berlaku setelah reboot. Dalam mode unattended reboot terjadi otomatis, atur dengan `LNMS_AUTO_REBOOT=no`.
- Script menolak berjalan bila folder instalasi sudah berisi instalasi lama, supaya data tidak tertimpa.
- Validasi `Python3 module issue found: ''` pada `validate.php` di image Docker umumnya false positive dan bisa diabaikan.
