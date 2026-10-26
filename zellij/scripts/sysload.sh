#!/bin/bash
case "$(basename "$0")" in
   zj-tgt.sh)
    if [ -s /tmp/target ]; then
        N=$(wc -l < /tmp/target)
        if [ "$N" -le 3 ]; then
            echo "TGT: $(paste -sd' ' /tmp/target) //"
        else
            echo "TGT($N): $(cut -d= -f1 /tmp/target | paste -sd' ') //"
        fi
    fi
    ;;
  zj-ports.sh)
    PORTS=$(ss -tulpn 2>/dev/null | awk 'NR>1 {print $5}' | awk -F: '{print $NF}' | grep -E '^(80|443|4444|8000|8080|8443|9001)$' | sort -u | paste -sd "," -)
    [ -n "$PORTS" ] && echo "LPORT: $PORTS //"
    ;;
  zj-net.sh)
    VPN_IP=$(ip -4 addr show tun0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    LOCAL_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP '(?<=src\s)\d+(\.\d+){3}')
    if [ -n "$VPN_IP" ]; then
        echo "TUN0: $VPN_IP //"
    elif [ -n "$LOCAL_IP" ]; then
        echo "LAN: $LOCAL_IP //"
    else
        echo "OFFLINE //"
    fi
    ;;
#  zj-ram.sh)
#    free -m | awk '/Mem:/ { printf("MEM: %.0f%%\n", $3/$2 * 100) }'
#    ;;
esac
exit 0
