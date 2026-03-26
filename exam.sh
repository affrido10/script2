#!/bin/bash
# ==================================================================
# ДЕМОЭКЗАМЕН 2026 — МОДУЛЬ 1 — ВСЕ 11 ПУНКТОВ ТЗ
# ALT Linux (JeOS / Сервер / Рабочая станция)
#
# Порядок запуска:
#   sudo bash exam.sh isp
#   sudo bash exam.sh hq-rtr
#   sudo bash exam.sh br-rtr
#   sudo bash exam.sh hq-srv
#   sudo bash exam.sh br-srv
#   sudo bash exam.sh hq-cli
#
# ИНТЕРФЕЙСЫ — проверь на своей машине: ip -br link
# Если имена отличаются — замени sed-командой:
#   sed -i 's/ens19/eth0/g; s/ens20/eth1/g; s/ens21/eth2/g' exam.sh
#
# Текущее назначение:
#   ISP:    ens19=WAN(интернет)  ens20=к HQ-RTR  ens21=к BR-RTR
#   HQ-RTR: ens19=LAN(trunk)    ens20=WAN(к ISP)
#   BR-RTR: ens20=WAN(к ISP)    ens21=LAN(к BR-SRV)
#   HQ-SRV: ens19=LAN
#   BR-SRV: ens19=LAN
#   HQ-CLI: ens19=LAN
# ==================================================================
set +e

ROLE="$1"
DOMAIN="au-team.irpo"
HQ_SRV_IP="192.168.100.2"   # DNS-сервер для всей сети

if [ -z "$ROLE" ]; then
    echo "Использование: sudo bash exam.sh <isp|hq-rtr|br-rtr|hq-srv|br-srv|hq-cli>"
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    echo "Запускай от root: sudo bash exam.sh $ROLE"
    exit 1
fi

log() { echo -e "\n\e[1;32m>>>>> $1\e[0m"; }
err() { echo -e "\e[1;31m[ERR] $1\e[0m"; }

# --- Проверка nmcli ---
if ! command -v nmcli &>/dev/null; then
    err "nmcli не найден! Установи: apt-get install -y NetworkManager && systemctl enable --now NetworkManager"
    exit 1
fi

# --- Найти соединение NM по имени интерфейса ---
get_con() {
    local res
    res=$(nmcli -t -f NAME,DEVICE con show | grep ":${1}$" | cut -d: -f1 | head -n1)
    if [ -z "$res" ]; then
        # Соединения нет — создать новое
        nmcli con add type ethernet ifname "$1" con-name "$1" \
            ipv4.method manual ipv6.method disabled 2>/dev/null || true
        res="$1"
    fi
    echo "$res"
}

# --- Путь к sshd_config ---
SSH_CONF="/etc/openssh/sshd_config"
[ ! -f "$SSH_CONF" ] && SSH_CONF="/etc/ssh/sshd_config"

# ==================================================================
# 0. БАЗА — hostname, timezone, пользователи (на каждой машине)
# ==================================================================
log "[$ROLE] Базовая настройка: hostname, timezone, пользователь"

# Пункт 1: hostname FQDN
hostnamectl set-hostname "${ROLE}.${DOMAIN}"
echo "[OK] Hostname: ${ROLE}.${DOMAIN}"

# Пункт 11: часовой пояс
timedatectl set-timezone Europe/Moscow
echo "[OK] Timezone: Europe/Moscow"

apt-get update -y 2>/dev/null | tail -1

# Пункт 3: пользователи
case "$ROLE" in
    hq-srv|br-srv)
        # sshuser: UID 2026, sudo без пароля
        id sshuser &>/dev/null || useradd -u 2026 -m -s /bin/bash sshuser
        echo "sshuser:P@ssw0rd" | chpasswd
        echo "sshuser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/sshuser
        chmod 440 /etc/sudoers.d/sshuser
        echo "[OK] sshuser (UID=2026) создан"
        ;;
    hq-rtr|br-rtr)
        # net_admin: sudo без пароля
        id net_admin &>/dev/null || useradd -m -s /bin/bash net_admin
        echo "net_admin:P@ssw0rd" | chpasswd
        echo "net_admin ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/net_admin
        chmod 440 /etc/sudoers.d/net_admin
        echo "[OK] net_admin создан"
        ;;
