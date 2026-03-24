#!/bin/bash
# ==================================================================
# ДЕМОЭКЗАМЕН 2025 — МОДУЛЬ 1 — ВСЕ 11 ПУНКТОВ ТЗ
# ALT Linux (JeOS / Сервер / Рабочая станция)
#
# Порядок запуска: isp → hq-rtr → br-rtr → hq-srv → br-srv → hq-cli
#
# Если интерфейсы называются иначе (eth0, eth1...):
#   sed -i 's/ens19/eth0/g; s/ens20/eth1/g; s/ens21/eth2/g' exam.sh
# ==================================================================
set +e

ROLE="$1"
DOMAIN="au-team.irpo"
DNS_IP="192.168.100.2"

if [ -z "$ROLE" ]; then
    echo "Использование: $0 <isp|hq-rtr|br-rtr|hq-srv|br-srv|hq-cli>"
    exit 1
fi

log() { echo -e "\n\e[1;32m>>>>> $1\e[0m"; }

# --- Проверка nmcli ---
if ! command -v nmcli &>/dev/null; then
    echo "ОШИБКА: nmcli не найден!"
    echo "Выполните: apt-get install NetworkManager -y && systemctl enable --now NetworkManager"
    exit 1
fi

# --- Поиск соединения по имени устройства ---
get_con() {
    local res
    res=$(nmcli -t -f NAME,DEVICE con show | grep ":${1}$" | cut -d: -f1 | head -n1)
    if [ -z "$res" ]; then
        echo "ОШИБКА: интерфейс $1 не найден в nmcli!" >&2
        echo "Доступные:" >&2
        nmcli -t -f NAME,DEVICE con show >&2
        exit 1
    fi
    echo "$res"
}

# --- Определение пути SSH для ALT ---
SSH_CONF="/etc/openssh/sshd_config"
[ ! -f "$SSH_CONF" ] && SSH_CONF="/etc/ssh/sshd_config"

# ==================================================================
# 0. БАЗА — ВЫПОЛНЯЕТСЯ НА КАЖДОЙ МАШИНЕ
# ==================================================================
log "[$ROLE] Базовая настройка: hostname, timezone, пакеты"

hostnamectl set-hostname "${ROLE}.${DOMAIN}"
timedatectl set-timezone Europe/Moscow
apt-get update -y || true

# Пользователи — СТРОГО по ТЗ (пункт 3)
case "$ROLE" in
    hq-srv|br-srv)
        id sshuser &>/dev/null || useradd -u 2026 -G wheel -m sshuser
        echo "sshuser:P@ssw0rd" | chpasswd
        echo "sshuser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/sshuser
        chmod 440 /etc/sudoers.d/sshuser
        ;;
    hq-rtr|br-rtr)
        id net_admin &>/dev/null || useradd -G wheel -m net_admin
        echo "net_admin:P@ssw0rd" | chpasswd
        echo "net_admin ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/net_admin
        chmod 440 /etc/sudoers.d/net_admin
        ;;
esac

# --- Функция: NAT + ip_forward + автозагрузка (пункт 8) ---
setup_nat() {
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-forward.conf
    sysctl -p /etc/sysctl.d/99-forward.conf
    apt-get install -y iptables-services || true
    iptables -t nat -F POSTROUTING
    iptables -t nat -A POSTROUTING -o "$1" -j MASQUERADE
    iptables-save > /etc/sysconfig/iptables
    systemctl enable --now iptables
}

# --- Функция: SSH на серверах (пункт 5) ---
setup_ssh() {
    apt-get install -y openssh-server || true
    echo "Authorized access only" > /etc/banner
    # Порт — безопасный sed (меняет ТОЛЬКО строку Port)
    sed -i -E 's/^#?Port [0-9]+/Port 2026/' "$SSH_CONF"
    # Остальное — идемпотентно (не дублируется при повторном запуске)
    grep -q "^AllowUsers sshuser" "$SSH_CONF" || echo "AllowUsers sshuser" >> "$SSH_CONF"
    grep -q "^MaxAuthTries 2"    "$SSH_CONF" || echo "MaxAuthTries 2"    >> "$SSH_CONF"
    grep -q "^Banner /etc/banner" "$SSH_CONF" || echo "Banner /etc/banner" >> "$SSH_CONF"
    systemctl enable --now sshd
    systemctl restart sshd
}

