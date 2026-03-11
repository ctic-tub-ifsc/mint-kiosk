#!/bin/bash

# Script de Configuração do Kiosk para Linux Mint
# Versão unificada com suporte a PWA e detecção inteligente de travamentos
# Autor: Baseado em scripts validados para Raspberry Pi e Linux Mint

set -e  # Sai imediatamente se algum comando falhar

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ============================================
#          FUNÇÃO DE VALIDAÇÃO DE URL
# ============================================

validate_url() {
    local input_url="$1"
    
    # Remove espaços
    input_url=$(echo "$input_url" | xargs)
    
    # Se vazio, erro
    [[ -z "$input_url" ]] && return 1
    
    # Converte para minúsculas (URLs são case-insensitive para domínio)
    input_url=$(echo "$input_url" | tr '[:upper:]' '[:lower:]')
    
    # Corrige protocolos mal digitados
    input_url=$(echo "$input_url" | sed \
        -e 's/^htp:\/\//https:\/\//' \
        -e 's/^htt:\/\//https:\/\//' \
        -e 's/^htps:\/\//https:\/\//' \
        -e 's/^http:\/\/https:\/\//https:\/\//' \
        -e 's/^https:\/\/http:\/\//https:\/\//')
    
    # Extrai parte do domínio (sem protocolo)
    local domain_part="$input_url"
    if [[ "$input_url" =~ ^[a-zA-Z]+:/* ]]; then
        domain_part=$(echo "$input_url" | sed -E 's#^[a-zA-Z]+:/*##')
    fi
    
    # Remove barras extras no início e fim
    domain_part=$(echo "$domain_part" | sed 's#^/*##' | sed 's#/*$##')
    
    # Se tiver caminho, preserva
    local path=""
    if [[ "$domain_part" =~ ^([^/]+)(/.*)?$ ]]; then
        domain_part="${BASH_REMATCH[1]}"
        path="${BASH_REMATCH[2]}"
    fi
    
    # Verifica se é IP ou domínio
    if [[ ! "$input_url" =~ ^https?:// ]]; then
        if [[ "$domain_part" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?$ ]]; then
            # É IP, usa http://
            final_url="http://$domain_part"
        else
            # É domínio, usa https://
            final_url="https://$domain_part"
        fi
    else
        final_url="$input_url"
    fi
    
    # Adiciona caminho se existir
    if [[ -n "$path" ]]; then
        # Remove barras duplicadas
        path=$(echo "$path" | sed 's#//*#/#g')
        final_url="${final_url}${path}"
    fi
    
    echo "$final_url"
}

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Instalação do Sistema Kiosk - PWA     ${NC}"
echo -e "${GREEN}========================================${NC}"

# ============================================
#               CONFIGURAÇÕES
# ============================================

INSTALL_DIR="/home/$(logname)/kiosk"
LOG_FILE="/var/log/kiosk_monitor.log"
CHROMIUM_USER_DATA="/home/$(logname)/.config/chromium-kiosk"
SCREENSHOT_DIR="/var/log/kiosk_screenshots"

# Coletar URL com validação
while true; do
    echo -e "${YELLOW}Por favor, digite a URL do Mural:${NC}"
    echo -e "${YELLOW}Exemplos:${NC}"
    echo -e "  • https://mural.exemplo.com.br"
    echo -e "  • 192.168.1.100:8080"
    echo -e "  • mural.intranet.local"
    read -p "URL: " RAW_URL
    
    # Valida e corrige a URL
    KIOSK_URL=$(validate_url "$RAW_URL")
    
    # Se validação falhou
    if [[ -z "$KIOSK_URL" ]]; then
        echo -e "${RED}ERRO: URL não pode estar vazia. Tente novamente.${NC}"
        continue
    fi
    
    # Mostra o resultado
    echo -e "${GREEN}✓ URL processada: $KIOSK_URL${NC}"
    
    # Teste rápido de conectividade
    echo -e "${YELLOW}Testando conexão...${NC}"
    if curl --output /dev/null --silent --head --fail --max-time 5 "$KIOSK_URL"; then
        echo -e "${GREEN}✓ URL acessível!${NC}"
    else
        echo -e "${YELLOW}⚠ ATENÇÃO: URL parece inacessível no momento${NC}"
        echo -e "${YELLOW}  O sistema continuará a instalação, mas o mural pode não carregar até que a rede esteja disponível.${NC}"
    fi
    
    echo -e "${YELLOW}Confirmar URL? (s/N):${NC}"
    read -p "> " CONFIRM
    
    if [[ "$CONFIRM" =~ ^[Ss]$ ]]; then
        break
    fi
done

# Configuração VNC (opcional)
echo -e "${YELLOW}Deseja configurar acesso VNC? (s/N):${NC}"
read -p "> " CONFIG_VNC
CONFIG_VNC=${CONFIG_VNC:-N}

if [[ "$CONFIG_VNC" =~ ^[Ss]$ ]]; then
    echo -e "${YELLOW}Digite a senha para acesso VNC:${NC}"
    read -s -p "> " VNC_PASSWORD
    echo
fi

# ============================================
#          INSTALAÇÃO DE DEPENDÊNCIAS
# ============================================

echo -e "${GREEN}[1/8] Instalando dependências do sistema...${NC}"
sudo apt-get update
sudo apt-get install -y \
    unclutter \
    xdotool \
    curl \
    wget \
    openssh-server \
    x11-utils \
    xprintidle \
    imagemagick \
    gnome-screenshot \
    ufw \
    bc

# ============================================
#          SCRIPT PRINCIPAL DO KIOSK
#         (Versão corrigida - sem refresh cego)
# ============================================

echo -e "${GREEN}[2/8] Criando script do kiosk com monitor inteligente...${NC}"
mkdir -p "$INSTALL_DIR"
mkdir -p "$SCREENSHOT_DIR"
sudo chmod 755 "$SCREENSHOT_DIR"

cat > "$INSTALL_DIR/kiosk.sh" << 'EOF'
#!/bin/bash

# ============================================
#    SCRIPT DO KIOSK - MONITOR INTELIGENTE
#    SEM refresh cego - Apenas age quando necessário
# ============================================

# Configurações
LOG_FILE="/var/log/kiosk_monitor.log"
CHROMIUM_USER_DATA="/home/$(logname)/.config/chromium-kiosk"
SCREENSHOT_DIR="/var/log/kiosk_screenshots"
KIOSK_URL="$1"

# Timeouts e limites
CHECK_INTERVAL=30          # Verificar a cada 30 segundos
IDLE_THRESHOLD=120         # 2 minutos sem resposta = travado
CRASH_THRESHOLD=3          # 3 falhas seguidas = reinício completo
OFFLINE_CHECK_INTERVAL=60  # Verificar URL offline a cada 1 minuto
MAX_SCREENSHOTS=10         # Manter apenas os últimos 10 screenshots

# Criar diretórios
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$SCREENSHOT_DIR"
mkdir -p "$CHROMIUM_USER_DATA"

# Limpar screenshots antigos (manter apenas os últimos MAX_SCREENSHOTS)
cleanup_screenshots() {
    cd "$SCREENSHOT_DIR" 2>/dev/null || return
    ls -t *.png 2>/dev/null | tail -n +$((MAX_SCREENSHOTS + 1)) | xargs -r rm
}

# Função de log
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Função para capturar screenshot de diagnóstico (APENAS em falhas)
capture_diagnostic_screenshot() {
    local reason="$1"
    local filename="$SCREENSHOT_DIR/diagnostic_$(date +%Y%m%d_%H%M%S)_${reason}.png"
    
    # Tentar capturar a tela atual
    if DISPLAY=:0 gnome-screenshot -w -f "$filename" 2>/dev/null; then
        log "Screenshot de diagnóstico salvo: $filename"
        cleanup_screenshots
    else
        log "Falha ao capturar screenshot de diagnóstico"
    fi
}

# Verificação de saúde do Chromium (NÃO gera screenshot automaticamente)
check_chromium_health() {
    local pid
    local window_count
    local idle_time
    
    # Verificar processo
    pid=$(pgrep -f "chromium.*$KIOSK_URL" | head -1)
    if [[ -z "$pid" ]]; then
        log "ERRO: Processo Chromium não encontrado"
        return 1
    fi
    
    # Verificar se processo está respondendo
    if ! kill -0 "$pid" 2>/dev/null; then
        log "ERRO: Processo Chromium não está respondendo"
        return 1
    fi
    
    # Verificar janelas visíveis
    export DISPLAY=:0
    window_count=$(xdotool search --onlyvisible --class "chromium" 2>/dev/null | wc -l)
    if [[ "$window_count" -eq 0 ]]; then
        log "ERRO: Nenhuma janela Chromium visível"
        return 1
    fi
    
    # Verificar se a janela está congelada (não responde a eventos)
    if ! xdotool search --onlyvisible --class "chromium" windowfocus 2>/dev/null; then
        log "ERRO: Janela Chromium não aceita foco"
        return 1
    fi
    
    # Verificar idle time da aplicação
    idle_time=$(xprintidle 2>/dev/null || echo 0)
    if [[ "$idle_time" -gt "$((IDLE_THRESHOLD * 1000))" ]]; then
        log "AVISO: Janela inativa por $(($idle_time / 1000)) segundos"
    fi
    
    return 0
}

# Verificação de conectividade da URL
check_url_health() {
    local http_code
    local start_time
    local end_time
    local response_time
    
    start_time=$(date +%s%N)
    http_code=$(curl -o /dev/null -s -w "%{http_code}" --max-time 15 --connect-timeout 10 "$KIOSK_URL")
    end_time=$(date +%s%N)
    
    response_time=$(( (end_time - start_time) / 1000000 ))
    
    if [[ "$http_code" == "200" ]]; then
        log "URL OK (${response_time}ms)"
        return 0
    else
        log "ERRO: URL retornou HTTP $http_code (${response_time}ms)"
        return 1
    fi
}

# Função para verificar se o PWA tem conteúdo em cache
check_cached_content() {
    if DISPLAY=:0 xdotool search --onlyvisible --class "chromium" key --clearmodifiers "Ctrl+l" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Reinicialização completa do Chromium
restart_chromium() {
    log "REINICIANDO Chromium completamente..."
    
    capture_diagnostic_screenshot "pre_restart"
    
    pkill -f chromium
    sleep 5
    
    if [[ -f "$CHROMIUM_USER_DATA/Default/Preferences" ]]; then
        sed -i 's/"exited_cleanly":false/"exited_cleanly":true/' "$CHROMIUM_USER_DATA/Default/Preferences"
        sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/' "$CHROMIUM_USER_DATA/Default/Preferences"
    fi
    
    export DISPLAY=:0
    chromium \
        --user-data-dir="$CHROMIUM_USER_DATA" \
        --kiosk \
        --noerrdialogs \
        --disable-infobars \
        --disable-pinch \
        --overscroll-history-navigation=0 \
        --disable-features=TranslateUI \
        --disable-session-crashed-bubble \
        --disable-component-update \
        --disable-background-networking \
        --autoplay-policy=no-user-gesture-required \
        --enable-features=OverlayScrollbar,OverlayScrollbarFlashAfterAnyScrollUpdate,OverlayScrollbarFlashWhenMouseEnter \
        --app="$KIOSK_URL" &
    
    log "Chromium reiniciado (PID: $!)"
    sleep 10
}

# Refresh suave - APENAS quando necessário
soft_refresh() {
    local reason="$1"
    
    log "Executando refresh inteligente (motivo: $reason)..."
    export DISPLAY=:0
    
    capture_diagnostic_screenshot "pre_refresh_${reason}"
    
    if xdotool search --onlyvisible --class "chromium" windowactivate --sync key --clearmodifiers F5 2>/dev/null; then
        log "Refresh via F5 executado"
        return 0
    fi
    
    if xdotool search --onlyvisible --class "chromium" windowactivate --sync key --clearmodifiers "ctrl+r" 2>/dev/null; then
        log "Refresh via Ctrl+R executado"
        return 0
    fi
    
    log "Falha ao executar refresh suave"
    return 1
}

# ============================================
#          INICIALIZAÇÃO
# ============================================

log "=== INICIANDO SISTEMA KIOSK ==="
log "URL: $KIOSK_URL"
log "Data: $(date)"

export DISPLAY=:0
xset s off
xset -dpms
unclutter -idle 0.5 -root &

restart_chromium

# ============================================
#          LOOP PRINCIPAL - SEM CRON!
# ============================================

consecutive_failures=0
was_offline=false
last_url_check=0

while true; do
    current_time=$(date +%s)
    
    if ! check_chromium_health; then
        ((consecutive_failures++))
        log "Falha de saúde #$consecutive_failures"
        
        if [[ $consecutive_failures -ge $CRASH_THRESHOLD ]]; then
            log "Múltiplas falhas consecutivas ($consecutive_failures). Reiniciando completamente."
            restart_chromium
            consecutive_failures=0
        else
            if soft_refresh "chromium_unhealthy"; then
                log "Refresh suave recuperou o Chromium"
                consecutive_failures=0
            else
                log "Refresh suave falhou. Aguardando próxima verificação."
            fi
        fi
    else
        if [[ $((current_time - last_url_check)) -ge $OFFLINE_CHECK_INTERVAL ]]; then
            if check_url_health; then
                if [[ "$was_offline" == true ]]; then
                    log "URL voltou ao normal. Fazendo refresh para garantir."
                    soft_refresh "url_back_online"
                    was_offline=false
                fi
                consecutive_failures=0
            else
                was_offline=true
                log "URL offline - aguardando recuperação da rede"
                
                if check_cached_content; then
                    log "PWA exibindo conteúdo em cache - OK"
                else
                    log "AVISO: PWA sem cache disponível"
                fi
            fi
            last_url_check=$current_time
        fi
        
        consecutive_failures=0
    fi
    
    if [[ $((current_time % 3600)) -lt $CHECK_INTERVAL ]]; then
        if [[ -f "$LOG_FILE" ]] && [[ $(wc -l < "$LOG_FILE") -gt 1000 ]]; then
            tail -n 1000 "$LOG_FILE" > "${LOG_FILE}.tmp"
            mv "${LOG_FILE}.tmp" "$LOG_FILE"
        fi
    fi
    
    sleep $CHECK_INTERVAL
done
EOF

chmod +x "$INSTALL_DIR/kiosk.sh"

# ============================================
#          SCRIPT DE EMERGÊNCIA (OPCIONAL)
#          CORRIGIDO: while loop com sintaxe correta
# ============================================

echo -e "${GREEN}[3/8] Criando script de emergência (apenas para casos extremos)...${NC}"
cat > "$INSTALL_DIR/emergency_refresh.sh" << 'EOF'
#!/bin/bash
# Script de EMERGÊNCIA - executado manualmente ou em casos extremos
# NÃO configurar no cron automático!
# VERSÃO CORRIGIDA: while loop com sintaxe adequada

LOG_FILE="/var/log/kiosk_emergency.log"
EMERGENCY_FILE="/tmp/kiosk_emergency"
USER_HOME="/home/$(logname)"

# Função de log
log_emergency() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_emergency "Script de emergência iniciado"

# Determina se deve executar (flag de emergência ou força manual)
if [[ -f "$EMERGENCY_FILE" ]] || [[ "$1" == "--force" ]]; then
    log_emergency "Executando refresh forçado em todas as janelas Chromium"
    
    export DISPLAY=:0
    export XAUTHORITY="$USER_HOME/.Xauthority"
    
    # CORREÇÃO: while loop com sintaxe correta (do)
    /usr/bin/xdotool search --onlyvisible --class "chromium" | while read window; do
        log_emergency "Enviando F5 para janela: $window"
        /usr/bin/xdotool windowactivate --sync "$window" key --clearmodifiers F5
        sleep 0.5  # Pequena pausa entre janelas
    done
    
    # Remove a flag se existir
    if [[ -f "$EMERGENCY_FILE" ]]; then
        rm -f "$EMERGENCY_FILE"
        log_emergency "Flag de emergência removida"
    fi
    
    log_emergency "Refresh de emergência concluído"
else
    log_emergency "Nenhuma flag de emergência encontrada. Use --force para executar manualmente."
    echo "Para executar refresh manual: $0 --force"
    echo "Ou crie a flag: touch $EMERGENCY_FILE"
    exit 1
fi

exit 0
EOF

chmod +x "$INSTALL_DIR/emergency_refresh.sh"

# ============================================
#          SERVIÇO SYSTEMD
# ============================================

echo -e "${GREEN}[4/8] Criando serviço systemd...${NC}"
sudo tee /etc/systemd/system/kiosk.service > /dev/null << EOF
[Unit]
Description=Kiosk Mode - Monitor Inteligente
After=network.target graphical.target
Wants=network.target

[Service]
Type=simple
User=$(logname)
Group=$(logname)
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/$(logname)/.Xauthority
ExecStart=/bin/bash $INSTALL_DIR/kiosk.sh "$KIOSK_URL"
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=graphical.target
EOF

# ============================================
#          REMOVER CRON AGRESSIVO
# ============================================

echo -e "${GREEN}[5/8] Removendo crons agressivos (se existirem)...${NC}"
(crontab -u $(logname) -l 2>/dev/null | grep -v "xdotool\|F5\|refresh" || true) | crontab -u $(logname) -

# ============================================
#          CONFIGURAÇÕES DO SISTEMA
# ============================================

echo -e "${GREEN}[6/8] Configurações de energia e tela...${NC}"
gsettings set org.gnome.desktop.screensaver idle-activation-enabled false
gsettings set org.gnome.desktop.screensaver lock-enabled false
gsettings set org.gnome.desktop.session idle-delay 0
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
gsettings set org.gnome.desktop.interface enable-animations false
gsettings set org.gnome.desktop.notifications show-banners false

# ============================================
#          CONFIGURAÇÃO VNC (OPCIONAL)
# ============================================

if [[ "$CONFIG_VNC" =~ ^[Ss]$ ]] && [[ -n "$VNC_PASSWORD" ]]; then
    echo -e "${GREEN}[7/8] Configurando VNC...${NC}"
    sudo apt-get install -y vino
    
    gsettings set org.gnome.Vino prompt-enabled false
    gsettings set org.gnome.Vino require-encryption false
    gsettings set org.gnome.Vino authentication-methods "['vnc']"
    gsettings set org.gnome.Vino vnc-password "$(echo -n "$VNC_PASSWORD" | base64)"
    
    sudo ufw allow 5900/tcp
    sudo ufw --force enable
    
    systemctl --user enable vino-server
    systemctl --user start vino-server
    
    echo -e "${GREEN}VNC configurado na porta 5900${NC}"
fi

# ============================================
#          INSTALAÇÃO DO CHROMIUM
# ============================================

echo -e "${GREEN}[8/8] Instalando Chromium...${NC}"
if ! command -v chromium &> /dev/null; then
    sudo apt-get install -y chromium-browser || {
        wget -O /tmp/chromium.deb http://packages.linuxmint.com/pool/upstream/c/chromium/chromium_latest_amd64.deb
        sudo dpkg -i /tmp/chromium.deb || true
        sudo apt-get install -f -y
        rm /tmp/chromium.deb
    }
fi

# ============================================
#          FINALIZAÇÃO
# ============================================

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  INSTALAÇÃO COMPLETA!                  ${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "URL: $KIOSK_URL"
echo -e "Modo: PWA com cache offline habilitado"
echo -e "Monitor: Inteligente (sem refresh cego)"
echo -e "Screenshots: Apenas em falhas (máx 10)"
echo -e "Logs: $LOG_FILE"
echo -e ""
echo -e "${YELLOW}IMPORTANTE:${NC}"
echo -e "- O sistema NÃO faz refresh automático cego"
echo -e "- Screenshots são gerados APENAS quando há falha"
echo -e "- O PWA pode usar cache offline normalmente"
echo -e "- Em caso de problemas, verifique os logs:"
echo -e "  sudo tail -f $LOG_FILE"
echo -e ""
echo -e "${YELLOW}SCRIPT DE EMERGÊNCIA:${NC}"
echo -e "  Para refresh manual: $INSTALL_DIR/emergency_refresh.sh --force"
echo -e "  Logs: /var/log/kiosk_emergency.log"
echo -e ""
echo -e "${YELLOW}Reiniciando em 10 segundos...${NC}"
sleep 10
sudo reboot