esac

# ==================================================================
# ФУНКЦИИ
# ==================================================================

# Пункт 8: NAT через nftables (работает на всех версиях Alt Linux)
setup_nat() {
    local WAN="$1"
    log "Настройка NAT на $WAN"

    # IP forwarding — пишем сразу в два места для надёжности
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-forward.conf
    [ -f /etc/net/sysctl.conf ] && {
        grep -q "ip_forward" /etc/net/sysctl.conf || \
            echo "net.ipv4.ip_forward=1" >> /etc/net/sysctl.conf
    }
    sysctl -w net.ipv4.ip_forward=1

    # nftables — работает на Alt p9/p10
    apt-get install -y nftables 2>/dev/null | tail -1
    mkdir -p /etc/nftables

    cat > /etc/nftables/nftables.nft << EOF
#!/usr/sbin/nft -f
flush ruleset

table ip filter {
    chain forward {
        type filter hook forward priority 0; policy accept;
    }
}

table ip nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "$WAN" masquerade
    }
}
EOF

    systemctl enable nftables
    systemctl restart nftables
    echo "[OK] NAT masquerade на $WAN"
}

# NAT + проброс портов (для роутеров офиса, модуль 2 п.8)
setup_nat_dnat() {
    local WAN="$1"
    local SRV="$2"   # IP сервера за роутером
    log "Настройка NAT + DNAT на $WAN -> $SRV"

    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-forward.conf
    [ -f /etc/net/sysctl.conf ] && {
        grep -q "ip_forward" /etc/net/sysctl.conf || \
            echo "net.ipv4.ip_forward=1" >> /etc/net/sysctl.conf
    }
    sysctl -w net.ipv4.ip_forward=1

    apt-get install -y nftables 2>/dev/null | tail -1
    mkdir -p /etc/nftables

    cat > /etc/nftables/nftables.nft << EOF
#!/usr/sbin/nft -f
flush ruleset

table ip filter {
    chain forward {
        type filter hook forward priority 0; policy accept;
    }
}

table ip nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        iifname "$WAN" tcp dport 8080 dnat to ${SRV}:8080
        iifname "$WAN" tcp dport 2026 dnat to ${SRV}:2026
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "$WAN" masquerade
    }
}
EOF

    systemctl enable nftables
    systemctl restart nftables
    echo "[OK] NAT + DNAT (8080, 2026 -> $SRV) на $WAN"
}

# Пункт 5: SSH на серверах
setup_ssh() {
    log "Настройка SSH (порт 2026)"
    apt-get install -y openssh-server 2>/dev/null | tail -1

    # Баннер (точно по ТЗ — без точки)
    echo "Authorized access only" > /etc/banner

    # Идемпотентно правим sshd_config
    sed -i -E 's/^#?Port [0-9]+/Port 2026/' "$SSH_CONF"

    # Удаляем старые строки и добавляем правильные
    for KEY in AllowUsers MaxAuthTries Banner PasswordAuthentication; do
        sed -i "/^#*${KEY} /d" "$SSH_CONF"
    done
    cat >> "$SSH_CONF" << 'SSHEOF'
AllowUsers sshuser
MaxAuthTries 2
Banner /etc/banner
PasswordAuthentication yes
SSHEOF

    systemctl enable sshd 2>/dev/null || systemctl enable ssh 2>/dev/null
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
    echo "[OK] SSH: порт 2026, AllowUsers sshuser, MaxAuthTries 2"
}

# ==================================================================
# 1. ISP (пункт 2)
# ==================================================================
if [ "$ROLE" = "isp" ]; then
    log "Настройка ISP"

    C19=$(get_con "ens19")
    C20=$(get_con "ens20")
    C21=$(get_con "ens21")

    # ens19 — WAN к интернету: DHCP от провайдера
    nmcli con mod "$C19" \
        ipv4.method auto \
        ipv4.addresses "" \
        ipv4.gateway "" \
        ipv6.method disabled
    nmcli con up "$C19"
    echo "[OK] ens19: DHCP (WAN к интернету)"

    # ens20 — к HQ-RTR: сеть 172.16.1.0/28, ISP берёт .14
    nmcli con mod "$C20" \
        ipv4.addresses "172.16.1.14/28" \
        ipv4.method manual \
        ipv4.gateway "" \
        ipv6.method disabled
    nmcli con up "$C20"
    echo "[OK] ens20: 172.16.1.14/28 (к HQ-RTR)"

    # ens21 — к BR-RTR: сеть 172.16.2.0/28, ISP берёт .14
    nmcli con mod "$C21" \
        ipv4.addresses "172.16.2.14/28" \
        ipv4.method manual \
        ipv4.gateway "" \
        ipv6.method disabled
    nmcli con up "$C21"
    echo "[OK] ens21: 172.16.2.14/28 (к BR-RTR)"

    setup_nat "ens19"

    log "ISP готов"