# ==================================================================
# 1. ISP (пункт 2)
# ==================================================================
if [ "$ROLE" = "isp" ]; then
    log "Настройка ISP"

    C19=$(get_con "ens19")
    C20=$(get_con "ens20")
    C21=$(get_con "ens21")

    # ens19 — Интернет (DHCP от провайдера)
    nmcli con mod "$C19" ipv4.method auto
    # ens20 — к HQ-RTR (172.16.1.0/28)
    nmcli con mod "$C20" ipv4.addresses "172.16.1.14/28" ipv4.method manual
    # ens21 — к BR-RTR (172.16.2.0/28)
    nmcli con mod "$C21" ipv4.addresses "172.16.2.14/28" ipv4.method manual

    nmcli con up "$C19"
    nmcli con up "$C20"
    nmcli con up "$C21"

    setup_nat "ens19"

    log "ISP готов"
fi

# ==================================================================
# 2. HQ-RTR (пункты 4, 6, 7, 8, 9)
# ==================================================================
if [ "$ROLE" = "hq-rtr" ]; then
    log "Настройка HQ-RTR"
    apt-get install -y frr dhcp-server || true

    C20=$(get_con "ens20")
    C19=$(get_con "ens19")

    # Uplink к ISP
    nmcli con mod "$C20" \
        ipv4.addresses "172.16.1.2/28" \
        ipv4.gateway "172.16.1.14" \
        ipv4.dns "${DNS_IP}" \
        ipv4.dns-search "${DOMAIN}" \
        ipv4.method manual

    # Trunk — отключаем IP на самом интерфейсе
    nmcli con mod "$C19" ipv4.method disabled ipv6.method ignore

    # --- VLAN (пункт 4) ---
    nmcli con delete vlan100 2>/dev/null; true
    nmcli con delete vlan200 2>/dev/null; true
    nmcli con delete vlan999 2>/dev/null; true

    # VLAN 100: не более 32 адресов → /27
    nmcli con add type vlan con-name vlan100 ifname ens19.100 dev ens19 id 100 \
        ipv4.addresses "192.168.100.1/27" ipv4.method manual \
        ipv4.dns-search "${DOMAIN}"
    # VLAN 200: не менее 16 адресов → /28
    nmcli con add type vlan con-name vlan200 ifname ens19.200 dev ens19 id 200 \
        ipv4.addresses "192.168.200.1/28" ipv4.method manual \
        ipv4.dns-search "${DOMAIN}"
    # VLAN 999: не более 8 адресов → /29
    nmcli con add type vlan con-name vlan999 ifname ens19.999 dev ens19 id 999 \
        ipv4.addresses "192.168.99.1/29" ipv4.method manual \
        ipv4.dns-search "${DOMAIN}"

    nmcli con up "$C20"
    nmcli con up vlan100
    nmcli con up vlan200
    nmcli con up vlan999

    # --- NAT (пункт 8) ---
    setup_nat "ens20"

    # --- GRE туннель (пункт 6) + персистентность ---
    mkdir -p /etc/rc.d
    cat > /etc/rc.d/rc.local <<'RCEOF'
#!/bin/bash
ip tunnel add gre1 mode gre remote 172.16.2.2 local 172.16.1.2 ttl 64 2>/dev/null
ip addr replace 10.0.0.1/30 dev gre1
ip link set gre1 up
RCEOF
    chmod +x /etc/rc.d/rc.local
    systemctl enable rc-local 2>/dev/null || true
    /etc/rc.d/rc.local

    # --- DHCP (пункт 9) ---
    echo 'DHCPDARGS="ens19.200"' > /etc/sysconfig/dhcpd
    cat > /etc/dhcp/dhcpd.conf <<DHCPEOF
