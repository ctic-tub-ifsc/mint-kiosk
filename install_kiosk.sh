#!/bin/bash

echo "Instalando dependências necessárias (unclutter, xdotool, curl, chromium-browser, chromium-codecs-ffmpeg-extra)..."
sudo apt-get update
sudo apt-get install -y unclutter xdotool curl # chromium-browser chromium-codecs-ffmpeg-extra

echo "Configura Navegador Chromium para TV Kiosk"

# --- Conteúdo do script kiosk.sh (o monitor de serviço) ---
# Este conteúdo será escrito para /home/pi/kiosk.sh
read -r -d '' kiosk_script_content << EOF
#!/bin/bash

# ============================================
#               CONFIGURAÇÕES
# ============================================

# Caminho completo para o arquivo de log
# Script deve ser executado com privilégios de root para gravar aqui
LOG_FILE="/var/log/chromium_kiosk.log"

# Número máximo de linhas a serem mantidas no arquivo de log
# Se o arquivo exceder este número, as linhas mais antigas serão removidas.
MAX_LOG_LINES=500 # Exemplo: manter as últimas 500 linhas

# ============================================
#             FIM DAS CONFIGURAÇÕES
# ============================================


# Garante que o diretório de log exista
mkdir -p "\$(dirname "\$LOG_FILE")"

# Função para aparar o arquivo de log
trim_log_file() {
    if [ -f "\$LOG_FILE" ]; then
        local current_lines=\$(wc -l < "\$LOG_FILE")
        if [ "\$current_lines" -gt "\$MAX_LOG_LINES" ]; then
            tail -n "\$MAX_LINES" "\$LOG_FILE" > "\${LOG_FILE}.tmp"
            mv "\${LOG_FILE}.tmp" "\$LOG_FILE"
            echo "\$(date): Log aparado para as últimas \$MAX_LOG_LINES linhas."
        fi
    fi
}

# Redireciona stdout e stderr para o arquivo de log e também para o console
exec > >(tee -a "\$LOG_FILE") 2>&1

echo "--- Script de Kiosk iniciado em \$(date) ---"
echo "\$(date): Log sendo salvo em: \$LOG_FILE"

# KIOSK_URL é esperada como uma variável de ambiente (definida pelo systemd)
# Um fallback é fornecido caso não esteja definida (útil para testes manuais do kiosk.sh)
KIOSK_URL="\${KIOSK_URL:-\"https://www.example.com\"}"

echo "\$(date): URL do quiosque configurada para: \$KIOSK_URL (via ambiente)"


# --- Parte de configuração de ambiente X (CRÍTICA para interação com GUI) ---
DISPLAY_VAR=":0" # Display padrão para sessão gráfica
X_USER=\$(who | awk '/:0|:1/ {print \$1; exit}') # Tenta determinar o usuário da sessão X
if [ -z "\$X_USER" ]; then
    echo "\$(date): ALERTA: Não foi possível determinar o usuário do display X. Tentando 'pi' por padrão."
    X_USER="pi" # Fallback comum para Raspberry Pi
fi

# Tenta encontrar o arquivo XAUTHORITY do usuário da sessão X
XAUTHORITY_FILE="/home/\$X_USER/.Xauthority"
if [ ! -f "\$XAUTHORITY_FILE" ]; then
    echo "\$(date): ERRO CRÍTICO: Arquivo XAUTHORITY não encontrado em \$XAUTHORITY_FILE para o usuário \$X_USER."
    echo "\$(date): Sem este arquivo, comandos GUI (xset, unclutter) podem falhar ou o Chromium não iniciar corretamente."
    echo "\$(date): Verifique se o usuário \$X_USER está logado graficamente e se o .Xauthority existe."
fi
# --- Fim da parte de configuração de ambiente X ---