fi

# ==================================================================
# 2. HQ-RTR (пункты 1, 3, 4, 6, 7, 8, 9)
# ==================================================================
if [ "$ROLE" = "hq-rtr" ]; then
    log "Настройка HQ-RTR"
    apt-get install -y frr dhcp-server 2>/dev/null | tail -1

    C20=$(get_con "ens20")
    C19=$(get_con "ens19")

    # ens20 — WAN к ISP
    nmcli con mod "$C20" \
        ipv4.addresses "172.16.1.2/28" \
        ipv4.gateway "172.16.1.14" \
        ipv4.dns "127.0.0.1" \
        ipv4.dns-search "${DOMAIN}" \
        ipv4.method manual \
        ipv6.method disabled
    nmcli con up "$C20"
    echo "[OK] ens20: 172.16.1.2/28 GW=172.16.1.14 (WAN к ISP)"

    # ens19 — trunk-порт, IP не нужен
    nmcli con mod "$C19" \
        ipv4.method disabled \
        ipv6.method disabled
    nmcli con up "$C19" 2>/dev/null || true

    # --- Пункт 4: VLAN через NM (один физический порт = ens19) ---
    # Удалить старые если есть
    for V in vlan100 vlan200 vlan999; do
        nmcli con delete "$V" 2>/dev/null || true
    done

    # VLAN 100: ≤32 адресов → /27  (0-31, HQ-SRV=.2, GW=.1)
    nmcli con add type vlan con-name vlan100 ifname ens19.100 dev ens19 id 100 \
        ipv4.addresses "192.168.100.1/27" \
        ipv4.method manual \
        ipv4.dns "127.0.0.1" \
        ipv4.dns-search "${DOMAIN}" \
        ipv6.method disabled

    # VLAN 200: ≥16 адресов → /28  (0-15, HQ-CLI=DHCP, GW=.1)
    nmcli con add type vlan con-name vlan200 ifname ens19.200 dev ens19 id 200 \
        ipv4.addresses "192.168.200.1/28" \
        ipv4.method manual \
        ipv4.dns "127.0.0.1" \
        ipv4.dns-search "${DOMAIN}" \
        ipv6.method disabled

    # VLAN 999: ≤8 адресов → /29  (управление)
    nmcli con add type vlan con-name vlan999 ifname ens19.999 dev ens19 id 999 \
        ipv4.addresses "192.168.99.1/29" \
        ipv4.method manual \
        ipv6.method disabled

    nmcli con up vlan100
    nmcli con up vlan200
    nmcli con up vlan999
    echo "[OK] VLAN100=192.168.100.1/27  VLAN200=192.168.200.1/28  VLAN999=192.168.99.1/29"

    # --- Пункт 8: NAT + DNAT ---
    setup_nat_dnat "ens20" "192.168.100.2"

    # --- Пункт 6: GRE-туннель ---
    # Запуск сейчас + персистентность через rc.local
    ip tunnel del gre1 2>/dev/null
    ip tunnel add gre1 mode gre remote 172.16.2.2 local 172.16.1.2 ttl 64
    ip addr replace 10.0.0.1/30 dev gre1
    ip link set gre1 up
    echo "[OK] GRE gre1: 172.16.1.2 -> 172.16.2.2, IP=10.0.0.1/30"

    # rc.local для восстановления после перезагрузки
    mkdir -p /etc/rc.d
    cat > /etc/rc.d/rc.local << 'RCEOF'
