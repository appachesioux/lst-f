# lst-f

Explora e altera o filesystem no terminal. **A tela é o buffer do seu Vim ou
Neovim**: o `lst-f` abre o diretório como um buffer editável, você edita, salva,
e ele executa o que você escreveu.

```
╭─ ~/Devel/lst-f ─────────────────────────────────────────────────── lst-f v26.8.23 ─╮   ← moldura

──────────────────────────────────────────────────────────────────────────────────────
T │ PERMS     │ OWNER    │ SIZE      │ MODIFIED         │ NAME                           ← títulos
d │ rwxr-xr-x │          │         - │ 2026-08-21 22:58 │  src/
- │ rw-r--r-- │ root     │      220B │ 2026-08-20 11:03 │  instalado-pelo-sistema.conf
- │ rw-r--r-- │          │      1.1K │ 2026-08-22 00:14 │  README.md
 NORMAL  2/3  instalado-pelo-sistema.conf                                Vim  F1=Help
```

A coluna `OWNER` fica em branco no que é seu — repetir o seu nome em toda linha
não informa nada. Dono alheio aparece pelo nome; se o `uid` não estiver em
`/etc/passwd` (usuário só de LDAP ou SSSD, por exemplo), aparece o número.

As duas linhas do topo — a moldura com o caminho e a versão, e os títulos das colunas — são barra de tela; as entradas ocupam o buffer inteiro. Pressionar **`F1` ou `?`** abre o popup de ajuda flutuante com os comandos e diretivas principais (`:cd`, `:find`, `:undo`, `:quit`), fechando com `q` ou `Esc`.

A barra de baixo mostra permanentemente o modo, a posição na lista, o nome sob o cursor e se a sessão está usando **Vim** ou **Neovim**. O diretório atual fica na moldura, no topo.

O ID à esquerda casa a linha com a entrada, então reordenar, rodar `:sort` ou
recolar linhas é inofensivo. Nada é gravado sem diff e confirmação, e as
remoções aparecem em bloco próprio na confirmação.

Colisões que o próprio buffer já consegue provar são resolvidas antes do `:w`:
a linha editada, criada ou colada recebe o primeiro sufixo livre (`-01` a
`-99`) e a barra inferior mostra o nome sugerido. Se nenhum sufixo estiver
livre, o conflito fica sublinhado em vermelho. A validação após o `:w` permanece
como garantia definitiva contra mudanças externas e conflitos mais complexos.

Sem plugin, sem gerenciador de pacotes: funciona com `vim` puro no servidor em
que você acabou de entrar por SSH.

## O que faz

