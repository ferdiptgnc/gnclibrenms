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
| Komponen tambahan | syslog ✓, trap ✓, monitor PC ini ✓, SMTP ✗, sysName duplikat ✓, branding GNC ✓ | sysName duplikat perlu untuk banyak switch dengan hostname default (mis. Ruijie `ruijie`) |
| Lokasi (sysLocation) | `Kantor Klien` | |
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