#!/bin/bash
ip tunnel del gre1 2>/dev/null
ip tunnel add gre1 mode gre remote 172.16.2.2 local 172.16.1.2 ttl 64
ip addr replace 10.0.0.1/30 dev gre1
ip link set gre1 up
exit 0
RCEOF
    chmod +x /etc/rc.d/rc.local
    systemctl enable rc-local 2>/dev/null || true

    # --- Пункт 9: DHCP для HQ-CLI (vlan200) ---
    echo 'DHCPDARGS="ens19.200"' > /etc/sysconfig/dhcpd
    cat > /etc/dhcp/dhcpd.conf << DHCPEOF
default-lease-time 600;
max-lease-time 7200;
authoritative;

# VLAN200: 192.168.200.0/28, исключаем .1 (шлюз)
subnet 192.168.200.0 netmask 255.255.255.240 {
    range 192.168.200.2 192.168.200.14;
    option routers 192.168.200.1;
    option domain-name-servers ${HQ_SRV_IP};
    option domain-name "${DOMAIN}";
}

# Остальные подсети — объявляем чтобы dhcpd не ругался
subnet 192.168.100.0 netmask 255.255.255.224 {}
subnet 192.168.99.0 netmask 255.255.255.248 {}
subnet 172.16.1.0 netmask 255.255.255.240 {}
DHCPEOF
    systemctl enable --now dhcpd
    systemctl restart dhcpd
    echo "[OK] DHCP: ens19.200, диапазон .2-.14, DNS=${HQ_SRV_IP}"

    # --- Пункт 7: OSPF через FRR ---
    # Включить ospfd в daemons
    sed -i 's/^ospfd=.*/ospfd=yes/' /etc/frr/daemons
    grep -q '^ospfd=yes' /etc/frr/daemons || echo "ospfd=yes" >> /etc/frr/daemons

    cat > /etc/frr/frr.conf << 'FRREOF'
frr defaults traditional
hostname hq-rtr
!
interface gre1
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 P@ssw0rd
!
router ospf
 ospf router-id 172.16.1.2
 passive-interface default
 no passive-interface gre1
 network 10.0.0.0/30 area 0
 network 192.168.100.0/27 area 0
 network 192.168.200.0/28 area 0
 network 192.168.99.0/29 area 0
!
FRREOF

    chown frr:frr /etc/frr/frr.conf
    chmod 640 /etc/frr/frr.conf
    systemctl enable --now frr
    systemctl restart frr
    echo "[OK] OSPF (FRR): gre1, MD5=P@ssw0rd"

    log "HQ-RTR готов"
fi

# ==================================================================
# 3. BR-RTR (пункты 1, 3, 6, 7, 8)
# ==================================================================
if [ "$ROLE" = "br-rtr" ]; then
    log "Настройка BR-RTR"
    apt-get install -y frr 2>/dev/null | tail -1

    C20=$(get_con "ens20")
    C21=$(get_con "ens21")

    # ens20 — WAN к ISP
    nmcli con mod "$C20" \
        ipv4.addresses "172.16.2.2/28" \
        ipv4.gateway "172.16.2.14" \
        ipv4.dns "${HQ_SRV_IP}" \
        ipv4.dns-search "${DOMAIN}" \
        ipv4.method manual \
        ipv6.method disabled
    nmcli con up "$C20"
    echo "[OK] ens20: 172.16.2.2/28 GW=172.16.2.14 (WAN к ISP)"

    # ens21 — LAN к BR-SRV: ≤16 адресов → /28
    nmcli con mod "$C21" \
        ipv4.addresses "192.168.1.1/28" \
        ipv4.method manual \
        ipv4.dns "${HQ_SRV_IP}" \
        ipv4.dns-search "${DOMAIN}" \
        ipv6.method disabled
    nmcli con up "$C21"
    echo "[OK] ens21: 192.168.1.1/28 (LAN к BR-SRV)"

    # --- Пункт 8: NAT + DNAT ---
    setup_nat_dnat "ens20" "192.168.1.2"

    # --- Пункт 6: GRE-туннель ---
    ip tunnel del gre1 2>/dev/null
    ip tunnel add gre1 mode gre remote 172.16.1.2 local 172.16.2.2 ttl 64
    ip addr replace 10.0.0.2/30 dev gre1
    ip link set gre1 up
    echo "[OK] GRE gre1: 172.16.2.2 -> 172.16.1.2, IP=10.0.0.2/30"

    mkdir -p /etc/rc.d
    cat > /etc/rc.d/rc.local << 'RCEOF'