# Desabilita o screensaver e gerenciamento de energia
sudo -u "\$X_USER" env DISPLAY="\$DISPLAY_VAR" XAUTHORITY="\$XAUTHORITY_FILE" xset s noblank
sudo -u "\$X_USER" env DISPLAY="\$DISPLAY_VAR" XAUTHORITY="\$XAUTHORITY_FILE" xset s off
sudo -u "\$X_USER" env DISPLAY="\$DISPLAY_VAR" XAUTHORITY="\$XAUTHORITY_FILE" xset -dpms
echo "\$(date): Screensaver e DPMS desabilitados (para o usuário \$X_USER)."

# Configura a saída de áudio para Headphone (Fone de ouvido)
echo "\$(date): Configurando a saída de áudio para Headphone..."
sudo raspi-config nonint do_audio 0
sleep 1

# Garante que o volume do áudio esteja no máximo (usando o canal PCM)
sudo -u "\$X_USER" amixer sset 'PCM' 100%
echo "\$(date): Volume do áudio definido para 100%."

# Esconde o cursor do mouse quando ocioso
sudo -u "\$X_USER" env DISPLAY="\$DISPLAY_VAR" XAUTHORITY="\$XAUTHORITY_FILE" unclutter -idle 0.5 -root &
echo "\$(date): unclutter iniciado em segundo plano para o usuário \$X_USER."

# Corrige possíveis problemas de encerramento do Chromium
sudo -u "\$X_USER" sed -i 's/"exited_cleanly":false/"exited_cleanly":true/' "/home/\$X_USER/.config/chromium/Default/Preferences"
sudo -u "\$X_USER" sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/' "/home/\$X_USER/.config/chromium/Default/Preferences"
echo "\$(date): Preferências do Chromium ajustadas para o usuário \$X_USER."

# Abre o Chromium em modo quiosque
# ADICIONADO: --autoplay-policy=no-user-gesture-required para permitir áudio automático
sudo -u "\$X_USER" env DISPLAY="\$DISPLAY_VAR" XAUTHORITY="\$XAUTHORITY_FILE" /usr/bin/chromium-browser --noerrdialogs --disable-infobars --kiosk --autoplay-policy=no-user-gesture-required "\$KIOSK_URL" &
echo "\$(date): Chromium iniciado em modo quiosque como usuário \$X_USER, exibindo \$KIOSK_URL."

CHROMIUM_PID=\$!
echo "\$(date): PID do comando de início do Chromium: \$CHROMIUM_PID"

# Adiciona uma flag para controlar se o site estava offline
WAS_OFFLINE=false