| você escreve / digita               | acontece                                  |
| ----------------------------------- | ----------------------------------------- |
| muda o caminho de uma linha          | renomeia ou move (cria os pais que faltam) |
| apaga a linha                        | remove, via área de sessão                 |
| escreve um nome em linha nova        | cria o arquivo (com `/` no fim, o diretório) |
| `q` no buffer                        | sai do `lst-f`                            |
| `ZZ`                                  | sai do `lst-f`                            |
| `F1` ou `?`                          | abre o helper popup de ajuda flutuante     |
| `F4`                                  | abre terminal / shell interativo no diretório atual |
| `Enter` sobre diretório               | entra nele                                 |
| `Enter` sobre arquivo de texto/código | abre-o no Vim/Neovim; `:q` volta à lista   |
| `Enter` sobre arquivo binário/mídia   | abre no app padrão via `xdg-open`          |
| `.`                                   | alterna exibição de arquivos ocultos       |
| `-`                                   | sobe para o diretório-pai                  |
| `<` e `>`                             | voltam e avançam nos diretórios visitados na sessão |
| `\`                                   | abre uma árvore visual do diretório atual  |
| `Ctrl+P`                              | abre o buscador fuzzy (`fzf`) na árvore inteira |
| `Ctrl+A`                              | seleciona todo o buffer do `lst-f`         |
| `yr` ou `yp`                          | copia caminho relativo do arquivo/diretório para o clipboard |
| `ya`                                  | copia caminho absoluto do arquivo/diretório para o clipboard |
| `Ctrl+S`                              | abre/fecha o painel dividido de destino    |
| `Tab`                                 | alterna o foco entre painel principal e split |
| `Y` ou `yy` no split                  | copia caminho do destino para colar (`p`)  |
| `S` ou `s` no split                   | copia formato de symlink (`nome -> caminho`) para colar (`p`) |
| `F4` no split                         | abre terminal no diretório de destino      |
| `nome -> alvo` em linha nova          | cria symlink apontando para o alvo         |
| `nome => alvo` em linha nova          | cria hardlink apontando para o alvo        |
| `:cd <dir>`                          | entra no diretório (`..` sobe)             |
| `:sh [dir]`                          | abre terminal / shell no diretório (`:shell`, `:terminal`) |
| `:ln <alvo> [nome]`                  | cria symlink para o alvo (`:link`, `:symlink`) |
| `:hardlink <alvo> [nome]`            | cria hardlink para o alvo                  |
| `:yank` / `:relpath`                 | copia o caminho relativo do arquivo sob o cursor (:copy) |
| `:abspath` / `:realpath`             | copia o caminho absoluto do arquivo sob o cursor |
| `:hidden`                            | alterna exibição de arquivos ocultos       |
| `:open <arquivo>`                    | abre o arquivo para edição no editor       |
| `:find [termo]`                      | busca fuzzy na árvore com o `fzf`          |
| `:back` / `:forward`                 | andam pelos diretórios visitados na sessão |
| `:undo`                              | desfaz a última operação da sessão         |
| `:quit`                              | sai (salvar sem mudanças também sai)       |
| `:cq` no editor                      | aborta sem aplicar nada                    |

Na árvore, use `j`/`k` ou as setas para navegar; `q`, `Esc`, `Enter` ou `\` a fecha. Para manter a abertura rápida em árvores grandes, ela mostra até 2.000 entradas e informa quando foi truncada.

Use `:w` para aplicar a edição no filesystem. Antes de qualquer mudança, um popup lista criações, cópias, renomeios e remoções; `y` ou `Enter` confirma, `n` ou `Esc` cancela, e `j`/`k` rolam listas longas. Mesmo sem alterações, `:w` só atualiza a lista e mantém a sessão aberta. Depois de aplicar, o mesmo buffer é recarregado na mesma instância do editor, sem apagar a tela; o resultado aparece na barra de baixo e o cursor fica na mesma linha aproximada. Se o sistema não permitir o socket da sessão viva, a confirmação textual e o fluxo antigo de fechar e reabrir continuam disponíveis como fallback. `q`, `:q`, `:quit` ou `ZZ` encerram a sessão de fato, inclusive quando há renomeações pendentes.

Em terminais estreitos, o nome editável pode ficar fora da área visível; use `zl` e `zh` para rolar horizontalmente.

O editor abre com o diretório atual como *cwd*, então `:e`, `gf` e completação
funcionam direto sobre os caminhos listados.

## `:find` — o fzf entra aqui

`:find relatorio` abre o `fzf` sobre a árvore inteira a partir do diretório
atual. A busca usa *smart case*: uma consulta só em minúsculas ignora caixa;
uma maiúscula torna a consulta sensível. A busca `/` do Vim segue a mesma
regra. Você filtra, marca com `Tab` o que interessa — espalhado por quantos
subdiretórios for — e o que foi marcado **vira o conteúdo do buffer**. Renomear
doze arquivos de seis diretórios diferentes é um `:find`, doze `Tab` e uma
edição.

No buscador: `Tab` marca, `Ctrl+A` marca ou desmarca tudo, `Enter` aceita, `alt-p` abre e fecha o preview, `F1`
mostra a ajuda, `Esc` cancela.

## Requisitos

- Vim ou Neovim (prioridade para `vim`) ou `--editor <cmd>` — é a tela, não é opcional
- `fzf` 0.17 ou mais novo, só para o `:find`
- Zig 0.16.x para compilar

Os binários de runtime (`vim`, `nvim`, `fzf`) podem estar instalados no `$PATH` do sistema ou simplesmente colocados na mesma pasta do binário `lst-f` (modo bundle portátil, sem instalação e sem `sudo`).

Sem plugins, sem Node, Python, `fd`, `rg` ou Nerd Font.

## Instalação

```sh
zig build -Doptimize=ReleaseSafe
cp zig-out/bin/lst-f ~/.local/bin/
```

Para rodar em distribuição estável (Debian, Ubuntu Server), compile contra uma
glibc antiga ou estaticamente:

```sh
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu.2.28
```

## Uso

```sh
lst-f                  # abre o diretório atual no editor
lst-f ~/projetos       # abre outro diretório
lst-f -a               # inclui arquivos ocultos (dotfiles)
lst-f --find relatorio # começa direto no buscador
```

Opções: `-a`, `--all`, `--hidden`, `--editor <cmd>`, `--max-depth <n>`, `--icons`, `--no-color`.

Para editar com uma configuração limpa: `lst-f --editor "vim -u NONE"`.

## Criação

Uma linha que não começa por ID é um nome novo: `notas.md` cria o arquivo vazio,
`docs/` cria o diretório, `docs/2026/notas.md` cria os dois níveis que faltarem
antes do arquivo.

Para criar **links**:
- `meu-link -> /caminho/do/alvo` cria um **symlink** apontando para o alvo (relativo ou absoluto).
- `meu-link => /caminho/do/alvo` cria um **hardlink** apontando para o alvo.
- Ou use as diretivas `:ln <alvo> [nome]` (`:link`, `:symlink`) e `:hardlink <alvo> [nome]`.
- No painel dividido (`Ctrl+S`), pressione `S` ou `s` sobre qualquer entrada para copiar no formato `nome -> /caminho/completo` e colar (`p`) direto no buffer principal.

As criações acontecem depois das renomeações, então um nome
liberado no mesmo `:w` pode ser reocupado — arquivar `log.txt` como `log.1.txt`
e criar um `log.txt` novo funciona em um passo só.

Nada é sobrescrito: se o caminho já existir, o `lst-f` recusa antes de aplicar e
devolve o buffer. `:undo` apaga o que foi criado, mas só enquanto o arquivo
continuar vazio — o que você escreveu depois fica.

## Só o nome é editável

O caminho e os títulos das colunas ficam nas **duas barras de topo**, irmãs da
barra de status de baixo: são linha de tela, não de buffer. Não rolam junto com
a lista, não dá para apagar, redesenham-se sozinhas quando o terminal muda de
tamanho e a dos títulos acompanha a rolagem horizontal, para as colunas nunca
saírem do lugar.

As colunas técnicas de cada linha são leitura: o cursor não entra nelas e, se um
`:sort`, um `dd` ou uma colagem passar por cima, o `lst-f` recompõe a linha na
hora. Vim e Neovim não trancam um intervalo de linhas — `modifiable` vale para o
buffer inteiro —, então isso é feito pelo helper, sem plugin. O plano nunca
dependeu dessas colunas: elas são descartadas na leitura do buffer, então nem
uma edição que escape delas muda o que acontece no disco.

## Remoção

Apagar a linha remove a entrada, mas nada é apagado durante a aplicação: o que
sai vai por `rename()` para `.lst-f-<pid>/` no diretório-base, no mesmo modelo
de arquivo de swap do Vim. Enquanto a sessão estiver aberta, `:undo` traz tudo
de volta.

**Ao sair, a área é apagada e a remoção passa a ser definitiva.** O `lst-f` não
é uma lixeira: a garantia é sobre erro durante a operação e arrependimento
durante a sessão, não sobre recuperação amanhã.

Se a sessão morrer (crash, kill, queda de SSH), a área fica para trás e o
`lst-f` avisa no cabeçalho do buffer na abertura seguinte daquele diretório, sem
restaurar nem apagar sozinho.

## Nomes que não são UTF-8

O Vim não preserva bytes inválidos no round-trip. Entradas assim aparecem no
cabeçalho do buffer, com os bytes escapados, mas ficam fora da edição — o `ID`
estaria certo e o destino, corrompido.

## Desenvolvimento

```sh
zig build         # compila
zig build test    # roda a suíte
zig fmt .         # formata
```