#!/bin/bash
ip tunnel del gre1 2>/dev/null
ip tunnel add gre1 mode gre remote 172.16.1.2 local 172.16.2.2 ttl 64
ip addr replace 10.0.0.2/30 dev gre1
ip link set gre1 up
exit 0
RCEOF
    chmod +x /etc/rc.d/rc.local
    systemctl enable rc-local 2>/dev/null || true

    # --- Пункт 7: OSPF ---
    sed -i 's/^ospfd=.*/ospfd=yes/' /etc/frr/daemons
    grep -q '^ospfd=yes' /etc/frr/daemons || echo "ospfd=yes" >> /etc/frr/daemons

    cat > /etc/frr/frr.conf << 'FRREOF'
frr defaults traditional
hostname br-rtr
!
interface gre1
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 P@ssw0rd
!
router ospf
 ospf router-id 172.16.2.2
 passive-interface default
 no passive-interface gre1
 network 10.0.0.0/30 area 0
 network 192.168.1.0/28 area 0
!
FRREOF

    chown frr:frr /etc/frr/frr.conf
    chmod 640 /etc/frr/frr.conf
    systemctl enable --now frr
    systemctl restart frr
    echo "[OK] OSPF (FRR): gre1, MD5=P@ssw0rd"

    log "BR-RTR готов"
fi

# ==================================================================
# 4. HQ-SRV (пункты 1, 3, 5, 10)
# ==================================================================
if [ "$ROLE" = "hq-srv" ]; then
    log "Настройка HQ-SRV"
    apt-get install -y bind openssh-server 2>/dev/null | tail -1

    C19=$(get_con "ens19")
    nmcli con mod "$C19" \
        ipv4.addresses "${HQ_SRV_IP}/27" \
        ipv4.gateway "192.168.100.1" \
        ipv4.dns "127.0.0.1" \
        ipv4.dns-search "${DOMAIN}" \
        ipv4.method manual \
        ipv6.method disabled
    nmcli con up "$C19"
    echo "[OK] ens19: ${HQ_SRV_IP}/27 GW=192.168.100.1"

    # --- Пункт 5: SSH ---
    setup_ssh

    # --- Пункт 10: DNS (bind) ---
    log "Настройка DNS (bind)"

    # Определяем пути — Alt Linux использует /var/named
    NAMED_CONF="/etc/named.conf"
    NAMED_DIR="/var/named"
    # На некоторых Alt может быть /etc/bind
    [ -d "/etc/bind" ] && NAMED_CONF="/etc/bind/named.conf"
    [ -d "/var/lib/bind" ] && NAMED_DIR="/var/lib/bind"
    mkdir -p "${NAMED_DIR}/zone"

    # Полная перезапись named.conf
    cat > "${NAMED_CONF}" << NAMEDEOF
options {
    directory "${NAMED_DIR}";
    forwarders { 77.88.8.7; 77.88.8.3; };
    forward only;
    allow-query { any; };
    allow-recursion { any; };
    recursion yes;
    listen-on port 53 { any; };
    listen-on-v6 { none; };
    dnssec-validation no;
};

zone "${DOMAIN}" {
    type master;
    file "zone/forward.zone";
};

zone "100.168.192.in-addr.arpa" {
    type master;
    file "zone/rev.100";
};

zone "200.168.192.in-addr.arpa" {
    type master;
    file "zone/rev.200";
};
NAMEDEOF

    # Прямая зона — Таблица 3 из ТЗ
    cat > "${NAMED_DIR}/zone/forward.zone" << FWDEOF
\$TTL 86400
@   IN  SOA  hq-srv.${DOMAIN}. admin.${DOMAIN}. (
            2026010101 3600 900 1209600 86400 )
    IN  NS   hq-srv.${DOMAIN}.

; Таблица 3 ТЗ
hq-rtr  IN  A  192.168.100.1
hq-srv  IN  A  ${HQ_SRV_IP}
hq-cli  IN  A  192.168.200.2
br-rtr  IN  A  192.168.1.1
br-srv  IN  A  192.168.1.2
docker  IN  A  172.16.1.14
web     IN  A  172.16.2.14
FWDEOF

    # PTR — 192.168.100.x (hq-rtr, hq-srv)
    cat > "${NAMED_DIR}/zone/rev.100" << REVEOF