# Loop principal para verificação e atualização
while true; do
    echo "\$(date): Verificando status da URL \$KIOSK_URL..."
    HTTP_STATUS=\$(curl -o /dev/null -s -w "%{http_code}\\n" "\$KIOSK_URL")
    echo "\$(date): Status HTTP retornado: \$HTTP_STATUS"

    if [ "\$HTTP_STATUS" -eq 200 ]; then
        if [ "\$WAS_OFFLINE" = true ]; then
            echo "\$(date): Site retornou 200 OK. Forçando recarregamento do Chromium (reiniciando)."
            # Lógica para reiniciar o Chromium
            echo "\$(date): Encerrando processos do Chromium para o usuário \$X_USER..."
            sudo -u "\$X_USER" pkill chromium-browser
            sleep 5 # Dá um tempo para o processo morrer completamente

            echo "\$(date): Reiniciando Chromium em modo quiosque como usuário \$X_USER..."
            sudo -u "\$X_USER" env DISPLAY="\$DISPLAY_VAR" XAUTHORITY="\$XAUTHORITY_FILE" /usr/bin/chromium-browser --noerrdialogs --disable-infobars --kiosk --autoplay-policy=no-user-gesture-required "\$KIOSK_URL" &
            CHROMIUM_PID=\$!
            echo "\$(date): Chromium reiniciado para recarregar. Novo PID: \$CHROMIUM_PID"
            WAS_OFFLINE=false # Reseta a flag
        else
            echo "\$(date): Site retornou 200 OK. Aguardando 1 minuto para a próxima verificação."
        fi
        sleep 60
    else
        echo "\$(date): Site retornou \$HTTP_STATUS. Encerrando e reiniciando Chromium para tentar resolver."
        WAS_OFFLINE=true # Define a flag, indicando que o site está offline
        while [ "\$HTTP_STATUS" -ne 200 ]; do
            echo "\$(date): Encerrando processos do Chromium para o usuário \$X_USER..."
            sudo -u "\$X_USER" pkill chromium-browser
            sleep 5 # Dá um tempo para o processo morrer completamente

            echo "\$(date): Reiniciando Chromium em modo quiosque como usuário \$X_USER..."
            sudo -u "\$X_USER" env DISPLAY="\$DISPLAY_VAR" XAUTHORITY="\$XAUTHORITY_FILE" /usr/bin/chromium-browser --noerrdialogs --disable-infobars --kiosk --autoplay-policy=no-user-gesture-required "\$KIOSK_URL" &
            CHROMIUM_PID=\$!
            echo "\$(date): Chromium reiniciado. Novo PID do comando: \$CHROMIUM_PID"

            sleep 60 # Espera 1 minuto antes da próxima re-verificação
            echo "\$(date): Re-verificando status após 1 minuto do reinício..."
            HTTP_STATUS=\$(curl -o /dev/null -s -w "%{http_code}\\n" "\$KIOSK_URL")
            echo "\$(date): Status HTTP após reinício: \$HTTP_STATUS"
            trim_log_file # Chama a função para aparar o log
        done
        echo "\$(date): Site voltou a retornar 200 OK. Saindo do loop de reinício forçado."
        # A detecção de retorno ao normal será tratada pelo 'if [ "$WAS_OFFLINE" = true ]' no próximo ciclo do loop externo
    fi
    trim_log_file # Chama a função para aparar o log
done
EOF

# Coleta a URL do prompt
echo -n "Por favor, digite a URL do site para o quiosque (ex: https://exemplo.com): "
read KIOSK_URL_FROM_PROMPT

# Validação básica da URL
if [[ -z "$KIOSK_URL_FROM_PROMPT" ]]; then
    echo "ERRO: Nenhuma URL foi fornecida. O script será encerrado."
    exit 1
fi

echo "Criando /home/pi/kiosk.sh..."
# Salva o conteúdo no arquivo kiosk.sh
echo "$kiosk_script_content" | sudo tee /home/pi/kiosk.sh > /dev/null
# Garante permissões de execução para o script do kiosk
sudo chmod +x /home/pi/kiosk.sh
echo "/home/pi/kiosk.sh criado e com permissões de execução."

sleep 2

echo "Habilitando serviço TUB-KIOSK..."
# O conteúdo do serviço systemd, incluindo a variável de ambiente KIOSK_URL
kiosk_service_content="
[Unit]
Description=Chromium Kiosk
Wants=graphical.target
After=graphical.target

[Service]
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/pi/.Xauthority
Environment=KIOSK_URL=$KIOSK_URL_FROM_PROMPT # <--- A URL é definida aqui para o serviço!
Type=simple
ExecStart=/bin/bash /home/pi/kiosk.sh
Restart=on-failure
User=pi
Group=pi

[Install]
WantedBy=graphical.target
"
# Salva o conteúdo no arquivo de serviço
echo "$kiosk_service_content" | sudo tee /lib/systemd/system/kiosk.service > /dev/null
echo "kiosk.service criado."

# Recarrega a configuração do systemd para reconhecer o novo serviço
sudo systemctl daemon-reload
echo "systemd daemon recarregado."

# Habilita o serviço para iniciar no boot
sudo systemctl enable kiosk.service
echo "kiosk.service habilitado para iniciar no boot."
sleep 2

# Inicia o serviço imediatamente
sudo systemctl start kiosk.service
echo "kiosk.service iniciado."
sleep 3

echo "Sistema será reiniciado para aplicar as mudanças e iniciar o kiosk."
sudo reboot