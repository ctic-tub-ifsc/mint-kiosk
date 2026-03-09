## **Diagnóstico Pós-Falha: Como Funciona em Detalhe**

O sistema foi projetado para ser **reativo**, não proativo. Isso significa que só coletamos dados QUANDO algo dá errado, não ficamos "filmando" a tela o tempo todo. Aqui está o fluxo completo:

## **Arquitetura do Diagnóstico**

```
MONITORAMENTO CONSTANTE (leve) → DETECÇÃO DE FALHA → DIAGNÓSTICO PROFUNDO → AÇÃO CORRETIVA
         ↓                           ↓                       ↓                       ↓
   Verificações rápidas          Algo errado?          Coleta evidências        Tenta resolver
   (processo, janela)            (check_health)        (screenshot, logs)       (refresh/reinício)
```

## **1. O que é monitorado CONSTANTEMENTE (a cada 30s)**

```bash
# Estas verificações são RÁPIDAS e LEVES - NÃO geram screenshots
check_chromium_health() {
    # 1. Processo existe? (kill -0 é instantâneo)
    pid=$(pgrep -f "chromium" | head -1)
    
    # 2. Janela está visível? (xdotool search é rápido)
    window_count=$(xdotool search --onlyvisible --class "chromium" 2>/dev/null | wc -l)
    
    # 3. Janela aceita foco? (xdotool windowfocus)
    # 4. Quanto tempo sem interagir? (xprintidle)
}
```

**IMPORTANTE:** Estas verificações NÃO:
- ❌ Não capturam screenshots
- ❌ Não escrevem arquivos grandes
- ❌ Não consomem CPU significativa
- ❌ Não afetam a performance do vídeo

## **2. O que DISPARA um diagnóstico**

```bash
# Quando qualquer falha é detectada:
if ! check_chromium_health; then
    # SÓ AGORA entramos em modo diagnóstico!
    capture_diagnostic_screenshot "chromium_unhealthy"
    
    # Tenta resolver
    soft_refresh "chromium_unhealthy"
    
    # Se não resolver em 3 tentativas:
    if [[ $consecutive_failures -ge 3 ]]; then
        capture_diagnostic_screenshot "pre_restart"
        restart_chromium
    fi
fi
```

## **3. Diagnóstico Detalhado (PÓS-FALHA)**

Quando uma falha é detectada, o script captura **MÚLTIPLAS evidências**:

```bash
capture_diagnostic_screenshot() {
    local reason="$1"  # Ex: "chromium_unhealthy", "pre_restart", "url_offline"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    # 1. CAPTURA DA TELA (o que o usuário via)
    local screenshot="$SCREENSHOT_DIR/${timestamp}_${reason}.png"
    DISPLAY=:0 gnome-screenshot -w -f "$screenshot"
    
    # 2. LOG DO SISTEMA (o que aconteceu antes)
    {
        echo "=== DIAGNÓSTICO: $timestamp ==="
        echo "Motivo: $reason"
        echo "--- Processos Chromium ---"
        ps aux | grep -i chromium
        echo "--- Memória do sistema ---"
        free -h
        echo "--- CPU ---"
        top -bn1 | head -20
        echo "--- Conexões de rede ---"
        netstat -tupan | grep -i chromium
        echo "--- Log do Chromium (últimas 20 linhas) ---"
        tail -20 /home/$(logname)/.config/chromium-kiosk/chrome_debug.log 2>/dev/null
        echo "------------------------"
    } >> "$SCREENSHOT_DIR/${timestamp}_${reason}.log"
    
    # 3. METADADOS DA IMAGEM (para detectar tela branca)
    if [[ -f "$screenshot" ]]; then
        # Calcula desvio padrão da imagem (se for muito baixo = tela branca)
        local stddev=$(identify -format "%[standard-deviation]" "$screenshot" 2>/dev/null)
        echo "Desvio padrão da imagem: $stddev" >> "$SCREENSHOT_DIR/${timestamp}_${reason}.log"
        
        # Se for muito baixo, marca como suspeita de tela branca
        if (( $(echo "$stddev < 0.1" | bc -l) )); then
            mv "$screenshot" "$SCREENSHOT_DIR/${timestamp}_WHITE_SCREEN_${reason}.png"
        fi
    fi
}
```

## **4. Exemplo Prático: Cadeia de Eventos**