subnet 192.168.200.0 netmask 255.255.255.240 {
    range 192.168.200.2 192.168.200.14;
    option routers 192.168.200.1;
    option domain-name-servers ${DNS_IP};
    option domain-name "${DOMAIN}";
}
subnet 192.168.100.0 netmask 255.255.255.224 {}
subnet 192.168.99.0 netmask 255.255.255.248 {}
subnet 172.16.1.0 netmask 255.255.255.240 {}
DHCPEOF
    systemctl enable --now dhcpd
    systemctl restart dhcpd || true

    # --- OSPF (пункт 7) ---
    sed -i 's/^ospfd=.*/ospfd=yes/' /etc/frr/daemons
    grep -q '^ospfd=yes' /etc/frr/daemons || echo "ospfd=yes" >> /etc/frr/daemons

    cat > /etc/frr/frr.conf <<'FRREOF'
frr defaults traditional
!
interface gre1
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 exam2025
!
router ospf
 passive-interface default
 no passive-interface gre1
 network 10.0.0.0/30 area 0
 network 192.168.100.0/27 area 0
 network 192.168.200.0/28 area 0
 network 192.168.99.0/29 area 0
 area 0 authentication message-digest
!
FRREOF
    chown frr:frr /etc/frr/frr.conf
    chmod 640 /etc/frr/frr.conf
    systemctl enable --now frr
    systemctl restart frr

    log "HQ-RTR готов"
fi

# ==================================================================
# 3. BR-RTR (пункты 6, 7, 8)
# ==================================================================
if [ "$ROLE" = "br-rtr" ]; then
    log "Настройка BR-RTR"
    apt-get install -y frr || true

    C20=$(get_con "ens20")
    C21=$(get_con "ens21")

    nmcli con mod "$C20" \
        ipv4.addresses "172.16.2.2/28" \
        ipv4.gateway "172.16.2.14" \
        ipv4.dns "${DNS_IP}" \
        ipv4.dns-search "${DOMAIN}" \
        ipv4.method manual

    # LAN к BR-SRV: не более 16 адресов → /28
    nmcli con mod "$C21" \
        ipv4.addresses "192.168.1.1/28" \
        ipv4.method manual \
        ipv4.dns-search "${DOMAIN}"

    nmcli con up "$C20"
    nmcli con up "$C21"

    setup_nat "ens20"

    # --- GRE (пункт 6) ---
    mkdir -p /etc/rc.d
    cat > /etc/rc.d/rc.local <<'RCEOF'
#!/bin/bash
ip tunnel add gre1 mode gre remote 172.16.1.2 local 172.16.2.2 ttl 64 2>/dev/null
ip addr replace 10.0.0.2/30 dev gre1
ip link set gre1 up
RCEOF
    chmod +x /etc/rc.d/rc.local
    systemctl enable rc-local 2>/dev/null || true
    /etc/rc.d/rc.local

    # --- OSPF (пункт 7) ---
    sed -i 's/^ospfd=.*/ospfd=yes/' /etc/frr/daemons
    grep -q '^ospfd=yes' /etc/frr/daemons || echo "ospfd=yes" >> /etc/frr/daemons

    cat > /etc/frr/frr.conf <<'FRREOF'
frr defaults traditional
!
interface gre1
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 exam2025
!
router ospf
 passive-interface default
 no passive-interface gre1
 network 10.0.0.0/30 area 0
 network 192.168.1.0/28 area 0
 area 0 authentication message-digest
!
FRREOF
    chown frr:frr /etc/frr/frr.conf
    chmod 640 /etc/frr/frr.conf
    systemctl enable --now frr
    systemctl restart frr

    log "BR-RTR готов"
fi