\$TTL 86400
@   IN  SOA  hq-srv.${DOMAIN}. admin.${DOMAIN}. (
            2026010101 3600 900 1209600 86400 )
    IN  NS   hq-srv.${DOMAIN}.

1   IN  PTR  hq-rtr.${DOMAIN}.
2   IN  PTR  hq-srv.${DOMAIN}.
REVEOF

    # PTR — 192.168.200.x (hq-cli)
    cat > "${NAMED_DIR}/zone/rev.200" << REVEOF
\$TTL 86400
@   IN  SOA  hq-srv.${DOMAIN}. admin.${DOMAIN}. (
            2026010101 3600 900 1209600 86400 )
    IN  NS   hq-srv.${DOMAIN}.

2   IN  PTR  hq-cli.${DOMAIN}.
REVEOF

    # Права
    chown -R named:named "${NAMED_DIR}" 2>/dev/null || \
    chown -R bind:bind "${NAMED_DIR}" 2>/dev/null || true
    chmod -R 755 "${NAMED_DIR}"

    # Проверка и запуск
    named-checkconf "${NAMED_CONF}" \
        && echo "[OK] named.conf синтаксис верный" \
        || err "Ошибка в named.conf!"

    named-checkzone "${DOMAIN}" "${NAMED_DIR}/zone/forward.zone" \
        && echo "[OK] Зона forward.zone верна" \
        || err "Ошибка в forward.zone!"

    systemctl enable named 2>/dev/null || systemctl enable bind 2>/dev/null || true
    systemctl restart named 2>/dev/null || systemctl restart bind 2>/dev/null || true
    echo "[OK] DNS (bind) запущен"

    log "HQ-SRV готов"
fi

# ==================================================================
# 5. BR-SRV (пункты 1, 3, 5)
# ==================================================================
if [ "$ROLE" = "br-srv" ]; then
    log "Настройка BR-SRV"
    apt-get install -y openssh-server 2>/dev/null | tail -1

    C19=$(get_con "ens19")
    nmcli con mod "$C19" \
        ipv4.addresses "192.168.1.2/28" \
        ipv4.gateway "192.168.1.1" \
        ipv4.dns "${HQ_SRV_IP}" \
        ipv4.dns-search "${DOMAIN}" \
        ipv4.method manual \
        ipv6.method disabled
    nmcli con up "$C19"
    echo "[OK] ens19: 192.168.1.2/28 GW=192.168.1.1"

    # Пункт 5: SSH
    setup_ssh

    log "BR-SRV готов"
fi

# ==================================================================
# 6. HQ-CLI (пункт 9 — DHCP-клиент!)
# ==================================================================
if [ "$ROLE" = "hq-cli" ]; then
    log "Настройка HQ-CLI (DHCP)"

    C19=$(get_con "ens19")
    nmcli con mod "$C19" \
        ipv4.method auto \
        ipv4.addresses "" \
        ipv4.gateway "" \
        ipv4.dns "" \
        ipv4.dns-search "${DOMAIN}" \
        ipv6.method disabled
    nmcli con up "$C19"
    echo "[OK] ens19: DHCP (ждём адрес от HQ-RTR)"
    echo "     Ожидаемый диапазон: 192.168.200.2 - 192.168.200.14"
    sleep 3
    ip -4 addr show ens19 2>/dev/null | grep inet || echo "(адрес ещё не получен — подожди)"

    log "HQ-CLI готов"
fi

# ==================================================================
# ИТОГОВАЯ ПРОВЕРКА
# ==================================================================
echo ""
echo "======================================================="
echo "  ПРОВЕРКА: $ROLE"
echo "======================================================="
echo ""

echo "[hostname]  $(hostname)"
echo "[timezone]  $(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/localtime 2>/dev/null)"
echo ""
echo "[ip -br a]"
ip -br a
echo ""
echo "[маршруты]"
ip r
echo ""

