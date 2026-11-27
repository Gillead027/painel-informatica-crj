# Painel da Informática — CRJ Flexal · Guia para o redesenho

Este kit tem tudo o que é preciso para redesenhar o visual do painel em casa.
Amanhã o visual novo é ligado aos dados reais e vira o programa do PC do estúdio.

- **painel-demo.html**: o painel de hoje, com **dados de exemplo**. Abra com dois cliques no Chrome. Os botões funcionam, mas só simulam as ações.
- **GUIA-DO-PAINEL.md**: este arquivo.

---

## 1. Como o painel funciona (resumo)
- Um programa em Python roda escondido no PC do estúdio e conversa com as máquinas da sala.
- O visual é **uma página só** (`index.html`, com HTML, CSS e JavaScript juntos). Ela vai abrir numa **janela própria do Chrome**, sem barra de endereço, com cara de programa.
- A página pede os dados ao programa a cada 10 segundos e envia as ações quando um botão é clicado.

## 2. Regras para o visual novo
1. **Um único arquivo HTML.** O CSS e o JavaScript podem ficar dentro dele, ou em arquivos ao lado se precisar.
2. **Precisa funcionar no Chrome.** Não precisa funcionar no Edge.
3. **Fontes e ícones:** podem usar a internet (Google Fonts, por exemplo), mas o ideal é funcionar sem internet. Use fontes do sistema (Segoe UI) ou baixe a fonte junto. Para ícones, prefira SVG dentro do arquivo.
4. **Liberdade total no visual:** layout, cores, cartões, ícones, modo escuro, gráficos. Os **textos e ações** da seção 4 precisam continuar existindo.
5. Pode desenhar do zero. Se mantiver os **mesmos `id`** do HTML de hoje (`#grade`, `#h-tabela`, `#hr-abre` etc.), o encaixe fica mais rápido; se não manter, eu adapto amanhã.
6. **Tela-alvo:** o monitor do estúdio, em torno de 1366×768 a 1920×1080, com janela maximizada.