# ==================================================================
# 4. HQ-SRV (пункты 1, 5, 10)
# ==================================================================
if [ "$ROLE" = "hq-srv" ]; then
    log "Настройка HQ-SRV"
    apt-get install -y bind openssh-server || true

    C19=$(get_con "ens19")
    nmcli con mod "$C19" \
        ipv4.addresses "192.168.100.2/27" \
        ipv4.gateway "192.168.100.1" \
        ipv4.dns "127.0.0.1" \
        ipv4.dns-search "${DOMAIN}" \
        ipv4.method manual
    nmcli con up "$C19"

    # --- SSH (пункт 5) ---
    setup_ssh

    # --- DNS (пункт 10) ---
    # Определение путей для ALT
    NAMED_CONF="/etc/named.conf"
    NAMED_DIR="/var/named"
    [ -d "/etc/bind" ]     && NAMED_CONF="/etc/bind/named.conf"
    [ -d "/var/lib/bind" ] && NAMED_DIR="/var/lib/bind"
    mkdir -p "${NAMED_DIR}/zone"

    # named.conf — полная перезапись (безопаснее sed)
    cat > "${NAMED_CONF}" <<NAMEDEOF
options {
    directory "${NAMED_DIR}";
    forwarders { 77.88.8.7; 77.88.8.3; };
    allow-query { any; };
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
    file "zone/100.rev";
};

zone "200.168.192.in-addr.arpa" {
    type master;
    file "zone/200.rev";
};
NAMEDEOF

    # Прямая зона — ВСЕ записи из Таблицы 3
    cat > "${NAMED_DIR}/zone/forward.zone" <<FWDEOF
\$TTL 86400
@       IN  SOA   hq-srv.${DOMAIN}. admin.${DOMAIN}. (
                  2025060801 3600 900 1209600 86400 )
        IN  NS    hq-srv.${DOMAIN}.

hq-rtr  IN  A     192.168.100.1
hq-srv  IN  A     192.168.100.2
hq-cli  IN  A     192.168.200.2
br-rtr  IN  A     192.168.1.1
br-srv  IN  A     192.168.1.2
docker  IN  A     172.16.1.14
web     IN  A     172.16.2.14
FWDEOF

    # PTR — 100.168.192 (hq-rtr и hq-srv)
    cat > "${NAMED_DIR}/zone/100.rev" <<REVEOF
\$TTL 86400
@   IN  SOA   hq-srv.${DOMAIN}. admin.${DOMAIN}. (
              2025060801 3600 900 1209600 86400 )
    IN  NS    hq-srv.${DOMAIN}.

1   IN  PTR   hq-rtr.${DOMAIN}.
2   IN  PTR   hq-srv.${DOMAIN}.
REVEOF

    # PTR — 200.168.192 (hq-cli)
    cat > "${NAMED_DIR}/zone/200.rev" <<REVEOF
\$TTL 86400
@   IN  SOA   hq-srv.${DOMAIN}. admin.${DOMAIN}. (
              2025060801 3600 900 1209600 86400 )
    IN  NS    hq-srv.${DOMAIN}.

2   IN  PTR   hq-cli.${DOMAIN}.
REVEOF

    chown -R named:named "${NAMED_DIR}"
    chmod -R 755 "${NAMED_DIR}"

    # Валидация + запуск (автоопределение имени сервиса)
    named-checkconf "${NAMED_CONF}" && log "DNS: конфиг валиден" || echo "ОШИБКА в DNS-конфиге!"
    named-checkzone "${DOMAIN}" "${NAMED_DIR}/zone/forward.zone" 2>/dev/null
    systemctl enable named 2>/dev/null || systemctl enable bind 2>/dev/null
    systemctl restart named 2>/dev/null || systemctl restart bind 2>/dev/null

    log "HQ-SRV готов"
fi

# ==================================================================
# 5. BR-SRV (пункты 1, 3, 5)
# ==================================================================
if [ "$ROLE" = "br-srv" ]; then
    log "Настройка BR-SRV"
    apt-get install -y openssh-server || true

    C19=$(get_con "ens19")
    nmcli con mod "$C19" \
        ipv4.addresses "192.168.1.2/28" \
        ipv4.gateway "192.168.1.1" \
        ipv4.dns "${DNS_IP}" \
        ipv4.dns-search "${DOMAIN}" \
        ipv4.method manual
    nmcli con up "$C19"

    # SSH (пункт 5)
    setup_ssh

    log "BR-SRV готов"
