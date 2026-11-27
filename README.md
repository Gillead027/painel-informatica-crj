# Painel da Informática · CRJ Flexal

Sistema gratuito para controlar, de um único PC (o do estúdio), os computadores da sala de informática do CRJ Flexal.
Roda só com o que o Windows já tem, mais Python e Veyon. Não precisa de servidor pago nem de nuvem.

## O que faz

- **Proteção:** os alunos usam conta comum. O AppLocker bloqueia a instalação de programas e políticas no Chrome e no Edge restringem a navegação. Jogos já instalados continuam funcionando.
- **Painel web** (`http://IP-do-estudio:8080`), que abre no estúdio, no notebook e no celular, com senha fora do estúdio:
  - estado das máquinas e ações em massa com progresso: ligar pela rede, hibernar, reiniciar, mensagem, bloquear tela;
  - modo manutenção, liberar só o navegador e modo defeito;
  - horário automático por dia: liga antes da aula e hiberna no fechamento;
  - imagens do CRJ em slides na tela de bloqueio e no papel de parede;
  - histórico de pesquisas com palavras de alerta, visível só no painel;
  - manutenção semanal automática, com rede de segurança que funciona mesmo com o estúdio desligado;
  - sincronização automática das máquinas desatualizadas e adição de máquina nova pelo IP;
  - aba Atividade (quem fez o quê), avisos no celular (ntfy) e um Assistente com IA (Groq).

## Estrutura

| Caminho | O que é |
|---|---|
| `painel/painel.py` | Servidor do painel (Python, sem dependências externas) |
| `painel/painel-acoes.ps1` | Motor das ações nas máquinas (PowerShell + WinRM) |
| `painel/index.html`, `login.html`, `apresentacao.html` | Interface |
| `painel/manutencao-semanal.ps1` | Manutenção semanal instalada em cada máquina |
| `restricoes.ps1` | Restrições de cada máquina (AppLocker + navegadores) |
| `preparar-pc.ps1` + `servidor.py` | Preparo de uma máquina nova (uma vez, na própria máquina) |
| `pendrive-maquinas/`, `maquina-1-bloqueio/` | Scripts para rodar manualmente por pendrive |
| `Painel da Informatica.vbs` | Abre o painel como programa no estúdio |

## Fora do repositório (de propósito)

A lista está no `.gitignore`:
- **segredos:** senha do CRJ-Admin, chave do Veyon e `config.json` (senha do painel, tópico do ntfy, chave do Groq);
- **dados dos alunos:** histórico de pesquisas, fotos, relatórios e registros;
- **lista real de máquinas:** use `computadores.exemplo.csv` como modelo de `computadores.csv`;
- **instaladores binários:** Veyon e driver da impressora.

## Montar em outro PC

1. Instale o Python 3 e o Veyon (Master) no PC que vai ser o estúdio.
2. Crie `computadores.csv` a partir de `computadores.exemplo.csv`.
3. Rode `preparar-estudio.ps1` como administrador e depois `salvar-senha.ps1`.
4. Abra `Painel da Informatica.vbs`.
5. Em cada máquina da sala, rode `preparar-pc.ps1` como administrador. O painel mostra o comando em "Adicionar máquina".