## 3. Identidade
- Nome: **Painel da Informática**, subtítulo **CRJ Flexal**
- Quem usa: o educador social **Gillead** e a equipe. A linguagem deve ser simples, sem termos técnicos.
- Hoje: cabeçalho escuro (#1d2330), fundo cinza claro, azul de destaque (#2f6fed). **Tudo isso pode mudar.**

## 4. O que o painel mostra e faz

### Aba 1 — Máquinas (tela principal)
**Resumo no topo** (sugestão nova): quantas ligadas, bloqueadas, em manutenção e desligadas, além do horário da última atualização.

**Um cartão por máquina** (hoje são 8: Máquinas 1, 2, 3, 4, 5, 6, 8 e 10; a 7 entra em breve). Campos:

| Campo | Exemplo | Observação |
|---|---|---|
| nome | Maquina 3 | |
| online | sim / não | bolinha verde ou cinza |
| estado | Bloqueada · Manutenção até 17:00 · Desligada/hibernando · Verificar | ver estados abaixo |
| usuário logado | CRJ MAQUINA 03 / ninguém | |
| ligada desde | 18/11 13:55 | |
| visto por último | 18/11 15:40 | útil quando está desligada |
| IP | 192.168.10.125 | pode ficar discreto |
| horário | aplicado / pendente | só quando o controle de horário está ligado |

**Estados de cada máquina**, cada um com cor ou ícone próprio:
1. **Bloqueada:** normal, tudo protegido (verde)
2. **Manutenção até HH:MM:** restrições pausadas, voltam sozinhas (amarelo)
3. **Desligada / hibernando:** sem resposta (cinza)
4. **Verificar:** ligada, mas com o bloqueio desligado sem motivo (vermelho)

**Seleção:** clicar no cartão seleciona. Precisa haver "Selecionar todas" e um contador de selecionadas.

**Ações** (valem para as selecionadas; ficam desabilitadas sem seleção):

| Ação | Confirmação | Observação |
|---|---|---|
| Modo manutenção | sim | escolher a duração: 1, 2, 3 ou 4 horas |
| Reativar bloqueio | sim | |
| Enviar mensagem | caixa de texto | aparece na tela dos alunos (até 250 caracteres) |
| Hibernar | sim | desliga guardando tudo; liga sozinha na abertura |
| Ligar | sim | **ainda não funciona** (falta o Wake-on-LAN); deixar com aviso |
| Reiniciar | sim (ação de risco) | aviso de 1 minuto na tela dos alunos |
| Desligar | sim (ação de risco) | avisar que ela não liga sozinha depois |

Avisos rápidos no canto (toasts): "Hibernar: enviando para 3 máquinas…", "Hibernar: 3 ok", "1 falhou (desligada?)".

### Aba 2 — Pesquisas e sites
- Filtros: **tipo** (Pesquisas / Sites visitados), **máquina** (todas ou uma), **período** (hoje, 7 dias, 30 dias) e **busca por palavra**.
- Botão **"Coletar agora"** e o texto "Última coleta: 18/11 15:30" ou "Coletando histórico…".
- **Tabela de pesquisas:** quando · máquina · pesquisa (destaque) · onde (Google/YouTube/Bing) · navegador.
- **Tabela de sites:** quando · máquina · título da página · endereço (link) · navegador.
- Pode ter centenas de linhas (até 1000): pensar em rolagem e leitura confortável.
- Ideias (opcionais): ranking dos termos mais pesquisados, filtro rápido por máquina, destaque para palavras de alerta.

### Aba 3 — Horário de funcionamento
- Liga/desliga o controle de horário.
- **Abre às** (hoje 14:00) e **Fecha às** (hoje 17:30).
- **Dias:** Seg, Ter, Qua, Qui, Sex, Sáb, Dom (hoje de segunda a sexta).
- Botão **"Salvar e aplicar em todas"**.
- Situação: "Aplicado em todas as 8 máquinas" ou "Aplicado em 7 de 8. Pendentes: Maquina 6".
- Texto explicativo: 5 minutos antes de fechar aparece um aviso; no horário de fechar, as máquinas hibernam; 5 minutos antes de abrir, ligam sozinhas; máquinas em manutenção não hibernam.

### Elementos gerais
- **Janela de confirmação** (título, texto e botões Cancelar/Confirmar), também usada com campo de texto para mensagens.
- **Estados vazios:** "Carregando máquinas…", "Nada encontrado neste período.", "Sem conexão com o painel".

## 5. Dados que a página recebe (para quem for programar)
`GET /api/estado` (a cada 10 s):
```json
{
  "atualizado": "15:40:12",
  "hist_atualizado": "18/11 15:30", "hist_rodando": false,
  "horario": {"ativo": true, "abre": "14:00", "fecha": "17:30", "dias": ["Monday","Tuesday","Wednesday","Thursday","Friday"]},
  "pcs": [{"nome": "Maquina 3", "ip": "192.168.10.125", "online": true, "logado": "CRJ MAQUINA 03",
           "estado": "PAUSADO (manutencao) ate 18/11/2026 17:00", "bloqueio": "AuditOnly",
           "boot": "18/11 13:55", "visto": "18/11 15:40", "horario_sync": true}]
}
```
- `estado` começa com `ATIVO` (normal) ou `PAUSADO` (manutenção). `bloqueio = "Enabled"` significa bloqueada.

`GET /api/historico?tipo=pesquisas|sites&pc=Maquina 3&dias=0|7|30&busca=texto` → `{"linhas": [[máquina, conta, navegador, "2026-11-18 15:31:10", termo_ou_url, onde_ou_título], ...]}`

`POST /api/acao` com corpo `{"acao": "Pausar|Aplicar|Mensagem|Hibernar|Ligar|Reiniciar|Desligar", "ips": [...], "horas": 3, "texto": "..."}` → `{"resultados": [{"ip": "...", "ok": true}]}`

`POST /api/horario` com o mesmo formato de `horario` acima. `POST /api/historico/atualizar` inicia a coleta.
(Os POST precisam do cabeçalho `X-CRJ: 1`. O demo já simula tudo isso.)

## 6. Amanhã, no estúdio
1. Trazer o arquivo do visual novo (pendrive, e-mail ou Google Drive).
2. Eu ligo o visual aos dados reais e testo com as máquinas.
3. Transformo em programa: janela própria (Chrome em modo aplicativo), sem a janela preta, com ícone, abrindo sozinho quando o PC liga.