fi

# ==================================================================
# 6. HQ-CLI (пункт 9 — DHCP-клиент)
# ==================================================================
if [ "$ROLE" = "hq-cli" ]; then
    log "Настройка HQ-CLI"

    C19=$(get_con "ens19")
    nmcli con mod "$C19" \
        ipv4.method auto \
        ipv4.dns-search "${DOMAIN}"
    nmcli con up "$C19"

    log "HQ-CLI готов"
fi

# ==================================================================
# АВТОМАТИЧЕСКАЯ ПРОВЕРКА
# ==================================================================
echo ""
echo "========================================"
echo "  ПРОВЕРКА: $ROLE"
echo "========================================"

case "$ROLE" in
    isp)
        echo -n "Интернет: ";   ping -c1 -W2 8.8.8.8   &>/dev/null && echo "✅" || echo "❌"
        echo -n "К HQ-RTR: ";   ping -c1 -W2 172.16.1.2 &>/dev/null && echo "✅" || echo "❌"
        echo -n "К BR-RTR: ";   ping -c1 -W2 172.16.2.2 &>/dev/null && echo "✅" || echo "❌"
        echo "NAT:"; iptables -t nat -L POSTROUTING -n 2>/dev/null | grep MASQ
        ;;
    hq-rtr)
        echo -n "К ISP: ";      ping -c1 -W2 172.16.1.14 &>/dev/null && echo "✅" || echo "❌"
        echo -n "GRE к BR: ";   ping -c1 -W2 10.0.0.2    &>/dev/null && echo "✅" || echo "❌"
        echo "OSPF маршруты:"
        vtysh -c "show ip route ospf" 2>/dev/null || echo "  FRR не готов (запустите после BR-RTR)"
        echo -n "DHCP: "; systemctl is-active dhcpd 2>/dev/null && echo "✅" || echo "❌"
        ;;
    br-rtr)
        echo -n "К ISP: ";      ping -c1 -W2 172.16.2.14 &>/dev/null && echo "✅" || echo "❌"
        echo -n "GRE к HQ: ";   ping -c1 -W2 10.0.0.1    &>/dev/null && echo "✅" || echo "❌"
        echo "OSPF маршруты:"
        vtysh -c "show ip route ospf" 2>/dev/null || echo "  FRR не готов"
        ;;
    hq-srv)
        echo -n "К шлюзу: ";    ping -c1 -W2 192.168.100.1 &>/dev/null && echo "✅" || echo "❌"
        echo -n "DNS конфиг: "; named-checkconf &>/dev/null && echo "✅" || echo "❌"
        echo -n "DNS сервис: "; (systemctl is-active named 2>/dev/null || systemctl is-active bind 2>/dev/null) && echo "✅" || echo "❌"
        echo -n "SSH порт: ";   grep "^Port" "$SSH_CONF" 2>/dev/null || echo "не настроен"
        ;;
    br-srv)
        echo -n "К шлюзу: ";    ping -c1 -W2 192.168.1.1 &>/dev/null && echo "✅" || echo "❌"
        echo -n "SSH порт: ";   grep "^Port" "$SSH_CONF" 2>/dev/null || echo "не настроен"
        echo -n "Баннер: ";     [ -f /etc/banner ] && echo "✅" || echo "❌"
        ;;
    hq-cli)
        echo "IP-адрес:"; ip -4 addr show ens19 2>/dev/null | grep inet
        echo -n "Интернет: ";   ping -c1 -W2 8.8.8.8 &>/dev/null && echo "✅" || echo "❌"
        echo -n "DNS (A): ";    nslookup hq-srv.${DOMAIN} ${DNS_IP} 2>/dev/null | grep -q "192.168.100.2" && echo "✅" || echo "❌"
        echo -n "DNS (PTR): ";  nslookup 192.168.100.2 ${DNS_IP} 2>/dev/null | grep -q "hq-srv" && echo "✅" || echo "❌"
        ;;
esac

echo "========================================"
echo "  $ROLE — ЗАВЕРШЁН"
echo "========================================"