case "$ROLE" in
    isp)
        echo -n "Интернет (8.8.8.8):    "; ping -c1 -W2 8.8.8.8   &>/dev/null && echo "✅" || echo "❌"
        echo -n "К HQ-RTR (172.16.1.2): "; ping -c1 -W2 172.16.1.2 &>/dev/null && echo "✅" || echo "❌"
        echo -n "К BR-RTR (172.16.2.2): "; ping -c1 -W2 172.16.2.2 &>/dev/null && echo "✅" || echo "❌"
        echo "nftables:"; nft list ruleset 2>/dev/null | grep -E "masquerade|table" || echo "  не активен"
        ;;
    hq-rtr)
        echo -n "К ISP (172.16.1.14):    "; ping -c1 -W2 172.16.1.14 &>/dev/null && echo "✅" || echo "❌"
        echo -n "Интернет (8.8.8.8):     "; ping -c1 -W2 8.8.8.8    &>/dev/null && echo "✅" || echo "❌"
        echo -n "GRE к BR (10.0.0.2):    "; ping -c1 -W2 10.0.0.2   &>/dev/null && echo "✅" || echo "❌"
        echo -n "DHCP статус:            "; systemctl is-active dhcpd 2>/dev/null || echo "неизвестно"
        echo -n "FRR статус:             "; systemctl is-active frr 2>/dev/null || echo "неизвестно"
        echo "OSPF маршруты:"; vtysh -c "show ip route ospf" 2>/dev/null || echo "  FRR не готов (запусти после BR-RTR)"
        ;;
    br-rtr)
        echo -n "К ISP (172.16.2.14):    "; ping -c1 -W2 172.16.2.14 &>/dev/null && echo "✅" || echo "❌"
        echo -n "Интернет (8.8.8.8):     "; ping -c1 -W2 8.8.8.8    &>/dev/null && echo "✅" || echo "❌"
        echo -n "GRE к HQ (10.0.0.1):    "; ping -c1 -W2 10.0.0.1   &>/dev/null && echo "✅" || echo "❌"
        echo -n "FRR статус:             "; systemctl is-active frr 2>/dev/null || echo "неизвестно"
        echo "OSPF маршруты:"; vtysh -c "show ip route ospf" 2>/dev/null || echo "  FRR не готов"
        ;;
    hq-srv)
        echo -n "К шлюзу (192.168.100.1):   "; ping -c1 -W2 192.168.100.1 &>/dev/null && echo "✅" || echo "❌"
        echo -n "Интернет (8.8.8.8):        "; ping -c1 -W2 8.8.8.8       &>/dev/null && echo "✅" || echo "❌"
        echo -n "named.conf:                "; named-checkconf &>/dev/null && echo "✅" || echo "❌"
        echo -n "DNS сервис:                "; (systemctl is-active named 2>/dev/null || systemctl is-active bind 2>/dev/null) && echo "✅" || echo "❌"
        echo -n "SSH порт 2026:             "; grep "^Port" "$SSH_CONF" 2>/dev/null || echo "не настроен"
        echo -n "Баннер:                    "; cat /etc/banner 2>/dev/null || echo "нет"
        ;;
    br-srv)
        echo -n "К шлюзу (192.168.1.1):  "; ping -c1 -W2 192.168.1.1 &>/dev/null && echo "✅" || echo "❌"
        echo -n "Интернет (8.8.8.8):     "; ping -c1 -W2 8.8.8.8     &>/dev/null && echo "✅" || echo "❌"
        echo -n "SSH порт 2026:          "; grep "^Port" "$SSH_CONF" 2>/dev/null || echo "не настроен"
        echo -n "Баннер:                 "; cat /etc/banner 2>/dev/null || echo "нет"
        ;;
    hq-cli)
        echo "Полученный IP:"; ip -4 addr show ens19 2>/dev/null | grep inet || echo "  нет адреса!"
        echo -n "Интернет (8.8.8.8):         "; ping -c1 -W3 8.8.8.8 &>/dev/null && echo "✅" || echo "❌"
        echo -n "DNS hq-srv.au-team.irpo:    "; dig +short hq-srv.${DOMAIN} @${HQ_SRV_IP} 2>/dev/null | head -1 || echo "не резолвит"
        echo -n "PTR 192.168.100.2:          "; dig +short -x 192.168.100.2 @${HQ_SRV_IP} 2>/dev/null | head -1 || echo "нет"
        ;;
esac

echo ""
echo "======================================================="
echo "  $ROLE — ЗАВЕРШЁН"
echo "======================================================="