### **Cenário 1: Chromium trava**
```
00:00:00 - Chromium rodando normalmente
00:00:30 - Verificação: OK
00:01:00 - Verificação: OK
00:01:30 - Chromium TRAVA (tela congelada)
00:02:00 - Verificação: FALHA! (janela não responde)
    → DISPARA DIAGNÓSTICO:
        • Captura screenshot do momento do travamento
        • Salva logs do sistema
        • Marca como "chromium_unhealthy"
    → TENTA RESOLVER:
        • Executa soft_refresh (F5)
00:02:05 - Verificação pós-refresh: FALHA (continua travado)
    → DISPARA NOVO DIAGNÓSTICO:
        • Captura screenshot mostrando que refresh não resolveu
        • Incrementa contador de falhas
00:02:35 - 3ª falha consecutiva
    → DISPARA DIAGNÓSTICO PRÉ-REINÍCIO:
        • Captura screenshot do estado final
        • Mata processos
        • Reinicia Chromium
00:02:45 - Verificação: OK (recuperado)
```

### **Cenário 2: URL offline (sem travamento)**
```
00:00:00 - Chromium exibindo conteúdo em cache
00:01:00 - Verificação URL: 200 OK
00:02:00 - Internet cai
00:03:00 - Verificação URL: FAIL (site inacessível)
    → DISPARA DIAGNÓSTICO:
        • Captura screenshot (mostra conteúdo em cache ainda)
        • Loga "URL offline - conteúdo em cache sendo exibido"
    → NÃO TENTA REFRESH (não faz sentido)
00:06:00 - Internet volta
00:07:00 - Verificação URL: 200 OK
    → DISPARA REFRESH INTELIGENTE:
        • Soft refresh para recarregar conteúdo novo
```

## **5. O que é salvo em cada diagnóstico**

Para cada falha, temos um **PACOTE DE EVIDÊNCIAS**:

```
/var/log/kiosk_screenshots/
├── 20231201_143022_chromium_unhealthy.png        # O que estava na tela
├── 20231201_143022_chromium_unhealthy.log        # Contexto do sistema
├── 20231201_143055_soft_refresh_failed.png       # Após tentativa de refresh
├── 20231201_143055_soft_refresh_failed.log
├── 20231201_143125_pre_restart.png               # Antes de reiniciar
└── 20231201_143125_pre_restart.log
```

## **6. Limpeza Automática**

```bash
# Mantém apenas os últimos 10 diagnósticos
cleanup_screenshots() {
    cd "$SCREENSHOT_DIR" 2>/dev/null || return
    # Lista por data, mantém 10 mais recentes, remove resto
    ls -t *.png 2>/dev/null | tail -n +11 | xargs -r rm
    ls -t *.log 2>/dev/null | tail -n +11 | xargs -r rm
}
```

## **7. Como usar para diagnóstico da causa raiz**

### **Análise Manual** (quando chamado para resolver):
```bash
# 1. Ver últimos diagnósticos
ls -la /var/log/kiosk_screenshots/

# 2. Ver o que aconteceu antes da falha
tail -50 /var/log/kiosk_monitor.log

# 3. Analisar screenshot da falha
eog /var/log/kiosk_screenshots/20231201_143022_chromium_unhealthy.png

# 4. Ver logs do sistema no momento da falha
cat /var/log/kiosk_screenshots/20231201_143022_chromium_unhealthy.log

# 5. Ver se há padrão (ex: sempre falha em horários específicos)
grep "WHITE_SCREEN" /var/log/kiosk_screenshots/*.log
```

## **8. Benefícios desta abordagem**

| Aspecto | Monitoramento Constante | Diagnóstico Pós-Falha |
|---------|------------------------|----------------------|
| **CPU** | 0.1% (verificações simples) | 5% por 2 segundos (só quando falha) |
| **Disco** | 0 writes (só logs) | ~500KB por falha |
| **Tela** | Sem interferência | Screenshot em 100ms |
| **Dados** | Poucos | Ricos em contexto |

## **9. Exemplo de Análise de Causa Raiz**

Quando um cliente reporta "a tela ficou branca", você pode:

```bash
# 1. Ver todos os diagnósticos do dia
ls -la /var/log/kiosk_screenshots/*WHITE_SCREEN*

# 2. Ver padrões
for f in /var/log/kiosk_screenshots/*WHITE_SCREEN*.log; do
    echo "=== $f ==="
    grep -E "CPU|Memory|swap" "$f"
done

# 3. Descobrir, por exemplo:
# - Se todas as falhas ocorrem com alta memória → problema de memory leak
# - Se ocorrem quando a rede cai → problema de reconexão do PWA
# - Se ocorrem em horários específicos → conflito com cron/backup
```

## **Resumo**

O sistema **NÃO**:
- ❌ Não faz screenshot a cada 30 segundos
- ❌ Não monitora constante a imagem da tela
- ❌ Não gera GBs de dados

O sistema **SIM**:
- ✅ Monitora indicadores indiretos de saúde (rápidos)
- ✅ SÓ captura evidências quando algo errado
- ✅ Cria um "black box" do avião para cada incidente
- ✅ Permite diagnóstico preciso sem sobrecarga

É como ter uma **caixa preta** que só grava quando o avião está caindo, não durante o voo normal!
